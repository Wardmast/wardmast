//! First-run credentials (PKG 9): the Cloak key and `SECRET_KEY_BASE`.
//!
//! On first run the shell generates both, stores them in the OS keychain (macOS
//! Keychain, Linux Secret Service) and hands the release **references**
//! (`WARDMAST_CLOAK_KEY_REF=keychain:<service>#<account>`, likewise
//! `SECRET_KEY_BASE_REF`), never values. The release resolves them itself
//! (`Wardmast.SecretRefs.Keychain`).
//!
//! Invariants, because losing the Cloak key makes every stored secret
//! unreadable:
//!
//!  * A value is only generated when the keychain *positively* reports the item
//!    missing **and** the shell has never created it before. A locked keychain,
//!    a missing `secret-tool`, an unreadable answer: none of them is "missing".
//!  * The "created before" record (`keychain-items` in the data dir, account
//!    names only) means a deleted item is reported, not silently replaced.
//!  * Values travel on stdin only (`secret-tool store`, `security -i`): never in
//!    argv, never in an error, a log line or a `Debug` print. Nothing here
//!    writes a value to disk.
//!  * When anything is wrong the shell still hands over the refs and reports on
//!    stderr (no values), so the release's own boot error, which names the item
//!    and the fix, is what the status page shows.

use std::fmt;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const SERVICE: &str = "dev.arbiter.wardmast";
pub const CLOAK_ACCOUNT: &str = "cloak-key";
pub const SECRET_KEY_BASE_ACCOUNT: &str = "secret-key-base";
pub const CLOAK_REF_ENV: &str = "WARDMAST_CLOAK_KEY_REF";
pub const SECRET_KEY_BASE_REF_ENV: &str = "SECRET_KEY_BASE_REF";
const MARKER_FILE: &str = "keychain-items";

/// Why the keychain could not answer. Carries no values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreError {
    Locked,
    Unavailable,
    Failed,
}

/// What the shell needs from a credential store.
pub trait SecretStore {
    /// `Ok(None)` only when the store says the item does not exist.
    fn get(&self, service: &str, account: &str) -> Result<Option<String>, StoreError>;
    fn set(&self, service: &str, account: &str, value: &str) -> Result<(), StoreError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialError {
    /// The item is gone but the shell created it earlier. Never regenerated.
    Missing {
        item: String,
    },
    Locked {
        item: String,
    },
    Unavailable {
        item: String,
    },
    StoreFailed {
        item: String,
    },
    /// The random source or the created-items record failed.
    Local {
        what: String,
    },
}

impl fmt::Display for CredentialError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CredentialError::Missing { item } => write!(
                f,
                "keychain item {item} was created earlier but is now missing. Restore it from \
                 your key backup; a new key is not generated because that would make every \
                 stored secret unreadable"
            ),
            CredentialError::Locked { item } => write!(
                f,
                "keychain item {item} is locked or access was denied; unlock the keychain and \
                 start again"
            ),
            CredentialError::Unavailable { item } => write!(
                f,
                "the OS keychain is not reachable for item {item} (macOS: `security`; Linux: \
                 `secret-tool` and a running Secret Service)"
            ),
            CredentialError::StoreFailed { item } => {
                write!(f, "could not store keychain item {item}")
            }
            CredentialError::Local { what } => write!(f, "credential setup failed: {what}"),
        }
    }
}

impl std::error::Error for CredentialError {}

/// `keychain:<service>#<account>`.
pub fn keychain_ref(account: &str) -> String {
    format!("keychain:{SERVICE}#{account}")
}

fn item_name(account: &str) -> String {
    format!("{SERVICE}#{account}")
}

/// The environment that hands the release its refs. Values never appear here.
pub fn ref_env() -> Vec<(String, String)> {
    vec![
        (CLOAK_REF_ENV.to_string(), keychain_ref(CLOAK_ACCOUNT)),
        (
            SECRET_KEY_BASE_REF_ENV.to_string(),
            keychain_ref(SECRET_KEY_BASE_ACCOUNT),
        ),
    ]
}

/// Where the shell keeps its non-secret state: `WARDMAST_DATA_HOME`, else
/// `~/.wardmast` (what the server and `arb server doctor` use too).
pub fn default_data_dir() -> PathBuf {
    match std::env::var("WARDMAST_DATA_HOME") {
        Ok(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".wardmast"),
    }
}

