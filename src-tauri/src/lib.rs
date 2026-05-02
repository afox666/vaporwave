use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command};
use tauri::Manager;

struct SidecarState {
    port: u16,
    _process: Child,
}

fn find_free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("failed to find free port")
        .local_addr()
        .unwrap()
        .port()
}

fn get_sidecar_path(app: &tauri::AppHandle) -> PathBuf {
    // Try multiple locations in order:
    // 1. Bundled resource path (for .app bundles)
    if let Ok(path) = app.path().resolve(
        "sidecars/vaporwave-sidecar",
        tauri::path::BaseDirectory::Resource,
    ) {
        if path.exists() {
            return path;
        }
    }

    // 2. Same directory as the executable
    if let Ok(exe) = std::env::current_exe() {
        let sibling = exe.parent().unwrap().join("vaporwave-sidecar");
        if sibling.exists() {
            return sibling;
        }
    }

    // 3. sidecars/ relative to cwd (dev fallback)
    let cwd = std::env::current_dir().expect("failed to get cwd");
    let dev_path = cwd.join("zig").join("main");
    if dev_path.exists() {
        return dev_path;
    }

    panic!("sidecar binary not found");
}

fn find_db_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("AKSHARE_DB_PATH") {
        let path = PathBuf::from(path);
        if path.exists() {
            return Some(path);
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        let path = cwd.join("market_data.db");
        if path.exists() {
            return Some(path);
        }
    }

    if let Ok(exe) = std::env::current_exe() {
        for ancestor in exe.ancestors() {
            let path = ancestor.join("market_data.db");
            if path.exists() {
                return Some(path);
            }
        }
    }

    None
}

#[tauri::command]
fn get_sidecar_port(state: tauri::State<SidecarState>) -> u16 {
    state.port
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_http::init())
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            let port = find_free_port();
            let sidecar_path = get_sidecar_path(app.handle());
            let db_path = find_db_path();

            log::info!("Starting sidecar: {:?} on port {}", sidecar_path, port);

            let mut command = Command::new(&sidecar_path);
            command.args(["--port", &port.to_string()]);
            if let Some(path) = db_path.as_ref() {
                log::info!("Using DuckDB: {:?}", path);
                command.args(["--db", path.to_string_lossy().as_ref()]);
            }

            let child = command.spawn().expect("failed to start sidecar");

            app.manage(SidecarState {
                port,
                _process: child,
            });

            log::info!("Sidecar started on port {}", port);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![get_sidecar_port])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
