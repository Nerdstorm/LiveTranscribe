//! Records from the machine's default microphone, and from each microphone by its id. Ignored by
//! default: CI has none. Nothing is kept or printed but the counts, and the microphones' names.
//!
//! `cargo test -p lt-capture --test default_microphone -- --ignored --nocapture`

use std::thread;
use std::time::Duration;

use lt_capture::{Recorder, RecorderConfiguration, input_devices};

#[test]
#[ignore = "records from the default microphone"]
fn records_a_second_from_the_default_microphone() {
    let recorder = Recorder::new(RecorderConfiguration {
        max_duration_seconds: 5,
        device: None,
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

#[test]
#[ignore = "records from each microphone"]
fn records_from_a_microphone_chosen_by_its_id() {
    let inputs = input_devices().expect("the microphones can be listed");
    println!("default: {:?}", inputs.default);
    assert!(!inputs.devices.is_empty(), "a microphone is connected");
    for device in &inputs.devices {
        println!("{}: {}", device.id, device.name);
        let recorder = Recorder::new(RecorderConfiguration {
            max_duration_seconds: 5,
            device: Some(device.id.clone()),
        })
        .expect("the recorder's thread starts");
        let opening = std::time::Instant::now();
        let input = recorder.start().expect("the microphone opens");
        println!("  opened in {} ms", opening.elapsed().as_millis());
        assert!(!input.chosen_missing, "{} was found by its id", device.id);
        thread::sleep(Duration::from_millis(500));
        let recording = recorder.stop();
        println!(
            "  {} ms recorded, failure {:?}",
            recording.duration_ms(),
            recording.failure
        );
        assert!(recording.failure.is_none());
    }

    // One that isn't connected falls back to the default input.
    let recorder = Recorder::new(RecorderConfiguration {
        max_duration_seconds: 5,
        device: Some("pulseaudio:not-a-microphone".to_owned()),
    })
    .expect("the recorder's thread starts");
    let input = recorder.start().expect("the default input opens instead");
    assert!(input.chosen_missing);
    recorder.cancel();
}
