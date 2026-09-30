//! Downloads and checks the pinned cleanup model into a models folder, as the app would, and
//! prints where it is.
//!
//! ```text
//! cargo run -p lt-language-model --release --example prepare -- <models folder>
//! ```

use std::path::PathBuf;
use std::time::Instant;

use lt_language_model::pinned_model::{Progress, Stage};
use lt_language_model::{CLEANUP_MODEL, prepare};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let models = PathBuf::from(std::env::args().nth(1).ok_or("usage: prepare <models folder>")?);
    let started = Instant::now();
    let mut last = None;
    let folder = prepare(&CLEANUP_MODEL, &models, &mut |progress: Progress| {
        let percent = progress.done * 100 / progress.total.max(1);
        if last != Some((progress.stage, percent / 10)) {
            last = Some((progress.stage, percent / 10));
            let stage = match progress.stage {
                Stage::Checking => "Checking",
                Stage::Downloading => "Downloading",
            };
            eprintln!("{stage} {percent}% ({:.0} s)", started.elapsed().as_secs_f64());
        }
        true
    })?;
    eprintln!("Ready in {:.1} s", started.elapsed().as_secs_f64());
    println!("{}", folder.display());
    Ok(())
}
