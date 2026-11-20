mod common;

use arbiter_shell_core::http;
use arbiter_shell_core::supervisor::{State, StopOutcome, Supervisor};
use common::{Fake, WAIT};
use std::net::TcpListener;
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

#[test]
fn starts_the_release_and_reports_the_port_it_serves_on() {
    let fake = Fake::new("start", &[]);
    let sup = Supervisor::start(fake.config.clone());
    let state = sup.wait_for(WAIT, running).expect("became ready");
    let r = http::get(
        port_of(&state),
        "/api/version",
        None,
        Duration::from_secs(2),
    )
    .unwrap();
    assert_eq!(r.status, 200);
    assert_eq!(sup.stop(), StopOutcome::Graceful);
}

#[test]
fn uses_the_preferred_port_when_it_is_free() {
    let probe = TcpListener::bind("127.0.0.1:0").unwrap();
    let free = probe.local_addr().unwrap().port();
    drop(probe);
    let mut fake = Fake::new("pref-free", &[]);
    fake.config.preferred_port = free;
    let sup = Supervisor::start(fake.config.clone());
    assert_eq!(port_of(&sup.wait_for(WAIT, running).unwrap()), free);
    sup.stop();
}

#[test]
fn picks_another_loopback_port_when_the_default_is_taken_and_passes_it_to_the_release() {
    let taken = TcpListener::bind("127.0.0.1:0").unwrap();
    let busy = taken.local_addr().unwrap().port();
    let mut fake = Fake::new("pref-busy", &[]);
    fake.config.preferred_port = busy;
    let sup = Supervisor::start(fake.config.clone());
    let port = port_of(&sup.wait_for(WAIT, running).unwrap());
    assert_ne!(port, busy);
    // The release was told that same port (it logs what it was given) ...
    assert_eq!(fake.log_lines(), vec![format!("start port={port}")]);
    // ... and it is the one answering.
    assert_eq!(
        http::get(port, "/api/version", None, Duration::from_secs(2))
            .unwrap()
            .status,
        200
    );
    sup.stop();
    drop(taken);
}

#[test]
fn restarts_after_a_crash_with_backoff() {
    // First two launches crash shortly after becoming ready; the third stays up.
    let fake = Fake::new("crash", &[("FAKE_CRASH_FIRST_N", "2")]);
    let sup = Supervisor::start(fake.config.clone());
    let events = sup.subscribe();
    // wait for the steady state
    sup.wait_for(WAIT, |s| running(s) && fake_starts_at_least(&fake, 3))
        .expect("third launch is stable");
    let seen: Vec<State> = events.try_iter().collect();
    let delays: Vec<Duration> = seen
        .iter()
        .filter_map(|s| match s {
            State::Restarting { delay, .. } => Some(*delay),
            _ => None,
        })
        .collect();
    assert_eq!(
        delays,
        vec![Duration::from_millis(50), Duration::from_millis(100)]
    );
    assert_eq!(fake.starts(), 3);
    sup.stop();
}

fn fake_starts_at_least(fake: &Fake, n: usize) -> bool {
    fake.starts() >= n
}

#[test]
fn surfaces_a_boot_failure_with_the_release_output_instead_of_looping() {
    let mut fake = Fake::new("bootfail", &[("FAKE_MODE", "exit")]);
    fake.config.max_boot_failures = 2;
    let sup = Supervisor::start(fake.config.clone());
    let state = sup
        .wait_for(WAIT, |s| matches!(s, State::BootFailed { .. }))
        .expect("boot failure surfaced");
    match state {
        State::BootFailed { reason, log_tail } => {
            assert!(reason.contains("exited"), "{reason}");
            assert!(log_tail.iter().any(|l| l.contains("boom")), "{log_tail:?}");
        }
        _ => unreachable!(),
    }
    // It stopped trying: exactly max_boot_failures launches.
    assert_eq!(fake.starts(), 2);
    sup.stop();
}

#[test]
fn retry_after_a_boot_failure_launches_again() {
    let mut fake = Fake::new("retry", &[("FAKE_MODE", "exit")]);
    fake.config.max_boot_failures = 1;
    let sup = Supervisor::start(fake.config.clone());
    sup.wait_for(WAIT, |s| matches!(s, State::BootFailed { .. }))
        .unwrap();
    assert_eq!(fake.starts(), 1);
    let events = sup.subscribe();
    sup.retry();
    let seen: Vec<State> = std::iter::from_fn(|| events.recv_timeout(WAIT).ok())
        .take_while(|s| !matches!(s, State::BootFailed { .. }))
        .collect();
    assert!(
        seen.iter().any(|s| matches!(s, State::Starting { .. })),
        "{seen:?}"
    );
    assert_eq!(fake.starts(), 2);
    sup.stop();
}

#[test]
fn a_release_that_never_becomes_ready_is_a_boot_failure() {
    let mut fake = Fake::new("hang", &[("FAKE_MODE", "hang")]);
    fake.config.ready_timeout = Duration::from_millis(300);
    fake.config.max_boot_failures = 1;
    let sup = Supervisor::start(fake.config.clone());
    match sup
        .wait_for(WAIT, |s| matches!(s, State::BootFailed { .. }))
        .unwrap()
    {
        State::BootFailed { reason, .. } => assert!(reason.contains("ready"), "{reason}"),
        _ => unreachable!(),
    }
    sup.stop();
}

#[test]
fn stop_sends_sigterm_and_waits_for_a_clean_exit() {
    let fake = Fake::new("stop", &[("FAKE_TERM_DELAY_MS", "200")]);
    let sup = Supervisor::start(fake.config.clone());
    let port = port_of(&sup.wait_for(WAIT, running).unwrap());
    assert_eq!(sup.stop(), StopOutcome::Graceful);
    assert_eq!(sup.state(), State::Stopped);
    let log = fake.log_lines();
    assert!(
        log.contains(&"term".to_string()) && log.contains(&"exit clean".to_string()),
        "{log:?}"
    );
    assert!(
        http::get(port, "/api/version", None, Duration::from_millis(300)).is_err(),
        "release is gone"
    );
}

#[test]
fn stop_escalates_to_kill_when_the_release_ignores_sigterm() {
    let mut fake = Fake::new("kill", &[("FAKE_IGNORE_TERM", "1")]);
    fake.config.stop_grace = Duration::from_millis(300);
    let sup = Supervisor::start(fake.config.clone());
    sup.wait_for(WAIT, running).unwrap();
    assert_eq!(sup.stop(), StopOutcome::Killed);
    assert_eq!(sup.state(), State::Stopped);
}

#[test]
fn stop_during_backoff_does_not_relaunch() {
    let mut fake = Fake::new("stop-backoff", &[("FAKE_CRASH_FIRST_N", "5")]);
    fake.config.backoff = arbiter_shell_core::backoff::Backoff::new(
        Duration::from_secs(30),
        Duration::from_secs(30),
        Duration::from_secs(60),
    );
    let sup = Supervisor::start(fake.config.clone());
    sup.wait_for(WAIT, |s| matches!(s, State::Restarting { .. }))
        .unwrap();
    sup.stop();
    assert_eq!(sup.state(), State::Stopped);
    assert_eq!(fake.starts(), 1);
}
