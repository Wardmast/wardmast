//! A stand-in for the Arbiter release, used by the shell's tests and by
//! `scripts/desktop-shell-smoke.sh`. It binds `$WARDMAST_PORT` on loopback and
//! speaks just enough HTTP for the shell: `GET /api/version` and
//! `GET /api/scheduler/status`.
//!
//! Behaviour is driven by env vars so one binary covers every lifecycle case:
//!
//!  * `FAKE_LOG=<file>`        append `start port=<p>` / `term` / `exit` lines
//!  * `FAKE_MODE=exit`         print an error to stderr and exit 1 at boot
//!  * `FAKE_MODE=hang`         stay alive but never listen (never ready)
//!  * `FAKE_CRASH_FIRST_N=<n>` exit 1 shortly after becoming ready on the
//!                             first n launches (counted via FAKE_LOG)
//!  * `FAKE_IGNORE_TERM=1`     ignore SIGTERM (forces the shell's SIGKILL path)
//!  * `FAKE_IN_FLIGHT=<n>`     the scheduler status reports n workers in flight
//!  * `FAKE_TOKEN=<t>`         require `Authorization: Bearer <t>` on the status

use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::exit;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::sleep;
use std::time::{Duration, Instant};

static TERM: AtomicBool = AtomicBool::new(false);

extern "C" fn on_term(_sig: libc::c_int) {
    TERM.store(true, Ordering::SeqCst);
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

fn log(line: &str) {
    if let Some(path) = env("FAKE_LOG") {
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(f, "{line}");
        }
    }
}

fn main() {
    let port: u16 = env("WARDMAST_PORT")
        .and_then(|p| p.parse().ok())
        .expect("WARDMAST_PORT");
    let launches_before = env("FAKE_LOG")
        .and_then(|p| fs::read_to_string(p).ok())
        .map(|s| s.lines().filter(|l| l.starts_with("start ")).count())
        .unwrap_or(0);
    log(&format!("start port={port}"));

    let handler: extern "C" fn(libc::c_int) = on_term;
    if env("FAKE_IGNORE_TERM").is_none() {
        unsafe { libc::signal(libc::SIGTERM, handler as libc::sighandler_t) };
    } else {
        unsafe { libc::signal(libc::SIGTERM, libc::SIG_IGN) };
    }

    match env("FAKE_MODE").as_deref() {
        Some("exit") => {
            eprintln!("boom: could not start (eaddrinuse / bad config)");
            log("exit boot-failure");
            exit(1);
        }
        Some("hang") => loop {
            sleep(Duration::from_millis(50));
            if TERM.load(Ordering::SeqCst) {
                log("term");
                exit(0);
            }
        },
        _ => {}
    }

    let crash_n: usize = env("FAKE_CRASH_FIRST_N")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let crash_at = (launches_before < crash_n).then(|| Instant::now() + Duration::from_millis(250));

    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("cannot bind 127.0.0.1:{port}: {e}");
            exit(1);
        }
    };
    listener.set_nonblocking(true).unwrap();

    loop {
        if TERM.load(Ordering::SeqCst) {
            log("term");
            sleep(Duration::from_millis(
                env("FAKE_TERM_DELAY_MS")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
            ));
            log("exit clean");
            exit(0);
        }
        if crash_at.is_some_and(|t| Instant::now() >= t) {
            eprintln!("fatal: simulated crash");
            log("exit crash");
            exit(1);
        }
        match listener.accept() {
            Ok((s, _)) => handle(s),
            Err(_) => sleep(Duration::from_millis(10)),
        }
    }
}

fn handle(mut s: TcpStream) {
    let _ = s.set_nonblocking(false);
    let _ = s.set_read_timeout(Some(Duration::from_secs(1)));
    let mut buf = [0u8; 4096];
    let n = s.read(&mut buf).unwrap_or(0);
    let req = String::from_utf8_lossy(&buf[..n]).into_owned();
    let path = req.split_whitespace().nth(1).unwrap_or("/");

    let (status, body) = match path {
        "/api/version" => ("200 OK", r#"{"version":"fake"}"#.to_string()),
        "/api/scheduler/status" => {
            let authed = match env("FAKE_TOKEN") {
                Some(t) => req.contains(&format!("Authorization: Bearer {t}\r\n")),
                None => true,
            };
            if authed {
                let n: usize = env("FAKE_IN_FLIGHT")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
                let items: Vec<String> = (0..n)
                    .map(|i| format!(r#"{{"kind":"worker","task_id":"bd-fake{i}"}}"#))
                    .collect();
                let state = if n == 0 { "quiescent" } else { "draining" };
                (
                    "200 OK",
                    format!(r#"{{"state":"{state}","in_flight":[{}]}}"#, items.join(",")),
                )
            } else {
                (
                    "401 Unauthorized",
                    r#"{"error":"unauthorized"}"#.to_string(),
                )
            }
        }
        "/" => ("200 OK", "<html>fake dashboard</html>".to_string()),
        _ => ("404 Not Found", "{}".to_string()),
    };
    let _ = write!(
        s,
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}
