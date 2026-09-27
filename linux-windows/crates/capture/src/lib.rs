//! Recording the microphone for dictation, mirroring the Mac app's DictationRecorder: the
//! microphone chosen in Settings, or the system's default input, opened on start and closed on
//! stop, its channels mixed to one and converted to the models' 16 kHz.
//!
//! On Linux the microphones are the sound server's (PulseAudio's protocol, which PipeWire
//! serves too), with ALSA's default device when there is no sound server.
//!
//! cpal's stream can't move between threads on every system, so it lives on a thread of its own
//! and a [`Recorder`] talks to that thread: a recorder can be used from any thread. Audio is
//! never written anywhere: it stays in memory until the caller takes it.

mod devices;
mod resample;

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::Instant;

use cpal::traits::{DeviceTrait, StreamTrait};
use cpal::{BufferSize, FromSample, Sample, SampleFormat, SizedSample, SupportedBufferSize};
use lt_shared::audio_format::milliseconds_for_samples;

pub use devices::{InputDevice, InputDevices, input_devices};
pub use resample::{ResampleError, to_model_rate};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecorderConfiguration {
    /// A recording longer than this keeps only its start, and says so.
    pub max_duration_seconds: u32,
    /// The microphone to record ([`InputDevice::id`]); `None` for the system's default input. A
    /// chosen microphone that isn't connected falls back to the default.
    pub device: Option<String>,
}

/// What one recording captured.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Recording {
    /// 16 kHz mono samples in [-1, 1].
    pub samples: Vec<f32>,
    /// The recording reached the limit and the rest was dropped.
    pub truncated: bool,
    /// Capture failed during the recording; `samples` holds what arrived before it did.
    pub failure: Option<String>,
}

impl Recording {
    pub fn duration_ms(&self) -> usize {
        milliseconds_for_samples(self.samples.len())
    }
}

/// The input a recording started on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Input {
    pub device: String,
    pub sample_rate: u32,
    pub channels: u16,
    /// The chosen microphone isn't connected, so this is the system's default input.
    pub chosen_missing: bool,
}

#[derive(Debug)]
pub enum CaptureError {
    /// The system has no microphone, or no default one.
    NoInputDevice,
    Device(cpal::Error),
    UnsupportedFormat(SampleFormat),
    /// The recorder's thread has ended.
    Stopped,
}

impl std::fmt::Display for CaptureError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoInputDevice => formatter.write_str("no microphone was found"),
            Self::Device(error) => write!(formatter, "the microphone couldn't be opened: {error}"),
            Self::UnsupportedFormat(format) => {
                write!(
                    formatter,
                    "the microphone delivers {format:?} samples, which aren't read"
                )
            }
            Self::Stopped => formatter.write_str("the recorder has stopped"),
        }
    }
}

impl std::error::Error for CaptureError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Device(error) => Some(error),
            _ => None,
        }
    }
}

impl From<cpal::Error> for CaptureError {
    fn from(error: cpal::Error) -> Self {
        Self::Device(error)
    }
}

enum Command {
    Configure(RecorderConfiguration),
    Start(mpsc::Sender<Result<Input, CaptureError>>),
    Stop(mpsc::Sender<Recording>),
    Cancel,
}

/// The microphone's level while recording, for the dictation panel's meter: the RMS of the
/// latest buffer, 0...1 (the Mac's DictationRecorder.rms). Zero while nothing records.
#[derive(Debug, Default)]
pub struct InputLevel(AtomicU32);

impl InputLevel {
    pub fn get(&self) -> f32 {
        f32::from_bits(self.0.load(Ordering::Relaxed))
    }

    fn set(&self, level: f32) {
        self.0.store(level.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }
}

/// Records the microphone, one recording at a time.
pub struct Recorder {
    commands: mpsc::Sender<Command>,
    level: Arc<InputLevel>,
}

impl Recorder {
    /// Starts the recorder's thread; the microphone stays closed until [`Recorder::start`].
    pub fn new(configuration: RecorderConfiguration) -> std::io::Result<Self> {
        let (commands, received) = mpsc::channel();
        let level = Arc::new(InputLevel::default());
        let recording_level = Arc::clone(&level);
        thread::Builder::new()
            .name("capture".to_owned())
            .spawn(move || run(configuration, &received, &recording_level))?;
        Ok(Self { commands, level })
    }

    /// The level of the recording in progress, updated with every buffer.
    pub fn level(&self) -> Arc<InputLevel> {
        Arc::clone(&self.level)
    }

    /// Records with `configuration` from the next start; a recording in progress keeps the one it
    /// started with.
    pub fn configure(&self, configuration: RecorderConfiguration) {
        // With the thread gone there is nothing to configure: the next start says so.
        let _ = self.commands.send(Command::Configure(configuration));
    }

