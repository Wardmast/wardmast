//! Starts the bundled release and keeps it alive.
//!
//! One supervisor thread owns the release process and walks this loop:
//!
//! ```text
//!   pick a free loopback port ─► spawn release (port in $WARDMAST_PORT)
//!        ─► poll the ready URL ──► Running ──► (exit) ─► Restarting{backoff} ─┐
//!                │                                                              │
//!                └─ exit / timeout before ready = boot failure                  │
//!                     fewer than max_boot_failures ─► Restarting{backoff} ──────┤
//!                     otherwise ─► BootFailed (waits for retry/stop)            │
//!        ◄───────────────────────────────────────────────────────────────────┘
//! ```
//!
//! A crash of a release that had been healthy is retried forever with
//! exponential backoff (reset after `Backoff::reset_after` of stable uptime).
//! A release that never gets ready is different: restarting it forever would
//! hide a broken install behind an endless spinner, so after
//! `max_boot_failures` in a row the supervisor stops and surfaces
//! `State::BootFailed` with the tail of the release's output.

use crate::backoff::Backoff;
use crate::http;
use crate::port::pick_port;
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// How to launch the release.
#[derive(Debug, Clone)]
pub struct ReleaseSpec {
    pub program: PathBuf,
    pub args: Vec<String>,
    /// Extra environment on top of the shell's own.
    pub env: Vec<(String, String)>,
}

