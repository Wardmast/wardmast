//! The shell's policy layer: what window close and Quit mean.
//!
//!  * **Close window** hides it (the shell lives on in the tray/menu bar) and
//!    leaves the release running: workers keep going, the MCP endpoint stays up.
//!  * **Quit** checks for live work first; with any (or an unreadable drain
//!    state) it asks, and only on confirmation stops the release with SIGTERM,
//!    which runs the server's own orderly shutdown so its workers are marked
//!    interrupted and `Wardmast.Workers.Reconciler` can resume them on the next
//!    start. Declining changes nothing.

use crate::quit::{self, LiveWork, QuitPrompt};
use crate::supervisor::{Config, State, StopOutcome, Supervisor};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseAction {
    /// Hide the window and keep the shell (and the server) running.
    HideToTray,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuitOutcome {
    /// The release was stopped; the shell process may exit.
    Quit(StopOutcome),
    /// The user declined; everything keeps running.
    Cancelled,
}

pub struct Shell {
    supervisor: Supervisor,
    api_token: Option<String>,
}

impl Shell {
    /// Start supervising the release. `api_token` is the bearer token used to
    /// read the drain state on Quit (see `quit`).
    pub fn start(config: Config, api_token: Option<String>) -> Shell {
        Shell {
            supervisor: Supervisor::start(config),
            api_token,
        }
    }

    pub fn supervisor(&self) -> &Supervisor {
        &self.supervisor
    }

    /// Where the window should point: the dashboard on the port the release
    /// was actually given. `None` until the release is ready.
    pub fn dashboard_url(&self) -> Option<String> {
        self.supervisor
            .port()
            .map(|p| format!("http://127.0.0.1:{p}/"))
    }

    /// The user closed the window. Never stops the release.
    pub fn window_closed(&self) -> CloseAction {
        CloseAction::HideToTray
    }

    pub fn live_work(&self) -> LiveWork {
        match self.supervisor.state() {
            State::Running { port } => quit::query_live_work(port, self.api_token.as_deref()),
            // Nothing is serving, so there is no agent work to interrupt.
            _ => LiveWork::Idle,
        }
    }

    pub fn request_quit(&self, prompt: &dyn QuitPrompt) -> QuitOutcome {
        let live = self.live_work();
        if live != LiveWork::Idle && !prompt.confirm_quit(&live) {
            return QuitOutcome::Cancelled;
        }
        QuitOutcome::Quit(self.supervisor.stop())
    }
}