    /// Opens the microphone and starts recording, replacing a recording in progress. Returns
    /// once the stream has started (tens of milliseconds through the sound server), or the
    /// microphone failed to open; what is said from then on is recorded.
    pub fn start(&self) -> Result<Input, CaptureError> {
        let (reply, answer) = mpsc::channel();
        self.commands
            .send(Command::Start(reply))
            .map_err(|_| CaptureError::Stopped)?;
        answer.recv().map_err(|_| CaptureError::Stopped)?
    }

    /// Closes the microphone and returns the recording: empty when none was running.
    pub fn stop(&self) -> Recording {
        let (reply, answer) = mpsc::channel();
        if self.commands.send(Command::Stop(reply)).is_err() {
            return Recording {
                failure: Some(CaptureError::Stopped.to_string()),
                ..Recording::default()
            };
        }
        answer.recv().unwrap_or_else(|_| Recording {
            failure: Some(CaptureError::Stopped.to_string()),
            ..Recording::default()
        })
    }

    /// Closes the microphone and throws the recording away.
    pub fn cancel(&self) {
        // With the thread gone there is nothing to cancel.
        let _ = self.commands.send(Command::Cancel);
    }
}

fn run(mut configuration: RecorderConfiguration, commands: &mpsc::Receiver<Command>, level: &Arc<InputLevel>) {
    let mut active: Option<Active> = None;
    for command in commands {
        match command {
            Command::Configure(changed) => configuration = changed,
            Command::Start(reply) => {
                active = None;
                let answer = match Active::open(&configuration, level) {
                    Ok(opened) => {
                        let input = opened.input.clone();
                        active = Some(opened);
                        Ok(input)
                    }
                    Err(error) => {
                        tracing::error!("The microphone couldn't start: {error}");
                        Err(error)
                    }
                };
                let _ = reply.send(answer);
            }
            Command::Stop(reply) => {
                let recording = active.take().map(Active::finish).unwrap_or_default();
                level.set(0.0);
                let _ = reply.send(recording);
            }
            Command::Cancel => {
                active = None;
                level.set(0.0);
            }
        }
    }
}

/// A recording in progress: the open stream and what it has delivered.
struct Active {
    stream: cpal::Stream,
    captured: Arc<Mutex<Captured>>,
    input: Input,
    started: Instant,
}

impl Active {
    fn open(configuration: &RecorderConfiguration, level: &Arc<InputLevel>) -> Result<Self, CaptureError> {
        let started = Instant::now();
        let host = cpal::default_host();
        let (device, chosen_missing) = devices::device_to_open(&host, configuration.device.as_deref())?;
        let supported = device.default_input_config()?;
        let mut config = supported.config();
        config.buffer_size = buffer_size(supported.buffer_size(), config.sample_rate);
        let input = Input {
            device: devices::name(&device).unwrap_or_else(|| "the default microphone".to_owned()),
            sample_rate: config.sample_rate,
            channels: config.channels,
            chosen_missing,
        };
        let limit = configuration.max_duration_seconds as usize * config.sample_rate as usize;
        let captured = Arc::new(Mutex::new(Captured::new(limit, config.sample_rate as usize)));
        let stream = match supported.sample_format() {
            SampleFormat::F32 => build::<f32>(&device, config, &captured, level),
            SampleFormat::F64 => build::<f64>(&device, config, &captured, level),
            SampleFormat::I8 => build::<i8>(&device, config, &captured, level),
            SampleFormat::I16 => build::<i16>(&device, config, &captured, level),
            SampleFormat::I32 => build::<i32>(&device, config, &captured, level),
            SampleFormat::U8 => build::<u8>(&device, config, &captured, level),
            SampleFormat::U16 => build::<u16>(&device, config, &captured, level),
            SampleFormat::U32 => build::<u32>(&device, config, &captured, level),
            other => return Err(CaptureError::UnsupportedFormat(other)),
        }?;
        stream.play()?;
        tracing::info!(
            "Recording from {} ({} Hz, {} channels), opened in {} ms",
            input.device,
            input.sample_rate,
            input.channels,
            started.elapsed().as_millis()
        );
        Ok(Self {
            stream,
            captured,
            input,
            started: Instant::now(),
        })
    }

