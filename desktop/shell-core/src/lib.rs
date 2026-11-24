//! Lifecycle core of the Arbiter desktop shell prototype (bd-aisgkf, PKG 8).
//!
//! See `docs/desktop-shell.md` for the decisions this encodes.

pub mod backoff;
pub mod credentials;
pub mod data_home;
pub mod http;
pub mod login_item;
pub mod port;
pub mod quit;
pub mod release_lock;
pub mod shell;
pub mod single_instance;
pub mod status_page;
pub mod supervisor;
