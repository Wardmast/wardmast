//! A windowless shell: the same `Shell` core the Tauri window drives, with the
//! "window" replaced by stdout lines and stdin commands. It exists so the
//! lifecycle can be exercised end to end, in separate OS processes, without a
//! GUI toolchain (`tests/headless.rs`), and so a real release directory can be
//! smoke-tested by hand:
//!
//! ```text
//! SHELL_RELEASE_DIR=/path/to/release cargo run -p arbiter-shell-core --bin headless
//! ```
//!
//! Environment: `SHELL_SOCKET` (single-instance socket; default under
//! `$XDG_RUNTIME_DIR`/tmp), `SHELL_RELEASE_DIR` (real release) or
//! `SHELL_RELEASE_PROGRAM` (any executable), `SHELL_PREFERRED_PORT` (default
//! 4848), `SHELL_MAX_BOOT_FAILURES`, `SHELL_DATA_HOME` (pidfile/lock directory; off
//! when unset), `SHELL_EXPECTED_VERSION`, `SHELL_API_TOKEN`, `SHELL_QUIT_ANSWER`
//! (`yes`/`no`, default `yes`).
//!
//! Stdin commands: `close`, `quit`, `retry`, `answer yes|no`. EOF quits.

use arbiter_shell_core::quit::{LiveWork, QuitPrompt};
use arbiter_shell_core::shell::{CloseAction, QuitOutcome, Shell};
use arbiter_shell_core::single_instance::{self, Acquired};
use arbiter_shell_core::supervisor::{Config, ReleaseSpec, State, StopOutcome};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::process::exit;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

fn say(line: &str) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

struct Prompt(Arc<AtomicBool>);

impl QuitPrompt for Prompt {
    fn confirm_quit(&self, live: &LiveWork) -> bool {
        match live {
            LiveWork::Busy(n) => say(&format!("quit-prompt busy={n}")),
            LiveWork::Unknown(why) => say(&format!("quit-prompt unknown={why}")),
            LiveWork::Idle => {}
        }
        self.0.load(Ordering::SeqCst)
    }
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn socket_path() -> PathBuf {
    env("SHELL_SOCKET").map(PathBuf::from).unwrap_or_else(|| {
        let base = env("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        base.join("arbiter-shell.sock")
    })
}

fn config() -> Config {
    let release = match (env("SHELL_RELEASE_PROGRAM"), env("SHELL_RELEASE_DIR")) {
        (Some(program), _) => ReleaseSpec {
            program: program.into(),
            args: vec![],
            env: vec![],
        },
        (None, Some(dir)) => ReleaseSpec::for_release_dir(dir),
        _ => {
            eprintln!("set SHELL_RELEASE_DIR (or SHELL_RELEASE_PROGRAM)");
            exit(2);
        }
    };
    let mut c = Config::new(release);
    if let Some(p) = env("SHELL_PREFERRED_PORT").and_then(|v| v.parse().ok()) {
        c.preferred_port = p;
    }
    // Opt-in: the pidfile + launch lock live in this directory (the shell proper
    // uses `release_lock::resolve_data_home()`; smoke runs must not touch the
    // real one).
    c.data_home = env("SHELL_DATA_HOME").map(PathBuf::from);
    c.expected_version = env("SHELL_EXPECTED_VERSION").or_else(|| {
        env("SHELL_RELEASE_DIR").and_then(|d| {
            arbiter_shell_core::release_lock::bundled_version(std::path::Path::new(&d))
        })
    });
    if let Some(n) = env("SHELL_MAX_BOOT_FAILURES").and_then(|v| v.parse().ok()) {
        c.max_boot_failures = n;
    }
    c.poll_interval = std::time::Duration::from_millis(50);
    c
}

fn main() {
    let guard = match single_instance::acquire(&socket_path(), || say("focus-requested")) {
        Ok(Acquired::Primary(g)) => g,
        Ok(Acquired::Secondary) => {
            say("focused-existing-instance");
            return;
        }
        Err(e) => {
            eprintln!("single-instance: {e}");
            exit(1);
        }
    };

    let shell = Shell::start(config(), env("SHELL_API_TOKEN"));
    let events = shell.supervisor().subscribe();
    thread::spawn(move || {
        for state in events {
            match state {
                State::Running { port } => say(&format!("dashboard http://127.0.0.1:{port}/")),
                State::Starting { port, attempt } => {
                    say(&format!("starting port={port} attempt={attempt}"))
                }
                State::Restarting { delay, reason } => {
                    say(&format!("restarting in={delay:?} {reason}"))
                }
                State::BootFailed { reason, log_tail } => {
                    say(&format!("boot-failed {reason}"));
                    log_tail.iter().for_each(|l| say(&format!("log {l}")));
                }
                State::Stopping | State::Stopped => {}
            }
        }
    });

    let answer = Arc::new(AtomicBool::new(
        env("SHELL_QUIT_ANSWER").as_deref() != Some("no"),
    ));
    let prompt = Prompt(Arc::clone(&answer));

    for line in io::stdin().lock().lines().map_while(Result::ok) {
        match line.trim() {
            "close" => {
                let CloseAction::HideToTray = shell.window_closed();
                say("window-hidden");
            }
            "retry" => shell.supervisor().retry(),
            "answer yes" => answer.store(true, Ordering::SeqCst),
            "answer no" => answer.store(false, Ordering::SeqCst),
            "quit" => {
                if quit(&shell, &prompt) {
                    drop(guard);
                    return;
                }
            }
            _ => {}
        }
    }
    // stdin closed: the "window" is gone and nobody can answer a prompt.
    shell.supervisor().stop();
    drop(guard);
}

/// Returns `true` when the shell should exit.
fn quit(shell: &Shell, prompt: &Prompt) -> bool {
    match shell.request_quit(prompt) {
        QuitOutcome::Cancelled => {
            say("quit cancelled");
            false
        }
        QuitOutcome::Quit(outcome) => {
            say(match outcome {
                StopOutcome::Graceful => "quit stopped graceful",
                StopOutcome::Killed => "quit stopped killed",
                StopOutcome::NotRunning => "quit stopped not-running",
            });
            true
        }
    }
}