    fn finish(self) -> Recording {
        // Dropping the stream stops the callbacks before the samples are taken.
        drop(self.stream);
        let captured = std::mem::take(&mut *lock(&self.captured));
        let mut failure = captured.failure;
        let samples = match to_model_rate(&captured.samples, self.input.sample_rate) {
            Ok(samples) => samples,
            Err(error) => {
                tracing::error!("The recording couldn't be converted to 16 kHz: {error}");
                failure.get_or_insert_with(|| error.to_string());
                Vec::new()
            }
        };
        tracing::info!(
            "Recorded {} ms in {} ms{}",
            milliseconds_for_samples(samples.len()),
            self.started.elapsed().as_millis(),
            if captured.truncated { ", cut at the limit" } else { "" }
        );
        Recording {
            samples,
            truncated: captured.truncated,
            failure,
        }
    }
}

/// Audio in each callback, in milliseconds. The device's default can be long: a sound server's
/// is two seconds, and its stream only starts once the first buffer has filled, which would lose
/// the dictation's first words. Short buffers start at once, and move the meter smoothly.
const BUFFER_MS: u32 = 20;

fn buffer_size(supported: &SupportedBufferSize, sample_rate: u32) -> BufferSize {
    match supported {
        SupportedBufferSize::Range { min, max } => {
            BufferSize::Fixed((sample_rate * BUFFER_MS / 1_000).clamp(*min, (*max).max(*min)))
        }
        SupportedBufferSize::Unknown => BufferSize::Default,
    }
}

fn build<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    captured: &Arc<Mutex<Captured>>,
    level: &Arc<InputLevel>,
) -> Result<cpal::Stream, CaptureError>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = usize::from(config.channels.max(1));
    let receiving = Arc::clone(captured);
    let metering = Arc::clone(level);
    let failing = Arc::clone(captured);
    let stream = device.build_input_stream::<T, _, _>(
        config,
        move |data: &[T], _| metering.set(lock(&receiving).append(data, channels)),
        move |error| {
            if error.kind() == cpal::ErrorKind::DeviceChanged {
                tracing::info!("The microphone changed: {error}");
                return;
            }
            tracing::error!("The microphone stopped: {error}");
            lock(&failing).failure.get_or_insert_with(|| error.to_string());
        },
        None,
    )?;
    Ok(stream)
}

/// What the stream has delivered, mixed to mono at the device's rate.
#[derive(Default)]
struct Captured {
    samples: Vec<f32>,
    limit: usize,
    truncated: bool,
    failure: Option<String>,
}

impl Captured {
    fn new(limit: usize, sample_rate: usize) -> Self {
        Self {
            // Ten seconds up front, so a typical dictation never reallocates in the callback.
            samples: Vec::with_capacity((sample_rate * 10).min(limit)),
            limit,
            ..Self::default()
        }
    }

    /// Mixes `interleaved` to mono and keeps it, up to the limit. Returns the buffer's level (RMS),
    /// past the limit too: the meter keeps moving while the recording goes on.
    fn append<T>(&mut self, interleaved: &[T], channels: usize) -> f32
    where
        T: SizedSample,
        f32: FromSample<T>,
    {
        let mut squares = 0.0_f32;
        let mut frames = 0_usize;
        for frame in interleaved.chunks_exact(channels) {
            let sum: f32 = frame.iter().map(|&sample| f32::from_sample(sample)).sum();
            let mixed = sum / channels as f32;
            squares += mixed * mixed;
            frames += 1;
            if self.samples.len() >= self.limit {
                self.truncated = true;
            } else {
                self.samples.push(mixed);
            }
        }
        if frames == 0 {
            0.0
        } else {
            (squares / frames as f32).sqrt().min(1.0)
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use lt_shared::audio_format::SAMPLE_RATE;

    use super::*;

    #[test]
    fn mixes_channels_and_stops_at_the_limit() {
        let mut captured = Captured::new(3, 48_000);
        let level = captured.append(&[0.5_f32, -0.5, 1.0, 0.0], 2);
        assert_eq!(captured.samples, [0.0, 0.5]);
        assert!((level - (0.125_f32).sqrt()).abs() < 1e-6, "RMS of 0 and 0.5");
        assert!(!captured.truncated);
        captured.append(&[i16::MAX, i16::MAX, 0, 0], 2);
        assert_eq!(captured.samples.len(), 3);
        assert!((captured.samples[2] - 1.0).abs() < 1e-4);
        assert!(captured.truncated);
    }

    #[test]
    fn buffers_are_short_where_the_device_allows() {
        let range = |min, max| SupportedBufferSize::Range { min, max };
        assert_eq!(buffer_size(&range(1, 1 << 20), 48_000), BufferSize::Fixed(960));
        assert_eq!(buffer_size(&range(2_048, 8_192), 48_000), BufferSize::Fixed(2_048));
        assert_eq!(buffer_size(&range(16, 256), 16_000), BufferSize::Fixed(256));
        assert_eq!(buffer_size(&SupportedBufferSize::Unknown, 48_000), BufferSize::Default);
    }

    #[test]
    fn a_recording_knows_its_length() {
        let recording = Recording {
            samples: vec![0.0; SAMPLE_RATE / 2],
            ..Recording::default()
        };
        assert_eq!(recording.duration_ms(), 500);
    }
}
