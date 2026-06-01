// Prevent a console window from popping up on Windows builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    concilio_lib::run()
}
