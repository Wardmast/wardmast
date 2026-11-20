#![allow(dead_code)]
use arbiter_shell_core::backoff::Backoff;
use arbiter_shell_core::supervisor::{Config, ReleaseSpec};
use std::path::PathBuf;
use std::time::Duration;

pub struct Fake {
    pub log: PathBuf,
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
        Fake { log, config }
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