/// Make sure both items exist, generating only what is positively missing and
/// never created before.
///
/// `random(n)` returns `n` random bytes.
pub fn ensure(
    store: &dyn SecretStore,
    data_dir: &Path,
    random: &dyn Fn(usize) -> std::io::Result<Vec<u8>>,
) -> Result<(), CredentialError> {
    // The Cloak key: 32 bytes, Base64 (what `Wardmast.Vault` decodes).
    ensure_item(store, data_dir, CLOAK_ACCOUNT, || {
        random(32).map(|b| base64(&b))
    })?;
    // SECRET_KEY_BASE: Phoenix wants at least 64 bytes of text.
    ensure_item(store, data_dir, SECRET_KEY_BASE_ACCOUNT, || {
        random(64).map(|b| hex(&b))
    })
}

fn ensure_item(
    store: &dyn SecretStore,
    data_dir: &Path,
    account: &str,
    generate: impl FnOnce() -> std::io::Result<String>,
) -> Result<(), CredentialError> {
    let item = item_name(account);
    let created_before = read_marker(data_dir).iter().any(|a| a == account);

    match store.get(SERVICE, account) {
        Ok(Some(_)) => {
            if !created_before {
                // An item we did not create (a restore, a manual setup): adopt it.
                record(data_dir, account)?;
            }
            Ok(())
        }
        Ok(None) if created_before => Err(CredentialError::Missing { item }),
        Ok(None) if account == CLOAK_ACCOUNT && data_dir.join("wardmast.env").exists() => {
            // A service install already keeps its key in this data dir's env file
            // (or a ref in it): generating a second one would orphan its data.
            Err(CredentialError::Local {
                what: format!(
                    "{item} is missing but {} exists, so this data dir already has an \
                     encryption key; import it into the keychain instead of generating a new one",
                    data_dir.join("wardmast.env").display()
                ),
            })
        }
        Ok(None) => {
            let value = generate().map_err(|e| CredentialError::Local {
                what: format!("no random bytes ({:?})", e.kind()),
            })?;
            store
                .set(SERVICE, account, &value)
                .map_err(|e| store_error(e, &item))?;
            // Read it back: only a stored key counts as created.
            match store.get(SERVICE, account) {
                Ok(Some(back)) if back == value => record(data_dir, account),
                _ => Err(CredentialError::StoreFailed { item }),
            }
        }
        Err(e) => Err(store_error(e, &item)),
    }
}

fn store_error(e: StoreError, item: &str) -> CredentialError {
    let item = item.to_string();
    match e {
        StoreError::Locked => CredentialError::Locked { item },
        StoreError::Unavailable => CredentialError::Unavailable { item },
        StoreError::Failed => CredentialError::StoreFailed { item },
    }
}

fn read_marker(data_dir: &Path) -> Vec<String> {
    fs::read_to_string(data_dir.join(MARKER_FILE))
        .map(|s| s.lines().map(|l| l.trim().to_string()).collect())
        .unwrap_or_default()
}

fn record(data_dir: &Path, account: &str) -> Result<(), CredentialError> {
    let local = |what: &str| CredentialError::Local {
        what: what.to_string(),
    };
    fs::create_dir_all(data_dir).map_err(|_| local("cannot create the data dir"))?;
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(data_dir.join(MARKER_FILE))
        .map_err(|_| local("cannot record the created keychain item"))?;
    writeln!(f, "{account}").map_err(|_| local("cannot record the created keychain item"))
}

/// What the shell does at launch: ensure the items and return the refs for the
/// release environment. Always returns the refs; a problem is reported on
/// stderr (item names only) and surfaces as the release's own boot error.
pub fn prepare(
    store: &dyn SecretStore,
    data_dir: &Path,
    random: &dyn Fn(usize) -> std::io::Result<Vec<u8>>,
) -> Vec<(String, String)> {
    if let Err(e) = ensure(store, data_dir, random) {
        eprintln!("arbiter-shell: {e}");
    }
    ref_env()
}

/// Random bytes from the OS (`/dev/urandom`); the shell is unix-only for now.
pub fn os_random(n: usize) -> std::io::Result<Vec<u8>> {
    let mut buf = vec![0u8; n];
    fs::File::open("/dev/urandom")?.read_exact(&mut buf)?;
    Ok(buf)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Standard Base64 with padding (the Cloak key format).
pub fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

// ---- the OS keychain ---------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    MacOs,
    Linux,
}

impl Os {
    pub fn current() -> Os {
        if cfg!(target_os = "macos") {
            Os::MacOs
        } else {
            Os::Linux
        }
    }
}

