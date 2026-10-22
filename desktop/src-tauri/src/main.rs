// Prevents an additional console window on Windows in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--agent-files") {
        std::process::exit(spektralab_lib::agent_files::serve());
    }
    spektralab_lib::run()
}
