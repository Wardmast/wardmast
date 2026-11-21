#![allow(dead_code)]
use arbiter_shell_core::backoff::Backoff;
use arbiter_shell_core::http;
use arbiter_shell_core::release_lock::{self, Record};
use arbiter_shell_core::supervisor::{Config, ReleaseSpec};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub struct Fake {
    pub log: PathBuf,
    /// Where the data home would live; `config.data_home` stays `None` until
    /// `enable_data_home` so only the pidfile tests exercise it.
    pub data_home: PathBuf,
    pub config: Config,
}

impl Fake {
    /// A supervisor config that runs the fake release with `env`, tuned for
    /// fast tests (tens of milliseconds instead of seconds).
    pub fn new(name: &str, env: &[(&str, &str)]) -> Fake {
        let dir = std::env::temp_dir().join(format!("arb-shell-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("fake.log");
        let _ = std::fs::remove_file(&log);
        let mut e: Vec<(String, String)> =
            vec![("FAKE_LOG".into(), log.to_string_lossy().into_owned())];
        e.extend(env.iter().map(|(k, v)| (k.to_string(), v.to_string())));
        let mut config = Config::new(ReleaseSpec {
            program: PathBuf::from(env!("CARGO_BIN_EXE_fake_release")),
            args: vec![],
            env: e,
        });
        config.backoff = Backoff::new(
            Duration::from_millis(50),
            Duration::from_millis(200),
            Duration::from_secs(30),
        );
        config.ready_timeout = Duration::from_secs(5);
        config.poll_interval = Duration::from_millis(20);
        config.stop_grace = Duration::from_secs(3);
        // Tests run in parallel and a release that never binds (`FAKE_MODE=hang`)
        // leaves its probed port free, so a shared preferred port (4848) lets a
        // sibling test's fake claim it and answer the hang test's readiness probe.
        // Port 0 gives every launch its own OS-assigned port instead.
        config.preferred_port = 0;
        let data_home = dir.join("data");
        let _ = std::fs::remove_dir_all(&data_home);
        Fake {
            log,
            data_home,
            config,
        }
    }

    pub fn log_lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.log)
            .map(|s| s.lines().map(str::to_string).collect())
            .unwrap_or_default()
    }

    pub fn starts(&self) -> usize {
        self.log_lines()
            .iter()
            .filter(|l| l.starts_with("start "))
            .count()
    }
}

pub const WAIT: Duration = Duration::from_secs(10);

impl Fake {
    /// Turn on the pidfile + launch lock for this config.
    pub fn enable_data_home(&mut self) {
        self.config.data_home = Some(self.data_home.clone());
    }
}

/// A free loopback port (probe-and-release; fine for tests).
pub fn free_port() -> u16 {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    l.local_addr().unwrap().port()
}

/// A process the test plays "orphaned release" with. SIGKILLed on drop so a
/// failing assertion never leaves one behind (exact pid, never a pattern).
pub struct Orphan {
    pub pid: u32,
    pub port: u16,
}

impl Drop for Orphan {
    fn drop(&mut self) {
        if !release_lock::pid_alive(self.pid) {
            return;
        }
        unsafe {
            libc::kill(-(self.pid as libc::pid_t), libc::SIGKILL);
            libc::kill(self.pid as libc::pid_t, libc::SIGKILL);
        }
    }
}

fn reap_in_background(mut child: std::process::Child) {
    std::thread::spawn(move || {
        let _ = child.wait();
    });
}

/// The fake release on its own port, in its own process group, logging to
/// `log`. Waits until it answers. No pidfile is written.
pub fn spawn_fake(log: &Path, env: &[(&str, &str)]) -> Orphan {
    let port = free_port();
    let child = Command::new(env!("CARGO_BIN_EXE_fake_release"))
        .env("WARDMAST_PORT", port.to_string())
        .env("FAKE_LOG", log)
        .envs(env.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    let pid = child.id();
    reap_in_background(child);
    let orphan = Orphan { pid, port };
    let deadline = Instant::now() + WAIT;
    while http::get(port, "/api/version", None, Duration::from_millis(200)).is_err() {
        assert!(Instant::now() < deadline, "fake release never answered");
        std::thread::sleep(Duration::from_millis(20));
    }
    orphan
}

/// Start the fake release on its own, as a shell that then died would have
/// left it (own process group, sharing `fake`'s log), wait until it answers,
/// and write the pidfile a shell would have written.
pub fn spawn_orphan(fake: &Fake, env: &[(&str, &str)]) -> Orphan {
    let orphan = spawn_fake(&fake.log, env);
    release_lock::write(
        &fake.data_home,
        &Record {
            pid: orphan.pid,
            port: orphan.port,
            version: None,
            start_time: release_lock::start_time(orphan.pid),
        },
    )
    .unwrap();
    orphan
}

/// A live process that holds a pid but serves nothing (stands in for a hung
/// release), recorded in the pidfile with a port nobody listens on.
pub fn spawn_silent_holder(fake: &Fake) -> Orphan {
    let mut holder = spawn_sleeper();
    holder.port = free_port();
    release_lock::write(
        &fake.data_home,
        &Record {
            pid: holder.pid,
            port: holder.port,
            version: None,
            start_time: release_lock::start_time(holder.pid),
        },
    )
    .unwrap();
    holder
}

/// An unrelated live process (`sleep`), SIGKILLed on drop. Stands in for
/// whatever reused a dead release's pid.
pub fn spawn_sleeper() -> Orphan {
    let child = Command::new("sleep")
        .arg("60")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    let pid = child.id();
    reap_in_background(child);
    Orphan { pid, port: 0 }
}
