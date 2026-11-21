//! The window and tray over `arbiter-shell-core`. All lifecycle decisions
//! (supervision, ports, quit/drain, single instance) live in the core and are
//! tested there; this file only maps them onto a window, a tray and a dialog.
//!
//! The window is one webview that is in one of two places:
//!
//!  * the bundled page (`ui/index.html`, origin `tauri://`), into which the
//!    shell writes `status_page::render(state)` for every non-running state
//!    (starting, restarting, boot failure with the release output). Only this
//!    origin has the Tauri IPC, which is what the page's "Try again" button
//!    (`invoke('retry')`) needs;
//!  * the dashboard on `http://127.0.0.1:<port>/`, while the release is running.
//!    The dashboard is a remote origin and deliberately gets no IPC.
//!
//! `sync_window` moves it to wherever the current supervisor state says. It
//! runs on every state change and after every page load, so a state that
//! changes while a navigation is in flight is never lost.

use arbiter_shell_core::quit::{LiveWork, QuitPrompt};
use arbiter_shell_core::shell::{CloseAction, QuitOutcome, Shell};
use arbiter_shell_core::single_instance::{self, Acquired};
use arbiter_shell_core::status_page;
use arbiter_shell_core::supervisor::{Config, ReleaseSpec, State};
use std::sync::{Arc, Mutex};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Manager, Url, WindowEvent};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};

/// Where the bundled status page lives; captured once the window exists.
struct Home(Mutex<Option<Url>>);

/// Called by the boot-failure page's "Try again" button.
#[tauri::command]
fn retry(shell: tauri::State<'_, Arc<Shell>>) {
    shell.supervisor().retry();
}

struct DialogPrompt(AppHandle);

impl QuitPrompt for DialogPrompt {
    fn confirm_quit(&self, live: &LiveWork) -> bool {
        let msg = match live {
            LiveWork::Busy(n) => format!(
                "{n} worker(s) are still running. Quitting stops them; they resume the next time Arbiter starts."
            ),
            LiveWork::Unknown(why) => {
                format!("Could not check for running workers ({why}). Quit anyway?")
            }
            LiveWork::Idle => return true,
        };
        self.0
            .dialog()
            .message(msg)
            .buttons(MessageDialogButtons::OkCancelCustom(
                "Quit".into(),
                "Keep running".into(),
            ))
            .blocking_show()
    }
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn same_origin(a: &Url, b: &Url) -> bool {
    a.host_str() == b.host_str() && a.port_or_known_default() == b.port_or_known_default()
}

/// Put the window where the supervisor state says it should be.
fn sync_window(app: &AppHandle, shell: &Shell) {
    let Some(w) = app.get_webview_window("main") else {
        return;
    };
    let current = w.url().ok();
    match shell.supervisor().state() {
        State::Running { .. } => {
            let Some(dash) = shell.dashboard_url().and_then(|u| Url::parse(&u).ok()) else {
                return;
            };
            if !current.as_ref().is_some_and(|c| same_origin(c, &dash)) {
                let _ = w.navigate(dash);
            }
        }
        other => {
            let home = app.state::<Home>().0.lock().unwrap().clone();
            match (current, home) {
                // Not on the bundled page (the dashboard, after a crash): go
                // back to it. Its page-load event re-enters here and renders.
                (Some(c), Some(h)) if !same_origin(&c, &h) => {
                    let _ = w.navigate(h);
                }
                _ => {
                    let _ = w.eval(status_page::eval_script(&other));
                }
            }
        }
    }
}

fn main() {
    let socket = std::env::temp_dir().join("arbiter-shell.sock"); // production: the app runtime dir
    let handle_slot: Arc<Mutex<Option<AppHandle>>> = Arc::default();
    let slot = Arc::clone(&handle_slot);
    let _guard = match single_instance::acquire(&socket, move || {
        if let Some(app) = slot.lock().unwrap().as_ref() {
            show_main(app);
        }
    }) {
        Ok(Acquired::Primary(g)) => g,
        Ok(Acquired::Secondary) => return, // the running instance was asked to focus
        Err(e) => panic!("single-instance: {e}"),
    };

    let release_dir = std::env::var("ARBITER_RELEASE_DIR").expect("bundled release dir");
    let mut config = Config::new(ReleaseSpec::for_release_dir(&release_dir));
    // Adopt-or-refuse an orphaned release instead of starting a second server
    // on the same database (docs/desktop-shell.md, "Orphaned release").
    config.data_home = arbiter_shell_core::release_lock::resolve_data_home();
    config.expected_version =
        arbiter_shell_core::release_lock::bundled_version(std::path::Path::new(&release_dir));
    let shell = Arc::new(Shell::start(config, None));

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Arc::clone(&shell))
        .manage(Home(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![retry])
        .on_page_load({
            let shell = Arc::clone(&shell);
            move |webview, payload| {
                if payload.event() == PageLoadEvent::Finished {
                    sync_window(webview.app_handle(), &shell);
                }
            }
        })
        .setup({
            let shell = Arc::clone(&shell);
            move |app| {
                *handle_slot.lock().unwrap() = Some(app.handle().clone());
                if let Some(w) = app.get_webview_window("main") {
                    *app.state::<Home>().0.lock().unwrap() = w.url().ok();
                }

                let open = MenuItem::with_id(app, "open", "Open dashboard", true, None::<&str>)?;
                let quit = MenuItem::with_id(app, "quit", "Quit Arbiter", true, None::<&str>)?;
                let menu = Menu::with_items(app, &[&open, &quit])?;
                let tray_shell = Arc::clone(&shell);
                let mut tray = TrayIconBuilder::new().menu(&menu);
                if let Some(icon) = app.default_window_icon() {
                    tray = tray.icon(icon.clone());
                }
                tray.on_menu_event(move |app, ev| match ev.id().as_ref() {
                    "open" => show_main(app),
                    "quit" => {
                        // The dialog blocks; keep it off the menu/event thread.
                        let (app, shell) = (app.clone(), Arc::clone(&tray_shell));
                        std::thread::spawn(move || {
                            if let QuitOutcome::Quit(_) =
                                shell.request_quit(&DialogPrompt(app.clone()))
                            {
                                app.exit(0);
                            }
                        });
                    }
                    _ => {}
                })
                .build(app)?;

                // Follow the supervisor: status page until the release is ready,
                // then the dashboard on the port it was given.
                let events = shell.supervisor().subscribe();
                let handle = app.handle().clone();
                let state_shell = Arc::clone(&shell);
                std::thread::spawn(move || {
                    for _state in events {
                        sync_window(&handle, &state_shell);
                    }
                });
                Ok(())
            }
        })
        .on_window_event({
            let shell = Arc::clone(&shell);
            move |window, event| {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    let CloseAction::HideToTray = shell.window_closed();
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running the Arbiter desktop shell");
}