impl ReleaseSpec {
    /// The real bundled release: `<dir>/bin/wardmast start` (foreground, so the
    /// pid the shell holds is the server's).
    pub fn for_release_dir(dir: impl Into<PathBuf>) -> ReleaseSpec {
        ReleaseSpec {
            program: dir.into().join("bin").join("wardmast"),
            args: vec!["start".into()],
            env: vec![],
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub release: ReleaseSpec,
    /// The env var the release reads its listen port from.
    pub port_env: String,
    /// Tried first on every launch; the server's default is 4848.
    pub preferred_port: u16,
    pub backoff: Backoff,
    /// Anonymous route polled until it answers 200.
    pub ready_path: String,
    pub ready_timeout: Duration,
    pub poll_interval: Duration,
    /// Consecutive launches that never became ready before giving up.
    pub max_boot_failures: u32,
    /// How long SIGTERM gets before SIGKILL. The server gives each worker 15s
    /// (`Wardmast.Worker.shutdown_grace_ms/0`) to reap its agent, so this must
    /// be comfortably above that.
    pub stop_grace: Duration,
    /// Lines of release output kept for the boot-failure page.
    pub log_lines: usize,
}

impl Config {
    pub fn new(release: ReleaseSpec) -> Config {
        Config {
            release,
            port_env: "WARDMAST_PORT".into(),
            preferred_port: 4848,
            backoff: Backoff::new(
                Duration::from_secs(1),
                Duration::from_secs(30),
                Duration::from_secs(60),
            ),
            ready_path: "/api/version".into(),
            ready_timeout: Duration::from_secs(60),
            poll_interval: Duration::from_millis(250),
            max_boot_failures: 3,
            stop_grace: Duration::from_secs(45),
            log_lines: 200,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    Starting {
        port: u16,
        attempt: u32,
    },
    Running {
        port: u16,
    },
    /// The release is down and will be relaunched after `delay`.
    Restarting {
        delay: Duration,
        reason: String,
    },
    /// Gave up after repeated boot failures; `retry()` or `stop()` to continue.
    BootFailed {
        reason: String,
        log_tail: Vec<String>,
    },
    Stopping,
    Stopped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopOutcome {
    /// Exited on SIGTERM within the grace period.
    Graceful,
    /// Had to be SIGKILLed.
    Killed,
    /// There was no release process to stop.
    NotRunning,
}

enum Cmd {
    Retry,
    Stop(Sender<StopOutcome>),
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
    subscribers: Mutex<Vec<Sender<State>>>,
}

impl Shared {
    fn publish(&self, next: State) {
        *self.state.lock().unwrap() = next.clone();
        self.changed.notify_all();
        self.subscribers
            .lock()
            .unwrap()
            .retain(|s| s.send(next.clone()).is_ok());
    }
}

pub struct Supervisor {
    shared: Arc<Shared>,
    cmd: Sender<Cmd>,
    join: Mutex<Option<JoinHandle<()>>>,
}

impl Supervisor {
    pub fn start(config: Config) -> Supervisor {
        let shared = Arc::new(Shared {
            state: Mutex::new(State::Starting {
                port: config.preferred_port,
                attempt: 0,
            }),
            changed: Condvar::new(),
            subscribers: Mutex::new(vec![]),
        });
        let (tx, rx) = mpsc::channel();
        let thread_shared = Arc::clone(&shared);
        let join = thread::spawn(move || run(config, thread_shared, rx));
        Supervisor {
            shared,
            cmd: tx,
            join: Mutex::new(Some(join)),
        }
    }

    pub fn state(&self) -> State {
        self.shared.state.lock().unwrap().clone()
    }

    /// The port the release is serving on, once it is ready.
    pub fn port(&self) -> Option<u16> {
        match self.state() {
            State::Running { port } => Some(port),
            _ => None,
        }
    }

    /// Every state change from now on.
    pub fn subscribe(&self) -> Receiver<State> {
        let (tx, rx) = mpsc::channel();
        self.shared.subscribers.lock().unwrap().push(tx);
        rx
    }

    /// Block until `pred` holds for the current state (checked on every
    /// change), or `timeout` passes.
    pub fn wait_for(&self, timeout: Duration, pred: impl Fn(&State) -> bool) -> Option<State> {
        let guard = self.shared.state.lock().unwrap();
        let (guard, res) = self
            .shared
            .changed
            .wait_timeout_while(guard, timeout, |s| !pred(s))
            .unwrap();
        (!res.timed_out()).then(|| guard.clone())
    }

    /// Leave `BootFailed` and try launching again.
    pub fn retry(&self) {
        let _ = self.cmd.send(Cmd::Retry);
    }

    /// Stop the release (SIGTERM, then SIGKILL after the grace period) and end
    /// supervision. Blocks until the process is gone.
    pub fn stop(&self) -> StopOutcome {
        let (tx, rx) = mpsc::channel();
        let outcome = if self.cmd.send(Cmd::Stop(tx)).is_ok() {
            rx.recv().unwrap_or(StopOutcome::NotRunning)
        } else {
            StopOutcome::NotRunning
        };
        if let Some(h) = self.join.lock().unwrap().take() {
            let _ = h.join();
        }
        outcome
    }
}

impl Drop for Supervisor {
    /// Never leave a server behind because the shell value went away.
    fn drop(&mut self) {
        self.stop();
    }
}

// ---------------------------------------------------------------- the process

type LogBuf = Arc<Mutex<VecDeque<String>>>;

struct Release {
    child: Child,
    log: LogBuf,
    readers: Vec<JoinHandle<()>>,
}

impl Release {
    fn spawn(config: &Config, port: u16) -> std::io::Result<Release> {
        let mut cmd = Command::new(&config.release.program);
        cmd.args(&config.release.args)
            .envs(config.release.env.iter().map(|(k, v)| (k, v)))
            .env(&config.port_env, port.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Its own process group: a terminal Ctrl-C aimed at the shell does
            // not reach it, and a final SIGKILL can take the whole group.
            .process_group(0);
        let mut child = cmd.spawn()?;
        let log: LogBuf = Arc::new(Mutex::new(VecDeque::new()));
        let mut readers = vec![];
        if let Some(out) = child.stdout.take() {
            readers.push(pump(out, Arc::clone(&log), config.log_lines));
        }
        if let Some(err) = child.stderr.take() {
            readers.push(pump(err, Arc::clone(&log), config.log_lines));
        }
        Ok(Release {
            child,
            log,
            readers,
        })
    }

    fn try_wait(&mut self) -> Option<ExitStatus> {
        self.child.try_wait().ok().flatten()
    }

    /// Give the output readers a moment to drain after the process exited. A
    /// grandchild that inherited the pipes could hold them open, so this is
    /// bounded rather than a join.
    fn settle_log(&mut self) {
        for _ in 0..30 {
            if self.readers.iter().all(|h| h.is_finished()) {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn log_tail(&mut self) -> Vec<String> {
        self.settle_log();
        self.log.lock().unwrap().iter().cloned().collect()
    }

    fn stop(&mut self, grace: Duration) -> StopOutcome {
        if self.try_wait().is_some() {
            return StopOutcome::NotRunning;
        }
        let pid = self.child.id() as libc::pid_t;
        unsafe { libc::kill(pid, libc::SIGTERM) };
        let deadline = Instant::now() + grace;
        while Instant::now() < deadline {
            if self.try_wait().is_some() {
                return StopOutcome::Graceful;
            }
            thread::sleep(Duration::from_millis(20));
        }
        // Escalate: the whole group, then reap.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
        let _ = self.child.kill();
        let _ = self.child.wait();
        StopOutcome::Killed
    }
}

fn pump(src: impl Read + Send + 'static, log: LogBuf, cap: usize) -> JoinHandle<()> {
    thread::spawn(move || {
        for line in BufReader::new(src).lines().map_while(Result::ok) {
            let mut buf = log.lock().unwrap();
            if buf.len() >= cap {
                buf.pop_front();
            }
            buf.push_back(line);
        }
    })
}

// ------------------------------------------------------------------- the loop

enum Ready {
    Yes,
    Failed(String),
    Stop(Sender<StopOutcome>),
}

fn wait_ready(release: &mut Release, config: &Config, port: u16, rx: &Receiver<Cmd>) -> Ready {
    let deadline = Instant::now() + config.ready_timeout;
    loop {
        if let Some(status) = release.try_wait() {
            return Ready::Failed(format!("release exited during boot ({status})"));
        }
        let ok = http::get(port, &config.ready_path, None, Duration::from_millis(500))
            .map(|r| r.status == 200)
            .unwrap_or(false);
        if ok {
            return Ready::Yes;
        }
        if Instant::now() >= deadline {
            return Ready::Failed(format!(
                "release was not ready within {}s",
                config.ready_timeout.as_secs_f32()
            ));
        }
        match rx.recv_timeout(config.poll_interval) {
            Ok(Cmd::Stop(reply)) => return Ready::Stop(reply),
            Ok(Cmd::Retry) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Ready::Failed("shell went away".into()),
        }
    }
}

enum Watched {
    Exited(ExitStatus),
    Stop(Sender<StopOutcome>),
}

fn monitor(release: &mut Release, config: &Config, rx: &Receiver<Cmd>) -> Watched {
    loop {
        if let Some(status) = release.try_wait() {
            return Watched::Exited(status);
        }
        match rx.recv_timeout(config.poll_interval) {
            Ok(Cmd::Stop(reply)) => return Watched::Stop(reply),
            Ok(Cmd::Retry) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Watched::Stop(mpsc::channel().0),
        }
    }
}

enum Slept {
    Elapsed,
    Stop(Sender<StopOutcome>),
}

fn sleep_or_stop(rx: &Receiver<Cmd>, delay: Duration) -> Slept {
    let deadline = Instant::now() + delay;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Slept::Elapsed;
        }
        match rx.recv_timeout(left) {
            Ok(Cmd::Stop(reply)) => return Slept::Stop(reply),
            Ok(Cmd::Retry) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Slept::Elapsed,
        }
    }
}

fn finish(shared: &Shared, reply: Sender<StopOutcome>, outcome: StopOutcome) {
    shared.publish(State::Stopped);
    let _ = reply.send(outcome);
}

fn run(config: Config, shared: Arc<Shared>, rx: Receiver<Cmd>) {
    let mut backoff = config.backoff.clone();
    let mut boot_failures = 0u32;
    let mut attempt = 0u32;
    let mut last_port: Option<u16> = None;

    loop {
        attempt += 1;
        let preferred = last_port.unwrap_or(config.preferred_port);
        let port = match pick_port(preferred) {
            Ok(p) => p,
            Err(e) => {
                if let Some(reply) = give_up_or_wait(
                    &shared,
                    &rx,
                    &mut boot_failures,
                    &mut backoff,
                    &config,
                    format!("no free loopback port: {e}"),
                    vec![],
                ) {
                    finish(&shared, reply, StopOutcome::NotRunning);
                    return;
                }
                continue;
            }
        };
        shared.publish(State::Starting { port, attempt });

        let mut release = match Release::spawn(&config, port) {
            Ok(r) => r,
            Err(e) => {
                let reason = format!("could not launch {}: {e}", config.release.program.display());
                if let Some(reply) = give_up_or_wait(
                    &shared,
                    &rx,
                    &mut boot_failures,
                    &mut backoff,
                    &config,
                    reason,
                    vec![],
                ) {
                    finish(&shared, reply, StopOutcome::NotRunning);
                    return;
                }
                continue;
            }
        };

        match wait_ready(&mut release, &config, port, &rx) {
            Ready::Stop(reply) => {
                shared.publish(State::Stopping);
                let outcome = release.stop(config.stop_grace);
                finish(&shared, reply, outcome);
                return;
            }
            Ready::Failed(reason) => {
                // Make sure a hung (alive but never ready) release is gone.
                release.stop(Duration::from_millis(500));
                let tail = release.log_tail();
                if let Some(reply) = give_up_or_wait(
                    &shared,
                    &rx,
                    &mut boot_failures,
                    &mut backoff,
                    &config,
                    reason,
                    tail,
                ) {
                    finish(&shared, reply, StopOutcome::NotRunning);
                    return;
                }
            }
            Ready::Yes => {
                last_port = Some(port);
                boot_failures = 0;
                let up_since = Instant::now();
                shared.publish(State::Running { port });
                match monitor(&mut release, &config, &rx) {
                    Watched::Stop(reply) => {
                        shared.publish(State::Stopping);
                        let outcome = release.stop(config.stop_grace);
                        finish(&shared, reply, outcome);
                        return;
                    }
                    Watched::Exited(status) => {
                        let delay = backoff.next_delay(up_since.elapsed());
                        shared.publish(State::Restarting {
                            delay,
                            reason: format!("release exited ({status})"),
                        });
                        if let Slept::Stop(reply) = sleep_or_stop(&rx, delay) {
                            finish(&shared, reply, StopOutcome::NotRunning);
                            return;
                        }
                    }
                }
            }
        }
    }
}

/// A launch failed before the release became ready. Either schedule another
/// attempt (returns `None` once the delay passed) or, after too many in a row,
/// publish `BootFailed` and wait for `retry` (returns `None`) / `stop`
/// (returns the reply channel).
fn give_up_or_wait(
    shared: &Shared,
    rx: &Receiver<Cmd>,
    boot_failures: &mut u32,
    backoff: &mut Backoff,
    config: &Config,
    reason: String,
    log_tail: Vec<String>,
) -> Option<Sender<StopOutcome>> {
    *boot_failures += 1;
    if *boot_failures < config.max_boot_failures {
        let delay = backoff.next_delay(Duration::ZERO);
        shared.publish(State::Restarting { delay, reason });
        return match sleep_or_stop(rx, delay) {
            Slept::Stop(reply) => Some(reply),
            Slept::Elapsed => None,
        };
    }
    shared.publish(State::BootFailed { reason, log_tail });
    loop {
        match rx.recv() {
            Ok(Cmd::Retry) => {
                *boot_failures = 0;
                backoff.reset();
                return None;
            }
            Ok(Cmd::Stop(reply)) => return Some(reply),
            Err(_) => return Some(mpsc::channel().0),
        }
    }
}
