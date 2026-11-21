//! The scripted smoke test: drives the real `headless` shell binary (the same
//! core the windowed shell uses) against the fake release, as separate OS
//! processes, the way a user's launches would be.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::Duration;

struct Shell {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Shell {
    fn launch(dir: &PathBuf, extra_env: &[(&str, &str)]) -> Shell {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_headless"));
        // A relative socket path keeps it under the sun_path limit however long
        // the temp dir is.
        cmd.current_dir(dir)
            .env("SHELL_SOCKET", "shell.sock")
            .env("SHELL_RELEASE_PROGRAM", env!("CARGO_BIN_EXE_fake_release"))
            .env("FAKE_LOG", dir.join("fake.log"))
            .env("SHELL_PREFERRED_PORT", "0")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        for (k, v) in extra_env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().unwrap();
        let stdin = child.stdin.take().unwrap();
        let out = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        thread::spawn(move || {
            for l in BufReader::new(out).lines().map_while(Result::ok) {
                if tx.send(l).is_err() {
                    break;
                }
            }
        });
        Shell {
            child,
            stdin,
            lines,
        }
    }

    fn expect_line(&self, starts_with: &str) -> String {
        loop {
            let l = self
                .lines
                .recv_timeout(Duration::from_secs(10))
                .unwrap_or_else(|e| panic!("waiting for {starts_with:?}: {e:?}"));
            if l.starts_with(starts_with) {
                return l;
            }
        }
    }

    fn send(&mut self, cmd: &str) {
        writeln!(self.stdin, "{cmd}").unwrap();
        self.stdin.flush().unwrap();
    }
}

fn workdir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arb-headless-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn log(dir: &PathBuf) -> Vec<String> {
    std::fs::read_to_string(dir.join("fake.log"))
        .map(|s| s.lines().map(str::to_string).collect())
        .unwrap_or_default()
}

#[test]
fn a_second_launch_focuses_the_first_and_starts_no_second_server() {
    let dir = workdir("second-launch");
    let mut first = Shell::launch(&dir, &[]);
    let url = first.expect_line("dashboard ");
    assert!(url.starts_with("dashboard http://127.0.0.1:"), "{url}");

    let mut second = Shell::launch(&dir, &[]);
    second.expect_line("focused-existing-instance");
    let status = second.child.wait().unwrap();
    assert!(status.success());
    first.expect_line("focus-requested");

    // Still exactly one server was ever started.
    assert_eq!(
        log(&dir).iter().filter(|l| l.starts_with("start ")).count(),
        1
    );

    first.send("quit");
    first.expect_line("quit ");
    assert!(first.child.wait().unwrap().success());
    assert!(log(&dir).contains(&"exit clean".to_string()));
}

#[test]
fn close_keeps_the_server_up_and_quit_with_live_workers_asks_then_stops() {
    let dir = workdir("close-quit");
    let mut sh = Shell::launch(
        &dir,
        &[("FAKE_IN_FLIGHT", "2"), ("SHELL_QUIT_ANSWER", "no")],
    );
    sh.expect_line("dashboard ");

    sh.send("close");
    sh.expect_line("window-hidden");
    assert!(
        !log(&dir).contains(&"term".to_string()),
        "close must not stop the server"
    );

    sh.send("quit");
    sh.expect_line("quit-prompt busy=2");
    sh.expect_line("quit cancelled");
    assert!(
        !log(&dir).contains(&"term".to_string()),
        "declined quit keeps the server"
    );

    // Now the user agrees.
    sh.send("answer yes");
    sh.send("quit");
    sh.expect_line("quit-prompt busy=2");
    sh.expect_line("quit stopped graceful");
    assert!(sh.child.wait().unwrap().success());
    let l = log(&dir);
    assert!(
        l.contains(&"term".to_string()) && l.contains(&"exit clean".to_string()),
        "{l:?}"
    );
}

#[test]
fn a_boot_failure_is_reported_and_the_shell_can_still_quit() {
    let dir = workdir("bootfail");
    let mut sh = Shell::launch(
        &dir,
        &[("FAKE_MODE", "exit"), ("SHELL_MAX_BOOT_FAILURES", "1")],
    );
    let l = sh.expect_line("boot-failed ");
    assert!(l.contains("exited"), "{l}");
    sh.expect_line("log boom");
    sh.send("quit");
    sh.expect_line("quit stopped");
    assert!(sh.child.wait().unwrap().success());
}

#[test]
fn an_os_level_quit_with_live_workers_prompts_and_never_kills_the_server_silently() {
    let dir = workdir("os-quit");
    let mut sh = Shell::launch(
        &dir,
        &[("FAKE_IN_FLIGHT", "2"), ("SHELL_QUIT_ANSWER", "no")],
    );
    sh.expect_line("dashboard ");

    // Cmd+Q / RunEvent::ExitRequested: intercepted, prompts, declined.
    sh.send("os-quit");
    sh.expect_line("os-exit-prevented");
    sh.expect_line("quit-prompt busy=2");
    sh.expect_line("quit cancelled");
    assert!(
        !log(&dir).contains(&"term".to_string()),
        "a declined OS quit must keep the server"
    );

    // The user agrees on the next attempt: the release is drained, then exit.
    sh.send("answer yes");
    sh.send("os-quit");
    sh.expect_line("os-exit-prevented");
    sh.expect_line("quit-prompt busy=2");
    sh.expect_line("quit stopped graceful");
    assert!(sh.child.wait().unwrap().success());
    let l = log(&dir);
    assert!(
        l.contains(&"term".to_string()) && l.contains(&"exit clean".to_string()),
        "{l:?}"
    );
}

#[test]
fn the_default_single_instance_socket_lives_in_the_app_runtime_dir() {
    let dir = workdir("runtime-dir");
    // Relative to the shell's cwd (`dir`), to stay under the sun_path limit.
    let runtime = dir.join("xdg");
    let mut sh = Shell::launch(
        &dir,
        &[("SHELL_SOCKET", ""), ("XDG_RUNTIME_DIR", "xdg")],
    );
    sh.expect_line("dashboard ");
    assert!(
        runtime.join("arbiter").join("shell.sock").exists(),
        "socket should be under $XDG_RUNTIME_DIR/arbiter"
    );
    sh.send("quit");
    sh.expect_line("quit stopped");
    assert!(sh.child.wait().unwrap().success());
}
