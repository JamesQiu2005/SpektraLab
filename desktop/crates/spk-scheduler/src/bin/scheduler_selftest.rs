//! `tools/selftest.sh`'s scheduler half, as the Swift's `@main`:
//!
//! ```text
//! scheduler-selftest               # the checks
//! scheduler-selftest --self-test   # the checks' own check: each mutation must be caught
//! ```
//!
//! On a paused tokio clock: the rules run in virtual time and nothing here measures this machine.
//! A dev-only tool (`--features selftest`), and **macOS only by design**: the suite is how the port is
//! verified on the Mac it was ported on, and it is never built for Windows (see README).

#[cfg(target_os = "macos")]
fn main() {
    use spk_scheduler::selftest;
    let self_test = std::env::args().any(|a| a == "--self-test");
    let result = selftest::run_paused(None);
    println!("scheduler checks: {} passed, {} failed", result.passed, result.failed.len());
    let mut code = if result.failed.is_empty() { 0 } else { 1 };
    if self_test {
        let mut caught = 0;
        for (name, r) in selftest::mutation_run() {
            if r.failed.is_empty() {
                println!("  NOT CAUGHT  {name}: every check still passed");
            } else {
                caught += 1;
                println!("  caught  {name}: {} check(s) failed, e.g. {}", r.failed.len(), r.failed[0]);
            }
        }
        println!("self-test: {caught} of {} broken rules caught", selftest::MUTATIONS.len());
        if caught != selftest::MUTATIONS.len() {
            code = 1;
        }
    }
    std::process::exit(code);
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("scheduler-selftest runs on macOS only");
    std::process::exit(2);
}
