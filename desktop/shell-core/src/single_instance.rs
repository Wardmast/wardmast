//! Single instance: a second launch focuses the running shell instead of
//! starting a second server.
//!
//! Mechanism (Unix; a Windows port would use a named pipe, see the doc):
//!
//!  * an exclusive `flock` on `<socket>.lock` decides who is primary. The
//!    kernel drops it when the holder dies, so a crash never wedges the next
//!    launch, and two simultaneous launches cannot both win;
//!  * the primary (re)binds a Unix socket at `<socket>` — removing any stale
//!    file left by a crashed predecessor, which is safe only because it holds
//!    the lock — and answers every connection by running `on_focus` and
//!    replying `ok`;
//!  * a launch that cannot take the lock connects to that socket, sends
//!    `focus`, waits for the reply and reports `Secondary` (the caller exits
//!    without touching the release).

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub enum Acquired {
    /// This process is the instance; keep the guard alive for as long as it runs.
    Primary(Guard),
    /// Another instance is running and has been asked to focus its window.
    Secondary,
}

/// Held by the primary instance. Dropping it removes the socket and releases
/// the lock, so the next launch becomes primary.
pub struct Guard {
    socket: PathBuf,
    stop: Arc<AtomicBool>,
    accept: Option<JoinHandle<()>>,
    _lock: File,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.accept.take() {
            let _ = h.join();
        }
        let _ = fs::remove_file(&self.socket);
    }
}

/// Conservative `sun_path` limit (macOS: 104 including the NUL).
const MAX_SOCKET_PATH: usize = 100;
const FOCUS: &str = "focus";
const HOW_LONG_TO_WAIT_FOR_PRIMARY: Duration = Duration::from_secs(5);
const SOCKET_NAME: &str = "shell.sock";

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// The single-instance socket path in the app runtime directory:
///
///  1. `SHELL_SOCKET` or `ARBITER_SHELL_SOCKET` when explicitly set;
///  2. `$XDG_RUNTIME_DIR/arbiter/shell.sock` on systemd/freedesktop sessions;
///  3. `/run/user/<uid>/arbiter/shell.sock` when that per-user runtime dir exists;
///  4. `<data-home>/run/shell.sock` (`WARDMAST_DATA_HOME`, legacy `ARB_DATA_HOME`,
///     default `~/.wardmast/run`), matching `Wardmast.MCP.OperatorProof.run_dir/0`
///     on macOS and non-systemd hosts.
pub fn default_socket_path() -> PathBuf {
    let explicit = env_path("SHELL_SOCKET").or_else(|| env_path("ARBITER_SHELL_SOCKET"));
    let xdg = env_path("XDG_RUNTIME_DIR");
    let run_user = Some(PathBuf::from(format!("/run/user/{}", unsafe {
        libc::geteuid()
    })));
    let data_home = env_path("WARDMAST_DATA_HOME").or_else(|| env_path("ARB_DATA_HOME"));
    let home = env_path("HOME");
    socket_path_from(explicit, xdg, run_user, data_home, home)
}

pub fn socket_path_from(
    explicit: Option<PathBuf>,
    xdg_runtime_dir: Option<PathBuf>,
    run_user_dir: Option<PathBuf>,
    data_home: Option<PathBuf>,
    home: Option<PathBuf>,
) -> PathBuf {
    if let Some(p) = explicit {
        return p;
    }
    if let Some(xdg) = xdg_runtime_dir {
        return xdg.join("arbiter").join(SOCKET_NAME);
    }
    if let Some(ru) = run_user_dir.filter(|p| p.is_dir()) {
        return ru.join("arbiter").join(SOCKET_NAME);
    }
    if let Some(dh) = data_home {
        return dh.join("run").join(SOCKET_NAME);
    }
    if let Some(h) = home {
        return h.join(".wardmast").join("run").join(SOCKET_NAME);
    }
    std::env::temp_dir().join("arbiter").join(SOCKET_NAME)
}

