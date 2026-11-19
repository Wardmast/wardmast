//! UNBUILT SKETCH — see Cargo.toml. All lifecycle decisions live in
//! `arbiter-shell-core`; this file only maps them onto a window and a tray.

use arbiter_shell_core::quit::{LiveWork, QuitPrompt};
use arbiter_shell_core::shell::{CloseAction, QuitOutcome, Shell};
use arbiter_shell_core::single_instance::{self, Acquired};
use arbiter_shell_core::status_page;
use arbiter_shell_core::supervisor::{Config, ReleaseSpec, State};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, WindowEvent};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};

struct DialogPrompt(AppHandle);

impl QuitPrompt for DialogPrompt {
    fn confirm_quit(&self, live: &LiveWork) -> bool {
        let msg = match live {
            LiveWork::Busy(n) => format!(
                "{n} worker(s) are still running. Quitting stops them; they resume the next time Arbiter starts."
            ),
            LiveWork::Unknown(why) => format!("Could not check for running workers ({why}). Quit anyway?"),
            LiveWork::Idle => return true,
        };
        self.0
            .dialog()
            .message(msg)
            .buttons(MessageDialogButtons::OkCancelCustom("Quit".into(), "Keep running".into()))
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

fn main() {
    let socket = std::env::temp_dir().join("arbiter-shell.sock"); // production: app runtime dir
    let handle_slot: Arc<std::sync::Mutex<Option<AppHandle>>> = Arc::default();
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
    let shell = Arc::new(Shell::start(Config::new(ReleaseSpec::for_release_dir(release_dir)), None));

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup({
            let shell = Arc::clone(&shell);
            move |app| {
                *handle_slot.lock().unwrap() = Some(app.handle().clone());

                let quit = MenuItem::with_id(app, "quit", "Quit Arbiter", true, None::<&str>)?;
                let open = MenuItem::with_id(app, "open", "Open dashboard", true, None::<&str>)?;
                let menu = Menu::with_items(app, &[&open, &quit])?;
                let tray_shell = Arc::clone(&shell);
                TrayIconBuilder::new()
                    .menu(&menu)
                    .on_menu_event(move |app, ev| match ev.id().as_ref() {
                        "open" => show_main(app),
                        "quit" => {
                            if let QuitOutcome::Quit(_) =
                                tray_shell.request_quit(&DialogPrompt(app.clone()))
                            {
                                app.exit(0);
                            }
                        }
                        _ => {}
                    })
                    .build(app)?;

                // Drive the window from supervisor state: status page until the
                // release is ready, then the dashboard on the port it was given.
                let events = shell.supervisor().subscribe();
                let handle = app.handle().clone();
                let url_shell = Arc::clone(&shell);
                std::thread::spawn(move || {
                    for state in events {
                        let Some(w) = handle.get_webview_window("main") else { continue };
                        match state {
                            State::Running { .. } => {
                                if let Some(url) = url_shell.dashboard_url() {
                                    let _ = w.eval(&format!("window.location.replace('{url}')"));
                                }
                            }
                            other => {
                                let html = status_page::render(&other);
                                let _ = w.emit("shell-status-html", html);
                            }
                        }
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
        .expect("tauri");
}
