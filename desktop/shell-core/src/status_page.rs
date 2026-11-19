//! The page the shell window shows while the dashboard is not available:
//! starting, restarting after a crash, and — the point of this module — a boot
//! failure with the release's own output so the user is never left looking at
//! a blank window. Self-contained HTML (no network, no assets) that the window
//! layer loads directly.

use crate::supervisor::State;

pub fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

pub fn render(state: &State) -> String {
    let (title, detail, extra) = match state {
        State::Starting { port, attempt } => (
            "Starting Arbiter…".to_string(),
            format!("Launching the server on 127.0.0.1:{port} (attempt {attempt})."),
            String::new(),
        ),
        State::Running { port } => (
            "Arbiter is running".to_string(),
            format!("Dashboard: http://127.0.0.1:{port}/"),
            String::new(),
        ),
        State::Restarting { delay, reason } => (
            "Arbiter stopped unexpectedly".to_string(),
            format!("{reason}. Restarting in {:.1}s.", delay.as_secs_f32()),
            String::new(),
        ),
        State::BootFailed { reason, log_tail } => (
            "Arbiter could not start".to_string(),
            reason.clone(),
            format!(
                "<pre id=\"log-tail\">{}</pre>\
                 <button id=\"retry\" type=\"button\" \
                 onclick=\"window.__TAURI__.core.invoke('retry')\">Try again</button>",
                escape(&log_tail.join("\n"))
            ),
        ),
        State::Stopping => (
            "Stopping Arbiter…".to_string(),
            String::new(),
            String::new(),
        ),
        State::Stopped => (
            "Arbiter is stopped".to_string(),
            String::new(),
            String::new(),
        ),
    };
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Arbiter</title>\
         <style>body{{font:14px system-ui;margin:2rem;max-width:48rem}}\
         pre{{background:#111;color:#ddd;padding:1rem;overflow:auto;max-height:20rem}}</style>\
         </head><body><h1 id=\"status-title\">{}</h1><p id=\"status-detail\">{}</p>{}</body></html>",
        escape(&title),
        escape(&detail),
        extra
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_boot_failure_shows_the_reason_the_log_and_a_retry_button() {
        let html = render(&State::BootFailed {
            reason: "release exited during boot (exit status: 1)".into(),
            log_tail: vec!["boom: eaddrinuse".into()],
        });
        assert!(html.contains("could not start"));
        assert!(html.contains("exit status: 1"));
        assert!(html.contains("boom: eaddrinuse"));
        assert!(html.contains("id=\"retry\""));
    }

    #[test]
    fn release_output_is_escaped() {
        let html = render(&State::BootFailed {
            reason: "<b>x</b>".into(),
            log_tail: vec!["<script>alert(1)</script>".into()],
        });
        assert!(!html.contains("<script>alert"));
        assert!(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"));
        assert!(!html.contains("<b>x</b>"));
    }

    #[test]
    fn a_crash_restart_says_when_it_will_retry() {
        let html = render(&State::Restarting {
            delay: Duration::from_millis(2500),
            reason: "release exited (exit status: 1)".into(),
        });
        assert!(html.contains("Restarting in 2.5s"));
    }
}