#[derive(Clone)]
pub struct CmdOutput {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

// `stdout` is the secret on a read: keep it out of any `{:?}` print.
impl fmt::Debug for CmdOutput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CmdOutput")
            .field("code", &self.code)
            .field("stdout", &"<redacted>")
            .field("stderr", &self.stderr)
            .finish()
    }
}

/// `(program, args, stdin) -> output`; `Err` when the program cannot be run.
pub type Runner =
    Box<dyn Fn(&str, &[String], Option<&str>) -> std::io::Result<CmdOutput> + Send + Sync>;

pub struct OsStore {
    os: Os,
    runner: Runner,
}

impl Default for OsStore {
    fn default() -> Self {
        OsStore::new()
    }
}

impl OsStore {
    pub fn new() -> OsStore {
        OsStore {
            os: Os::current(),
            runner: Box::new(run_command),
        }
    }

    /// For tests: a platform and a stubbed command runner.
    pub fn with_runner(os: Os, runner: Runner) -> OsStore {
        OsStore { os, runner }
    }
}

fn run_command(program: &str, args: &[String], stdin: Option<&str>) -> std::io::Result<CmdOutput> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    if let Some(input) = stdin {
        if let Some(mut pipe) = child.stdin.take() {
            pipe.write_all(input.as_bytes())?;
        }
    }
    let out = child.wait_with_output()?;
    Ok(CmdOutput {
        code: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

fn strings(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

impl SecretStore for OsStore {
    fn get(&self, service: &str, account: &str) -> Result<Option<String>, StoreError> {
        let (program, args) = match self.os {
            Os::MacOs => (
                "security",
                strings(&["find-generic-password", "-s", service, "-a", account, "-w"]),
            ),
            Os::Linux => (
                "secret-tool",
                strings(&["lookup", "service", service, "account", account]),
            ),
        };
        let out = (self.runner)(program, &args, None).map_err(|_| StoreError::Unavailable)?;
        classify_get(self.os, &out)
    }

    fn set(&self, service: &str, account: &str, value: &str) -> Result<(), StoreError> {
        // The value goes to the tool on stdin, never on its command line.
        let safe = |s: &str| {
            !s.is_empty()
                && s.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
        };
        if !safe(service) || !safe(account) {
            return Err(StoreError::Failed);
        }
        let out = match self.os {
            Os::MacOs => {
                // `security -i` reads its commands from stdin.
                let line = format!(
                    "add-generic-password -U -s {service} -a {account} -l Arbiter-{account} -w {value}\n"
                );
                (self.runner)("security", &strings(&["-i"]), Some(&line))
            }
            Os::Linux => (self.runner)(
                "secret-tool",
                &strings(&[
                    "store",
                    "--label=Arbiter",
                    "service",
                    service,
                    "account",
                    account,
                ]),
                Some(value),
            ),
        }
        .map_err(|_| StoreError::Unavailable)?;

        if out.code == 0 {
            Ok(())
        } else {
            Err(match classify_failure(&out.stderr) {
                Some(e) => e,
                None => StoreError::Failed,
            })
        }
    }
}

/// Interpret a `get` result. Only an unambiguous "no such item" is `Ok(None)`.
pub fn classify_get(os: Os, out: &CmdOutput) -> Result<Option<String>, StoreError> {
    if out.code == 0 {
        let value = out.stdout.trim();
        // An item that exists but reads back empty is not "missing".
        return if value.is_empty() {
            Err(StoreError::Failed)
        } else {
            Ok(Some(value.to_string()))
        };
    }
    match os {
        // errSecItemNotFound.
        Os::MacOs if out.code == 44 => Ok(None),
        // errSecInteractionNotAllowed (locked, no UI) / user cancelled the prompt.
        Os::MacOs if out.code == 36 || out.code == 51 => Err(StoreError::Locked),
        Os::MacOs => Err(classify_failure(&out.stderr).unwrap_or(StoreError::Failed)),
        // `secret-tool lookup` exits 1 with no output for a missing item.
        Os::Linux => match classify_failure(&out.stderr) {
            Some(e) => Err(e),
            None if out.stderr.trim().is_empty() && out.stdout.trim().is_empty() => Ok(None),
            None => Err(StoreError::Failed),
        },
    }
}

fn classify_failure(stderr: &str) -> Option<StoreError> {
    let text = stderr.to_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| text.contains(n));
    if has(&["locked", "denied", "user interaction is not allowed"]) {
        Some(StoreError::Locked)
    } else if has(&[
        "autolaunch",
        "org.freedesktop.secrets",
        "cannot connect",
        "no such interface",
        "dbus",
        "d-bus",
    ]) {
        Some(StoreError::Unavailable)
    } else {
        None
    }
}
