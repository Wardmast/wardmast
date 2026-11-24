//! The "Start at login" toggle (macOS).
//!
//! A login item is a per-user launchd agent: a plist in `~/Library/LaunchAgents`
//! with `RunAtLoad`, which launchd loads at the next login. Writing or removing
//! the file is the whole mechanism (no `launchctl`, no extra dependency); macOS
//! shows its usual "item added" background-items notice the first time.
//!
//! The agent runs the app's own executable, so the single-instance socket
//! makes a second start (the user opening the app by hand) just focus the
//! first. The path is baked into the plist, so [`LoginItem::refresh`] rewrites
//! it at every launch when the toggle is on: an app that was moved or updated
//! in place keeps launching at login.
//!
//! The module is plain file work, compiled and tested on every platform; only
//! the tray menu entry is macOS-only.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// launchd label of the agent (also the plist's file stem).
pub const LABEL: &str = "dev.arbiter.desktop";

#[derive(Debug, Clone)]
pub struct LoginItem {
    /// Directory the plist lives in (`~/Library/LaunchAgents`).
    pub dir: PathBuf,
    /// The executable launchd starts at login.
    pub program: PathBuf,
}

impl LoginItem {
    pub fn new(dir: PathBuf, program: PathBuf) -> Self {
        Self { dir, program }
    }

    /// The per-user agent directory under `home`.
    pub fn agents_dir(home: &Path) -> PathBuf {
        home.join("Library").join("LaunchAgents")
    }

    pub fn plist_path(&self) -> PathBuf {
        self.dir.join(format!("{LABEL}.plist"))
    }

    /// The agent definition for `self.program`.
    pub fn plist(&self) -> String {
        let program = xml_escape(&self.program.to_string_lossy());
        [
            r#"<?xml version="1.0" encoding="UTF-8"?>"#.to_string(),
            r#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#.to_string(),
            r#"<plist version="1.0">"#.to_string(),
            "<dict>".to_string(),
            "    <key>Label</key>".to_string(),
            format!("    <string>{LABEL}</string>"),
            "    <key>ProgramArguments</key>".to_string(),
            "    <array>".to_string(),
            format!("        <string>{program}</string>"),
            "    </array>".to_string(),
            "    <key>RunAtLoad</key>".to_string(),
            "    <true/>".to_string(),
            "    <key>LimitLoadToSessionType</key>".to_string(),
            "    <string>Aqua</string>".to_string(),
            "    <key>ProcessType</key>".to_string(),
            "    <string>Interactive</string>".to_string(),
            "</dict>".to_string(),
            "</plist>".to_string(),
            String::new(),
        ]
        .join("\n")
    }

    pub fn is_enabled(&self) -> bool {
        self.plist_path().is_file()
    }

    pub fn enable(&self) -> io::Result<()> {
        fs::create_dir_all(&self.dir)?;
        let tmp = self.dir.join(format!(".{LABEL}.plist.tmp"));
        fs::write(&tmp, self.plist())?;
        fs::rename(&tmp, self.plist_path())
    }

    /// Removing an item that is not there is not an error.
    pub fn disable(&self) -> io::Result<()> {
        match fs::remove_file(self.plist_path()) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        }
    }

    /// Rewrite the plist if the toggle is on and it names a different program.
    /// Returns whether it rewrote anything.
    pub fn refresh(&self) -> io::Result<bool> {
        if !self.is_enabled() {
            return Ok(false);
        }
        if fs::read_to_string(self.plist_path()).is_ok_and(|b| b == self.plist()) {
            return Ok(false);
        }
        self.enable()?;
        Ok(true)
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn item(name: &str) -> (LoginItem, PathBuf) {
        let root = std::env::temp_dir().join(format!("arb-login-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let dir = root.join("Library").join("LaunchAgents");
        (
            LoginItem::new(
                dir,
                PathBuf::from("/Applications/Arbiter.app/Contents/MacOS/arbiter-desktop"),
            ),
            root,
        )
    }

    #[test]
    fn enable_writes_a_run_at_load_agent_and_disable_removes_it() {
        let (it, root) = item("toggle");
        assert!(!it.is_enabled());
        it.enable().unwrap();
        assert!(it.is_enabled());
        let body = fs::read_to_string(it.plist_path()).unwrap();
        assert!(body.contains("<key>Label</key>\n    <string>dev.arbiter.desktop</string>"));
        assert!(body.contains("<key>RunAtLoad</key>\n    <true/>"));
        assert!(body
            .contains("<string>/Applications/Arbiter.app/Contents/MacOS/arbiter-desktop</string>"));
        it.disable().unwrap();
        assert!(!it.is_enabled());
        it.disable().unwrap(); // idempotent
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn the_plist_escapes_xml_in_the_program_path() {
        let it = LoginItem::new(PathBuf::from("/x"), PathBuf::from("/A & B/<app>/bin"));
        let body = it.plist();
        assert!(body.contains("<string>/A &amp; B/&lt;app&gt;/bin</string>"));
        assert!(!body.contains("/A & B"));
    }

    #[test]
    fn enable_is_atomic_and_leaves_no_temp_file_behind() {
        let (it, root) = item("atomic");
        it.enable().unwrap();
        it.enable().unwrap();
        let names: Vec<_> = fs::read_dir(&it.dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec![format!("{LABEL}.plist")]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn refresh_does_nothing_while_the_toggle_is_off() {
        let (it, root) = item("off");
        assert!(!it.refresh().unwrap());
        assert!(!it.plist_path().exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn refresh_repoints_an_item_whose_app_moved() {
        let (it, root) = item("moved");
        it.enable().unwrap();
        assert!(!it.refresh().unwrap(), "same program: nothing to rewrite");
        let moved = LoginItem::new(
            it.dir.clone(),
            PathBuf::from("/Users/me/Apps/Arbiter.app/Contents/MacOS/arbiter-desktop"),
        );
        assert!(moved.refresh().unwrap());
        let body = fs::read_to_string(moved.plist_path()).unwrap();
        assert!(body.contains("/Users/me/Apps/Arbiter.app"));
        assert!(!body.contains("/Applications/Arbiter.app"));
        let _ = fs::remove_dir_all(root);
    }
}
