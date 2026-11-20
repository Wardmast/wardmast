mod common;

use arbiter_shell_core::http;
use arbiter_shell_core::quit::{LiveWork, QuitPrompt};
use arbiter_shell_core::shell::{CloseAction, QuitOutcome, Shell};
use arbiter_shell_core::supervisor::{State, StopOutcome};
use common::{Fake, WAIT};
use std::sync::Mutex;
use std::time::Duration;

struct Prompt {
    answer: bool,
    seen: Mutex<Vec<LiveWork>>,
}

impl Prompt {
    fn new(answer: bool) -> Prompt {
        Prompt {
            answer,
            seen: Mutex::new(vec![]),
        }
    }
}

impl QuitPrompt for Prompt {
    fn confirm_quit(&self, live: &LiveWork) -> bool {
        self.seen.lock().unwrap().push(live.clone());
        self.answer
    }
}

fn started(fake: &Fake) -> (Shell, u16) {
    let shell = Shell::start(fake.config.clone(), None);
    match shell
        .supervisor()
        .wait_for(WAIT, |s| matches!(s, State::Running { .. }))
        .unwrap()
    {
        State::Running { port } => (shell, port),
        _ => unreachable!(),
    }
}

#[test]
fn the_dashboard_url_points_at_the_port_the_release_got() {
    let fake = Fake::new("url", &[]);
    let (shell, port) = started(&fake);
    assert_eq!(
        shell.dashboard_url(),
        Some(format!("http://127.0.0.1:{port}/"))
    );
    assert_eq!(
        http::get(port, "/", None, Duration::from_secs(2))
            .unwrap()
            .status,
        200
    );
    shell.request_quit(&Prompt::new(true));
}

#[test]
fn closing_the_window_hides_it_and_keeps_the_server_running() {
    let fake = Fake::new("close", &[]);
    let (shell, port) = started(&fake);
    assert_eq!(shell.window_closed(), CloseAction::HideToTray);
    assert_eq!(shell.supervisor().state(), State::Running { port });
    assert_eq!(
        http::get(port, "/api/version", None, Duration::from_secs(2))
            .unwrap()
            .status,
        200
    );
    assert!(!fake.log_lines().contains(&"term".to_string()));
    shell.request_quit(&Prompt::new(true));
}

#[test]
fn quit_with_nothing_running_does_not_ask_and_stops_the_release() {
    let fake = Fake::new("quit-idle", &[("FAKE_IN_FLIGHT", "0")]);
    let (shell, _) = started(&fake);
    let prompt = Prompt::new(false);
    assert_eq!(
        shell.request_quit(&prompt),
        QuitOutcome::Quit(StopOutcome::Graceful)
    );
    assert!(
        prompt.seen.lock().unwrap().is_empty(),
        "no prompt when nothing is in flight"
    );
    assert_eq!(shell.supervisor().state(), State::Stopped);
    assert!(fake.log_lines().contains(&"exit clean".to_string()));
}

#[test]
fn quit_with_live_workers_asks_and_declining_keeps_everything_running() {
    let fake = Fake::new("quit-decline", &[("FAKE_IN_FLIGHT", "2")]);
    let (shell, port) = started(&fake);
    let prompt = Prompt::new(false);
    assert_eq!(shell.request_quit(&prompt), QuitOutcome::Cancelled);
    assert_eq!(*prompt.seen.lock().unwrap(), vec![LiveWork::Busy(2)]);
    assert_eq!(shell.supervisor().state(), State::Running { port });
    assert!(!fake.log_lines().contains(&"term".to_string()));
    // Confirming later still works.
    assert!(matches!(
        shell.request_quit(&Prompt::new(true)),
        QuitOutcome::Quit(_)
    ));
}

#[test]
fn quit_with_live_workers_confirmed_stops_the_release_gracefully() {
    let fake = Fake::new("quit-confirm", &[("FAKE_IN_FLIGHT", "3")]);
    let (shell, _) = started(&fake);
    let prompt = Prompt::new(true);
    assert_eq!(
        shell.request_quit(&prompt),
        QuitOutcome::Quit(StopOutcome::Graceful)
    );
    assert_eq!(*prompt.seen.lock().unwrap(), vec![LiveWork::Busy(3)]);
    // SIGTERM (so the server's own shutdown path marks runs interrupted for the
    // reconciler), not a kill.
    let log = fake.log_lines();
    assert!(
        log.contains(&"term".to_string()) && log.contains(&"exit clean".to_string()),
        "{log:?}"
    );
}

#[test]
fn quit_asks_when_the_drain_state_cannot_be_read() {
    // The status route needs a token the shell does not have: unknown is not "idle".
    let fake = Fake::new(
        "quit-unknown",
        &[("FAKE_TOKEN", "secret"), ("FAKE_IN_FLIGHT", "1")],
    );
    let (shell, _) = started(&fake);
    let prompt = Prompt::new(false);
    assert_eq!(shell.request_quit(&prompt), QuitOutcome::Cancelled);
    match &prompt.seen.lock().unwrap()[..] {
        [LiveWork::Unknown(why)] => assert!(why.contains("401"), "{why}"),
        other => panic!("expected one Unknown prompt, got {other:?}"),
    }
    shell.request_quit(&Prompt::new(true));
}

#[test]
fn the_api_token_lets_the_shell_read_the_drain_state() {
    let fake = Fake::new(
        "quit-token",
        &[("FAKE_TOKEN", "secret"), ("FAKE_IN_FLIGHT", "1")],
    );
    let shell = Shell::start(fake.config.clone(), Some("secret".into()));
    shell
        .supervisor()
        .wait_for(WAIT, |s| matches!(s, State::Running { .. }))
        .unwrap();
    assert_eq!(shell.live_work(), LiveWork::Busy(1));
    shell.request_quit(&Prompt::new(true));
}

#[test]
fn quit_while_the_release_is_not_running_just_stops_without_asking() {
    let mut fake = Fake::new("quit-bootfail", &[("FAKE_MODE", "exit")]);
    fake.config.max_boot_failures = 1;
    let shell = Shell::start(fake.config.clone(), None);
    shell
        .supervisor()
        .wait_for(WAIT, |s| matches!(s, State::BootFailed { .. }))
        .unwrap();
    let prompt = Prompt::new(false);
    assert!(matches!(shell.request_quit(&prompt), QuitOutcome::Quit(_)));
    assert!(prompt.seen.lock().unwrap().is_empty());
    assert_eq!(shell.supervisor().state(), State::Stopped);
}
