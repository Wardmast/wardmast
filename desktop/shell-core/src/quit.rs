//! What Quit must know before it stops the release: is any agent work live?
//!
//! The answer comes from the release itself, `GET /api/scheduler/status`
//! (`Wardmast.Board.Drain`, the same body `arb scheduler status` prints), whose
//! `in_flight` list is every agent still running. That route needs a bearer
//! token, so when the shell has none (PKG 9 owns shell-managed credentials) or
//! the call fails, the answer is `Unknown`, never `Idle`: an unreadable drain
//! state must not silently become "safe to quit".

use crate::http;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveWork {
    /// Nothing in flight.
    Idle,
    /// This many workers/agents are still running.
    Busy(usize),
    /// The drain state could not be read; the string says why.
    Unknown(String),
}

/// The "are you sure?" dialog. Implemented by the window layer (a native
/// dialog in the Tauri shell, a scripted answer in tests and the smoke run).
pub trait QuitPrompt {
    /// Return `true` to quit (stopping the release) or `false` to stay.
    fn confirm_quit(&self, live: &LiveWork) -> bool;
}

/// A pre-set answer to the quit dialog (`SHELL_QUIT_ANSWER`), for the CI smoke
/// test and other unattended runs where nobody can click. `yes`/`no`; anything
/// else (or unset) means "ask". It only replaces the click: the drain state is
/// still read first and a `no` still keeps everything running.
pub fn scripted_answer(value: Option<&str>) -> Option<bool> {
    match value.map(str::trim) {
        Some("yes") => Some(true),
        Some("no") => Some(false),
        _ => None,
    }
}

pub fn query_live_work(port: u16, bearer: Option<&str>) -> LiveWork {
    match http::get(
        port,
        "/api/scheduler/status",
        bearer,
        Duration::from_secs(3),
    ) {
        Ok(r) => parse_status(r.status, &r.body),
        Err(e) => LiveWork::Unknown(format!("could not reach the release: {e}")),
    }
}

pub fn parse_status(status: u16, body: &str) -> LiveWork {
    if status != 200 {
        return LiveWork::Unknown(format!("scheduler status answered HTTP {status}"));
    }
    match serde_json::from_str::<serde_json::Value>(body) {
        Ok(v) => match v.get("in_flight").and_then(|f| f.as_array()) {
            Some(list) if list.is_empty() => LiveWork::Idle,
            Some(list) => LiveWork::Busy(list.len()),
            None => LiveWork::Unknown("scheduler status has no in_flight list".into()),
        },
        Err(e) => LiveWork::Unknown(format!("scheduler status is not JSON: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_scripted_quit_answer_is_yes_no_or_ask() {
        assert_eq!(scripted_answer(Some("yes")), Some(true));
        assert_eq!(scripted_answer(Some("no")), Some(false));
        assert_eq!(scripted_answer(Some("")), None);
        assert_eq!(scripted_answer(Some("maybe")), None);
        assert_eq!(scripted_answer(None), None);
    }

    #[test]
    fn empty_in_flight_is_idle() {
        assert_eq!(
            parse_status(200, r#"{"state":"quiescent","in_flight":[]}"#),
            LiveWork::Idle
        );
    }

    #[test]
    fn counts_in_flight_entries() {
        let body = r#"{"state":"draining","in_flight":[{"kind":"driver"},{"kind":"fix_pass"}]}"#;
        assert_eq!(parse_status(200, body), LiveWork::Busy(2));
    }

    #[test]
    fn anything_unreadable_is_unknown_not_idle() {
        for (status, body) in [
            (401, r#"{"error":{}}"#),
            (500, ""),
            (200, "not json"),
            (200, r#"{"state":"running"}"#),
        ] {
            assert!(
                matches!(parse_status(status, body), LiveWork::Unknown(_)),
                "{status} {body}"
            );
        }
        assert!(matches!(parse_status(401, "{}"), LiveWork::Unknown(m) if m.contains("401")));
    }
}
