//! A release orphaned by a shell crash must be adopted or replaced, never
//! raced by a second server on the same data home (PKG 26).
mod common;

use arbiter_shell_core::release_lock::{self, Record};
use arbiter_shell_core::supervisor::{State, StopOutcome, Supervisor};
use common::{free_port, spawn_orphan, spawn_silent_holder, Fake, WAIT};
use std::process::Command;
use std::time::Duration;

fn running(s: &State) -> bool {
    matches!(s, State::Running { .. })
}

fn port_of(s: &State) -> u16 {
    match s {
        State::Running { port } => *port,
        other => panic!("not running: {other:?}"),
    }
}

fn starts_in(lines: &[String]) -> usize {
    lines.iter().filter(|l| l.starts_with("start ")).count()
}

#[test]
fn adopts_a_live_release_and_starts_no_second_server() {
    let mut fake = Fake::new("adopt", &[]);
    fake.enable_data_home();
    let orphan = spawn_orphan(&fake, &[]);

    let sup = Supervisor::start(fake.config.clone());
    let state = sup.wait_for(WAIT, running).expect("adopted");

    // It connected to the orphan's port and launched nothing of its own.
    assert_eq!(port_of(&state), orphan.port);
    assert_eq!(fake.starts(), 1, "log: {:?}", fake.log_lines());
    assert_eq!(
        release_lock::read(&fake.data_home).map(|r| r.pid),
        Some(orphan.pid)
    );

    // The adopting shell owns it now: quitting stops that release.
    assert_eq!(sup.stop(), StopOutcome::Graceful);
    assert!(fake.log_lines().contains(&"exit clean".to_string()));
    assert_eq!(release_lock::read(&fake.data_home), None);
}

#[test]
fn a_stale_pidfile_is_cleaned_up_and_a_fresh_release_starts() {
    let mut fake = Fake::new("stale", &[]);
    fake.enable_data_home();
    let mut gone = Command::new("true").spawn().unwrap();
    let dead_pid = gone.id();
    gone.wait().unwrap();
    release_lock::write(
        &fake.data_home,
        &Record {
            pid: dead_pid,
            port: free_port(),
            version: None,
        },
    )
    .unwrap();

    let sup = Supervisor::start(fake.config.clone());
    let port = port_of(&sup.wait_for(WAIT, running).expect("fresh release"));

    assert_eq!(fake.starts(), 1);
    let rec = release_lock::read(&fake.data_home).expect("new record");
    assert_ne!(rec.pid, dead_pid);
    assert_eq!(rec.port, port);

    assert_eq!(sup.stop(), StopOutcome::Graceful);
    assert_eq!(release_lock::read(&fake.data_home), None);
}

#[test]
fn a_version_mismatch_stops_the_old_release_before_starting_the_new_one() {
    // The old release takes 300ms to exit after SIGTERM, like a draining server.
    let mut fake = Fake::new(
        "mismatch",
        &[("FAKE_VERSION", "2.0.0"), ("FAKE_TERM_DELAY_MS", "300")],
    );
    fake.enable_data_home();
    fake.config.expected_version = Some("2.0.0".into());
    let old = spawn_orphan(
        &fake,
        &[("FAKE_VERSION", "1.0.0"), ("FAKE_TERM_DELAY_MS", "300")],
    );

    let sup = Supervisor::start(fake.config.clone());
    let state = sup.wait_for(WAIT, running).expect("replacement is up");

    // Old: start, term, exit clean (not killed); only then the new start.
    let lines = fake.log_lines();
    assert_eq!(lines.len(), 4, "log: {lines:?}");
    assert_eq!(lines[0], format!("start port={}", old.port));
    assert_eq!(lines[1], "term");
    assert_eq!(lines[2], "exit clean");
    assert_eq!(lines[3], format!("start port={}", port_of(&state)));
    assert!(!release_lock::pid_alive(old.pid));
    let rec = release_lock::read(&fake.data_home).expect("new record");
    assert_ne!(rec.pid, old.pid);

    assert_eq!(sup.stop(), StopOutcome::Graceful);
}

#[test]
fn a_release_that_ignores_sigterm_is_killed_only_after_the_grace() {
    let mut fake = Fake::new("mismatch-kill", &[("FAKE_VERSION", "2.0.0")]);
    fake.enable_data_home();
    fake.config.expected_version = Some("2.0.0".into());
    fake.config.stop_grace = Duration::from_millis(500);
    let old = spawn_orphan(&fake, &[("FAKE_VERSION", "1.0.0"), ("FAKE_IGNORE_TERM", "1")]);

    let sup = Supervisor::start(fake.config.clone());
    sup.wait_for(WAIT, running).expect("replacement is up");

    assert!(!release_lock::pid_alive(old.pid));
    assert_eq!(fake.starts(), 2, "log: {:?}", fake.log_lines());
    assert_eq!(sup.stop(), StopOutcome::Graceful);
}

#[test]
fn a_live_holder_that_never_answers_is_refused_not_raced() {
    let mut fake = Fake::new("refuse", &[]);
    fake.enable_data_home();
    fake.config.ready_timeout = Duration::from_millis(300);
    fake.config.max_boot_failures = 1;
    let holder = spawn_silent_holder(&fake);

    let sup = Supervisor::start(fake.config.clone());
    let state = sup
        .wait_for(WAIT, |s| matches!(s, State::BootFailed { .. }))
        .expect("refused");

    match state {
        State::BootFailed { reason, .. } => {
            assert!(reason.contains(&holder.pid.to_string()), "{reason}")
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(fake.starts(), 0, "no second server was started");
    // The record is not ours to delete.
    assert_eq!(
        release_lock::read(&fake.data_home).map(|r| r.pid),
        Some(holder.pid)
    );
    sup.stop();
}

#[test]
fn two_shells_launched_at_once_start_exactly_one_server() {
    let mut fake = Fake::new("two-shells", &[]);
    fake.enable_data_home();

    let a = Supervisor::start(fake.config.clone());
    let b = Supervisor::start(fake.config.clone());
    let port_a = port_of(&a.wait_for(WAIT, running).expect("a is up"));
    let port_b = port_of(&b.wait_for(WAIT, running).expect("b is up"));

    assert_eq!(port_a, port_b, "both shells show the same server");
    assert_eq!(
        starts_in(&fake.log_lines()),
        1,
        "log: {:?}",
        fake.log_lines()
    );

    // Whichever one stops first takes the server down; the other may relaunch
    // before it is stopped too. Both end up stopped either way.
    b.stop();
    a.stop();
}
