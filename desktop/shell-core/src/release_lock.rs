//! The pidfile and launch lock that keep two servers off one database.
//!
//! The release runs in its own process group, so a SIGKILLed shell leaves it
//! orphaned and still holding the database. Without a record the next shell
//! would find the port taken, pick another one and start a SECOND server on
//! the same data home. Two files in the data home prevent that:
//!
//! * `desktop-release.json`, `{"pid":…,"port":…,"version":…,"start_time":…}`, written
//!   (atomically) right after the shell spawns a release and removed when the
//!   shell stops it. A record whose pid is alive means "a release owns this
//!   data home".
//! * `desktop-release.lock`, an exclusive `flock` held only while a shell
//!   decides what to do (inspect the record, adopt / replace / start, write the
//!   new record). It is what makes two shells launched at once start exactly
//!   one server: the second one waits, then sees the first one's record.
//!
//! The lock is deliberately not held for the release's lifetime: a flock dies
//! with the shell, the release does not, so only the pid says whether the
//! database is in use.
//!
//! The supervisor (`supervisor.rs`) owns the policy; this module is the
//! mechanism.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

pub const PIDFILE: &str = "desktop-release.json";
pub const LOCKFILE: &str = "desktop-release.lock";

/// What the shell records about the release it started.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub pid: u32,
    pub port: u16,
    /// The version the shell expected when it started the release (the live
    /// `GET /api/version` answer, not this field, decides adopt vs. replace).
    pub version: Option<String>,
    /// The release process's start time (`start_time(pid)`) when it was
    /// recorded. It is the identity of the process: a pid alone can be reused by
    /// an unrelated process after the release dies, and the shell must never
    /// adopt or signal that. `None` only when it could not be read.
    pub start_time: Option<String>,
}

impl Record {
    fn to_json(&self) -> String {
        serde_json::json!({
            "pid": self.pid,
            "port": self.port,
            "version": self.version,
            "start_time": self.start_time,
        })
        .to_string()
    }

    /// The record names this very process: its pid is running and its start
    /// time still matches the recorded one. A different start time means the
    /// pid was reused, so the record is stale.
    ///
    /// A record with no start time (it could not be read when written) cannot
    /// be told apart, so it falls back to "the pid is running".
    pub fn holds_process(&self) -> bool {
        if !pid_alive(self.pid) {
            return false;
        }
        match (&self.start_time, start_time(self.pid)) {
            (Some(recorded), Some(now)) => *recorded == now,
            // The process vanished while we looked.
            (Some(_), None) => false,
            (None, _) => true,
        }
    }

    /// `None` for anything that is not a well-formed record. A pid of 0 or 1
    /// is rejected too: `kill(0, …)` would signal the shell's own group.
    fn from_json(raw: &str) -> Option<Record> {
        let v: serde_json::Value = serde_json::from_str(raw).ok()?;
        let pid = u32::try_from(v.get("pid")?.as_u64()?).ok()?;
        let port = u16::try_from(v.get("port")?.as_u64()?).ok()?;
        if pid <= 1 {
            return None;
        }
        Some(Record {
            pid,
            port,
            version: v
                .get("version")
                .and_then(|x| x.as_str())
                .map(str::to_string),
            start_time: v
                .get("start_time")
                .and_then(|x| x.as_str())
                .map(str::to_string),
        })
    }
}

pub fn pidfile_path(home: &Path) -> PathBuf {
    home.join(PIDFILE)
}

/// The recorded release, or `None` when there is no (readable) record.
pub fn read(home: &Path) -> Option<Record> {
    fs::read_to_string(pidfile_path(home))
        .ok()
        .and_then(|raw| Record::from_json(&raw))
}

/// Write the record atomically (temp file + rename) so a crash mid-write can
/// never leave a half-written pidfile that reads as "nothing is running".
pub fn write(home: &Path, record: &Record) -> io::Result<()> {
    fs::create_dir_all(home)?;
    let tmp = home.join(format!("{PIDFILE}.{}.tmp", std::process::id()));
    fs::write(&tmp, record.to_json())?;
    fs::rename(&tmp, pidfile_path(home))
}

