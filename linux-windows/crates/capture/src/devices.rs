//! The microphones the system offers, and which one a recording opens: the one chosen in
//! Settings while it is connected, otherwise the system's default input.

use std::str::FromStr;

use cpal::DeviceId;
#[cfg(target_os = "linux")]
use cpal::HostId;
use cpal::traits::{DeviceTrait, HostTrait};

use crate::CaptureError;

/// A microphone, as Settings lists and keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputDevice {
    /// The same across runs and reconnections, so Settings keeps it: the audio system's name for
    /// the device, such as `pulseaudio:alsa_input.usb-Blue_Yeti-00.analog-stereo`.
    pub id: String,
    /// The name the system shows for it.
    pub name: String,
}

/// The microphones connected now.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InputDevices {
    pub devices: Vec<InputDevice>,
    /// The system's default input, one of `devices`, if there is one.
    pub default: Option<String>,
}

/// The microphones connected now, in the audio system's order.
pub fn input_devices() -> Result<InputDevices, CaptureError> {
    let host = cpal::default_host();
    let default = host
        .default_input_device()
        .and_then(|device| device.id().ok())
        .map(|id| id.to_string());
    let devices = host
        .input_devices()?
        .filter_map(|device| {
            let id = device.id().ok()?;
            is_microphone(&id).then(|| InputDevice {
                id: id.to_string(),
                name: name(&device).unwrap_or_else(|| id.to_string()),
            })
        })
        .collect();
    Ok(InputDevices { devices, default })
}

/// The device a recording opens for `chosen` (an [`InputDevice::id`], or `None` for the default),
/// and whether the chosen one was missing, so the default is opened instead.
pub(crate) fn device_to_open(host: &cpal::Host, chosen: Option<&str>) -> Result<(cpal::Device, bool), CaptureError> {
    if let Some(chosen) = chosen {
        match DeviceId::from_str(chosen).ok().and_then(|id| host.device_by_id(&id)) {
            Some(device) => return Ok((device, false)),
            None => {
                tracing::warn!("The chosen microphone ({chosen}) isn't connected; recording from the default input")
            }
        }
    }
    let device = host.default_input_device().ok_or(CaptureError::NoInputDevice)?;
    Ok((device, chosen.is_some()))
}

pub(crate) fn name(device: &cpal::Device) -> Option<String> {
    device
        .description()
        .ok()
        .map(|description| description.name().trim().to_owned())
        .filter(|name| !name.is_empty())
}

/// Whether a device the audio system lists as an input is one to offer: a sound server's monitor
/// of an output (what the speakers play) is not a microphone.
fn is_microphone(id: &DeviceId) -> bool {
    #[cfg(target_os = "linux")]
    if id.host() == HostId::PulseAudio && id.id().ends_with(".monitor") {
        return false;
    }
    let _ = id;
    true
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn a_sound_servers_monitors_are_not_microphones() {
        let source = DeviceId::new(HostId::PulseAudio, "alsa_input.pci-0000_00_1f.3.analog-stereo");
        let monitor = DeviceId::new(HostId::PulseAudio, "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor");
        assert!(is_microphone(&source));
        assert!(!is_microphone(&monitor));
        assert!(is_microphone(&DeviceId::new(HostId::Alsa, "hw:CARD=0,DEV=0")));
    }

    #[test]
    fn ids_are_kept_as_text_and_read_back() {
        let id = DeviceId::new(HostId::PulseAudio, "alsa_input.usb-Blue_Yeti-00.analog-stereo");
        let kept = id.to_string();
        assert_eq!(kept, "pulseaudio:alsa_input.usb-Blue_Yeti-00.analog-stereo");
        assert_eq!(DeviceId::from_str(&kept).expect("an id"), id);
    }
}
