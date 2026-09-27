//! Records from the machine's default microphone. Ignored by default: CI has none. Nothing is kept
//! or printed but the counts.
//!
//! `cargo test -p lt-capture --test default_microphone -- --ignored --nocapture`

use std::thread;
use std::time::Duration;

use lt_capture::{Recorder, RecorderConfiguration};

#[test]
#[ignore = "records from the default microphone"]
fn records_a_second_from_the_default_microphone() {
    let recorder = Recorder::new(RecorderConfiguration {
        max_duration_seconds: 5,
    })
    .expect("the recorder's thread starts");
    let input = recorder.start().expect("the default microphone opens");
    println!(
        "{}: {} Hz, {} channels",
        input.device, input.sample_rate, input.channels
    );
    thread::sleep(Duration::from_secs(1));
    let recording = recorder.stop();
    let peak = recording
        .samples
        .iter()
        .fold(0.0_f32, |peak, sample| peak.max(sample.abs()));
    println!(
        "{} ms recorded, peak {peak:.3}, failure {:?}",
        recording.duration_ms(),
        recording.failure
    );
    assert!(recording.failure.is_none());
    assert!(!recording.truncated);
    // The stream takes a moment to start, and the last buffer may not have arrived.
    assert!(
        (700..=1_100).contains(&recording.duration_ms()),
        "{} ms",
        recording.duration_ms()
    );
    assert!(recording.samples.iter().all(|sample| (-1.0..=1.0).contains(sample)));

    // A second recording opens the device again.
    recorder.start().expect("the microphone opens again");
    thread::sleep(Duration::from_millis(300));
    recorder.cancel();
}