/// Remove the record unconditionally (stale or unreadable).
pub fn remove(home: &Path) {
    let _ = fs::remove_file(pidfile_path(home));
}

/// Remove the record only if it still names `pid`, so a shell never deletes a
/// record another shell wrote for a different release.
pub fn remove_if_pid(home: &Path, pid: u32) {
    if read(home).is_some_and(|r| r.pid == pid) {
        remove(home);
    }
}

/// Exclusive hold on the data home's launch decision. Released on drop.
#[derive(Debug)]
pub struct LaunchLock {
    _file: File,
}

/// Try to take the launch lock without blocking: `Ok(None)` when another
/// shell (or another supervisor in this process) holds it.
pub fn try_lock(home: &Path) -> io::Result<Option<LaunchLock>> {
    fs::create_dir_all(home)?;
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(home.join(LOCKFILE))?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        return Ok(Some(LaunchLock { _file: file }));
    }
    let err = io::Error::last_os_error();
    if err.kind() == io::ErrorKind::WouldBlock {
        Ok(None)
    } else {
        Err(err)
    }
}

/// Is a process with this pid running? A zombie (exited, not yet reaped) does
/// not count: it holds no database.
pub fn pid_alive(pid: u32) -> bool {
    let Ok(p) = i32::try_from(pid) else {
        return false;
    };
    if p <= 1 {
        return false;
    }
    let rc = unsafe { libc::kill(p, 0) };
    // EPERM: it exists but belongs to someone else.
    let exists = rc == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
    exists && !is_zombie(pid)
}

/// An opaque identity for the running process `pid`: its start time. Two
/// processes that ever had the same pid never share it.
///
/// Linux: field 22 of `/proc/<pid>/stat` (clock ticks since boot). Elsewhere
/// (macOS): `ps -o lstart=` with a fixed locale. `None` when the process does
/// not exist or the platform tool is unavailable.
#[cfg(target_os = "linux")]
pub fn start_time(pid: u32) -> Option<String> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `pid (comm) state ppid ...`: comm may contain ')', so split on the last
    // one. What follows starts at field 3 (state); starttime is field 22.
    let (_, rest) = stat.rsplit_once(')')?;
    rest.split_whitespace().nth(19).map(str::to_string)
}

#[cfg(not(target_os = "linux"))]
pub fn start_time(pid: u32) -> Option<String> {
    let out = std::process::Command::new("ps")
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .env("LC_ALL", "C")
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!text.is_empty()).then_some(text)
}

#[cfg(target_os = "linux")]
fn is_zombie(pid: u32) -> bool {
    // /proc/<pid>/stat is `pid (comm) S …`; comm may contain ')' so split on
    // the last one.
    fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()
        .and_then(|s| {
            s.rsplit_once(')')
                .map(|(_, rest)| rest.trim_start().starts_with('Z'))
        })
        .unwrap_or(false)
}

#[cfg(not(target_os = "linux"))]
fn is_zombie(_pid: u32) -> bool {
    false
}

/// The `version` field of a `GET /api/version` body.
pub fn parse_version(body: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()?
        .get("version")?
        .as_str()
        .map(str::to_string)
}

/// The data home the release will use, resolved like `Wardmast.Env.data_home/0`
/// and `rel/env.sh.eex` (see [`crate::data_home`]; the last resort is
/// `~/Library/Application Support/Wardmast` on macOS, `~/.wardmast` elsewhere).
/// The shell passes the result to the release as `WARDMAST_DATA_HOME` so both
/// always agree.
pub fn resolve_data_home() -> Option<PathBuf> {
    crate::data_home::resolve()
}