fn lock_path(socket: &Path) -> PathBuf {
    let mut s = socket.as_os_str().to_owned();
    s.push(".lock");
    PathBuf::from(s)
}

/// Become the one running instance, or ask the running one to focus itself.
pub fn acquire<F>(socket: &Path, on_focus: F) -> io::Result<Acquired>
where
    F: Fn() + Send + 'static,
{
    // `sockaddr_un.sun_path` is ~104 bytes on macOS and 108 on Linux; fail with
    // a message instead of an opaque EINVAL from bind.
    if socket.as_os_str().len() > MAX_SOCKET_PATH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "single-instance socket path too long ({} > {MAX_SOCKET_PATH} bytes): {}",
                socket.as_os_str().len(),
                socket.display()
            ),
        ));
    }
    if let Some(dir) = socket.parent() {
        fs::create_dir_all(dir)?;
    }
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(lock_path(socket))?;

    match lock.try_lock() {
        Ok(()) => {
            // We are primary. Anything at `socket` is a dead predecessor's.
            let _ = fs::remove_file(socket);
            let listener = UnixListener::bind(socket)?;
            listener.set_nonblocking(true)?;
            let stop = Arc::new(AtomicBool::new(false));
            let accept = spawn_accept_loop(listener, Arc::clone(&stop), on_focus);
            Ok(Acquired::Primary(Guard {
                socket: socket.to_path_buf(),
                stop,
                accept: Some(accept),
                _lock: lock,
            }))
        }
        Err(fs::TryLockError::WouldBlock) => {
            request_focus(socket)?;
            Ok(Acquired::Secondary)
        }
        Err(fs::TryLockError::Error(e)) => Err(e),
    }
}

fn spawn_accept_loop<F>(
    listener: UnixListener,
    stop: Arc<AtomicBool>,
    on_focus: F,
) -> JoinHandle<()>
where
    F: Fn() + Send + 'static,
{
    thread::spawn(move || {
        while !stop.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let _ = stream.set_nonblocking(false);
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut line = String::new();
                    let mut reader = BufReader::new(&stream);
                    if reader.read_line(&mut line).is_ok() && line.trim() == FOCUS {
                        on_focus();
                        let _ = (&stream).write_all(b"ok\n");
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(20));
                }
                Err(_) => thread::sleep(Duration::from_millis(100)),
            }
        }
    })
}

/// The primary holds the lock before it binds, so for a moment the socket may
/// not exist yet; retry until it does.
fn request_focus(socket: &Path) -> io::Result<()> {
    let deadline = Instant::now() + HOW_LONG_TO_WAIT_FOR_PRIMARY;
    loop {
        match try_focus_once(socket) {
            Ok(()) => return Ok(()),
            Err(e) if Instant::now() >= deadline => return Err(e),
            Err(_) => thread::sleep(Duration::from_millis(50)),
        }
    }
}