/// The app version of a bundled `mix release` directory, from
/// `releases/start_erl.data` (`<erts vsn> <app vsn>`).
pub fn bundled_version(release_dir: &Path) -> Option<String> {
    fs::read_to_string(release_dir.join("releases").join("start_erl.data"))
        .ok()?
        .split_whitespace()
        .nth(1)
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("arb-release-lock-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn record_round_trips_through_the_pidfile() {
        let home = temp_home("roundtrip");
        let rec = Record {
            pid: 4242,
            port: 4848,
            version: Some("1.2.3".into()),
            start_time: Some("123456".into()),
        };
        write(&home, &rec).unwrap();
        assert_eq!(read(&home), Some(rec));
        // no temp file is left behind
        let names: Vec<String> = fs::read_dir(&home)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec![PIDFILE.to_string()]);
    }

    #[test]
    fn a_missing_or_malformed_record_reads_as_none() {
        let home = temp_home("malformed");
        assert_eq!(read(&home), None);
        for bad in [
            "",
            "not json",
            "{}",
            r#"{"pid":"x","port":1}"#,
            r#"{"pid":99999,"port":70000}"#,
        ] {
            fs::write(pidfile_path(&home), bad).unwrap();
            assert_eq!(read(&home), None, "{bad}");
        }
    }

    #[test]
    fn pids_that_would_signal_everything_are_rejected() {
        let home = temp_home("badpid");
        for pid in [0, 1] {
            fs::write(
                pidfile_path(&home),
                format!(r#"{{"pid":{pid},"port":4848}}"#),
            )
            .unwrap();
            assert_eq!(read(&home), None, "pid {pid}");
        }
    }

    #[test]
    fn remove_if_pid_only_removes_its_own_record() {
        let home = temp_home("remove");
        let rec = Record {
            pid: 4242,
            port: 1,
            version: None,
            start_time: None,
        };
        write(&home, &rec).unwrap();
        remove_if_pid(&home, 9999);
        assert_eq!(read(&home), Some(rec));
        remove_if_pid(&home, 4242);
        assert_eq!(read(&home), None);
    }

    #[test]
    fn the_launch_lock_is_exclusive_until_dropped() {
        let home = temp_home("lock");
        let first = try_lock(&home).unwrap().expect("first lock");
        assert!(try_lock(&home).unwrap().is_none(), "second must wait");
        drop(first);
        assert!(try_lock(&home).unwrap().is_some(), "free again");
    }

    #[test]
    fn pid_alive_tracks_a_real_process_and_ignores_the_unusable_pids() {
        assert!(pid_alive(std::process::id()));
        assert!(!pid_alive(0));
        assert!(!pid_alive(1));
        let mut child = std::process::Command::new("true").spawn().unwrap();
        let pid = child.id();
        child.wait().unwrap();
        assert!(!pid_alive(pid), "reaped child");
    }

    #[test]
    fn start_time_identifies_a_process_and_is_gone_with_it() {
        let own = start_time(std::process::id()).expect("own start time");
        assert_eq!(start_time(std::process::id()), Some(own));
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let theirs = start_time(child.id()).expect("child start time");
        assert!(!theirs.is_empty());
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(start_time(child.id()), None, "reaped");
    }

    #[test]
    fn a_record_holds_its_process_only_while_the_start_time_matches() {
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id();
        let mut rec = Record {
            pid,
            port: 1,
            version: None,
            start_time: start_time(pid),
        };
        assert!(rec.holds_process());
        // The same pid with another start time is a reused pid: stale.
        rec.start_time = Some("not-this-process".into());
        assert!(!rec.holds_process());
        // No recorded start time: only the pid can be checked.
        rec.start_time = None;
        assert!(rec.holds_process());
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!rec.holds_process(), "dead pid");
    }

    #[test]
    fn parses_the_version_out_of_the_api_body() {
        assert_eq!(
            parse_version(r#"{"version":"0.9.1","sha":"x"}"#),
            Some("0.9.1".into())
        );
        assert_eq!(parse_version("<html>"), None);
        assert_eq!(parse_version(r#"{"version":7}"#), None);
    }

    #[test]
    fn reads_the_bundled_release_version() {
        let dir = temp_home("bundled");
        assert_eq!(bundled_version(&dir), None);
        fs::create_dir_all(dir.join("releases")).unwrap();
        fs::write(dir.join("releases").join("start_erl.data"), "15.1 0.9.1\n").unwrap();
        assert_eq!(bundled_version(&dir), Some("0.9.1".into()));
    }
}