fn try_focus_once(socket: &Path) -> io::Result<()> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(format!("{FOCUS}\n").as_bytes())?;
    let mut reply = String::new();
    BufReader::new(&stream).read_line(&mut reply)?;
    if reply.trim() == "ok" {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "primary did not acknowledge focus",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn sock(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("si{}{name}", std::process::id()));
        fs::create_dir_all(&d).unwrap();
        d.join("s")
    }

    #[test]
    fn first_launch_is_primary_second_focuses_the_first() {
        let path = sock("focus");
        let (tx, rx) = mpsc::channel();
        let guard = match acquire(&path, move || tx.send(()).unwrap()).unwrap() {
            Acquired::Primary(g) => g,
            Acquired::Secondary => panic!("first launch must be primary"),
        };
        let second = acquire(&path, || panic!("a secondary must not install a handler")).unwrap();
        assert!(matches!(second, Acquired::Secondary));
        rx.recv_timeout(Duration::from_secs(2))
            .expect("primary was asked to focus");
        // A third launch also focuses.
        assert!(matches!(
            acquire(&path, || {}).unwrap(),
            Acquired::Secondary
        ));
        rx.recv_timeout(Duration::from_secs(2))
            .expect("focus again");
        drop(guard);
    }

    #[test]
    fn a_stale_socket_from_a_crashed_instance_is_taken_over() {
        let path = sock("stale");
        // A socket file with nobody listening (what a SIGKILLed primary leaves).
        drop(UnixListener::bind(&path).unwrap());
        assert!(path.exists());
        assert!(matches!(
            acquire(&path, || {}).unwrap(),
            Acquired::Primary(_)
        ));
    }

    #[test]
    fn after_the_primary_quits_the_next_launch_is_primary() {
        let path = sock("relaunch");
        let g = match acquire(&path, || {}).unwrap() {
            Acquired::Primary(g) => g,
            _ => panic!("first launch must be primary"),
        };
        drop(g);
        assert!(matches!(
            acquire(&path, || {}).unwrap(),
            Acquired::Primary(_)
        ));
    }

    #[test]
    fn an_overlong_socket_path_is_a_clear_error() {
        let long = PathBuf::from(format!("/{}/shell.sock", "x".repeat(120)));
        let err = acquire(&long, || {}).err().expect("must fail");
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("too long"), "{err}");
    }

    #[test]
    fn simultaneous_launches_elect_exactly_one_primary() {
        let path = sock("race");
        let results: Vec<_> = (0..6)
            .map(|_| {
                let p = path.clone();
                thread::spawn(move || match acquire(&p, || {}).unwrap() {
                    Acquired::Primary(g) => Some(g),
                    Acquired::Secondary => None,
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();
        assert_eq!(results.iter().filter(|r| r.is_some()).count(), 1);
    }

    #[test]
    fn default_socket_path_honours_explicit_override_first() {
        assert_eq!(
            socket_path_from(
                Some(PathBuf::from("/custom/shell.sock")),
                Some(PathBuf::from("/run/user/1000")),
                Some(PathBuf::from("/run/user/1000")),
                Some(PathBuf::from("/custom/data")),
                Some(PathBuf::from("/home/u")),
            ),
            PathBuf::from("/custom/shell.sock")
        );
    }

    #[test]
    fn default_socket_path_uses_xdg_runtime_dir_app_subdir() {
        assert_eq!(
            socket_path_from(
                None,
                Some(PathBuf::from("/run/user/1000")),
                None,
                Some(PathBuf::from("/home/u/.wardmast")),
                Some(PathBuf::from("/home/u")),
            ),
            PathBuf::from("/run/user/1000/arbiter/shell.sock")
        );
    }

    #[test]
    fn default_socket_path_uses_run_user_uid_when_xdg_runtime_dir_is_unset() {
        let run_user = std::env::temp_dir().join(format!("si-ru-{}", std::process::id()));
        fs::create_dir_all(&run_user).unwrap();
        assert_eq!(
            socket_path_from(
                None,
                None,
                Some(run_user.clone()),
                None,
                Some(PathBuf::from("/home/u")),
            ),
            run_user.join("arbiter").join("shell.sock")
        );
    }

    #[test]
    fn default_socket_path_falls_back_to_data_home_run_dir_when_no_runtime_dir_exists() {
        let missing = PathBuf::from("/nonexistent-run-user-dir-for-test");
        assert_eq!(
            socket_path_from(
                None,
                None,
                Some(missing.clone()),
                Some(PathBuf::from("/Users/u/.wardmast")),
                Some(PathBuf::from("/Users/u")),
            ),
            PathBuf::from("/Users/u/.wardmast/run/shell.sock")
        );
        assert_eq!(
            socket_path_from(None, None, Some(missing), None, Some(PathBuf::from("/Users/u"))),
            PathBuf::from("/Users/u/.wardmast/run/shell.sock")
        );
    }
}
