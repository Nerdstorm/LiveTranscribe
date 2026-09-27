//! Where the mouse pointer is. Wayland tells a client about the pointer only over the client's
//! own surfaces, and the panel takes no input, so the position comes from cursor sessions
//! (ext-image-copy-capture-v1) instead: one per output, each saying where the pointer's hotspot
//! is while it is on that output, without capturing anything. They run only while the panel
//! shows. Each output's mode, transform and logical size (xdg-output) turn the position into
//! logical pixels.

use wayland_client::globals::GlobalList;
use wayland_client::protocol::wl_output::{self, Transform, WlOutput};
use wayland_client::protocol::wl_pointer::WlPointer;
use wayland_client::protocol::wl_registry::WlRegistry;
use wayland_client::protocol::wl_seat::{self, Capability, WlSeat};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, WEnum, delegate_noop};
use wayland_protocols::ext::image_capture_source::v1::client::ext_image_capture_source_v1::ExtImageCaptureSourceV1;
use wayland_protocols::ext::image_capture_source::v1::client::ext_output_image_capture_source_manager_v1::ExtOutputImageCaptureSourceManagerV1;
use wayland_protocols::ext::image_copy_capture::v1::client::ext_image_copy_capture_cursor_session_v1::{
    self, ExtImageCopyCaptureCursorSessionV1,
};
use wayland_protocols::ext::image_copy_capture::v1::client::ext_image_copy_capture_manager_v1::ExtImageCopyCaptureManagerV1;
use wayland_protocols::xdg::xdg_output::zv1::client::zxdg_output_manager_v1::ZxdgOutputManagerV1;
use wayland_protocols::xdg::xdg_output::zv1::client::zxdg_output_v1::{self, ZxdgOutputV1};

use crate::event_loop::{State, Wayland};

/// The newest wl_output this reads: its name and description events go unused.
const OUTPUT_VERSION: u32 = 4;

/// Where the pointer is.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct PointerAt {
    /// The global name of the output it is on.
    pub(crate) output: u32,
    /// Where on the output, in logical pixels from its top-left corner.
    pub(crate) x: f32,
    pub(crate) y: f32,
    /// The output's size in logical pixels.
    pub(crate) screen: (f32, f32),
}

/// What the compositor has said about the outputs and the pointer on them.
#[derive(Default)]
pub(crate) struct PointerState {
    outputs: Vec<Output>,
    /// wl_output globals added (name, version) and removed since the tracker last looked.
    added: Vec<(u32, u32)>,
    removed: Vec<u32>,
    pointer_capable: bool,
}

impl PointerState {
    /// Where the pointer is, on whichever output has it.
    pub(crate) fn pointer(&self) -> Option<PointerAt> {
        self.outputs.iter().find_map(Output::pointer_at)
    }

    /// Where the pointer is on the output named `output`, if it is on it.
    pub(crate) fn pointer_on(&self, output: u32) -> Option<PointerAt> {
        self.output(output).and_then(Output::pointer_at)
    }

    pub(crate) fn wl_output(&self, output: u32) -> Option<&WlOutput> {
        self.output(output).map(|output| &output.output)
    }

    /// A global the compositor added, from the registry.
    pub(crate) fn global_added(&mut self, name: u32, interface: &str, version: u32) {
        if interface == WlOutput::interface().name {
            self.added.push((name, version));
        }
    }

    /// A global the compositor removed, from the registry.
    pub(crate) fn global_removed(&mut self, name: u32) {
        self.removed.push(name);
    }

    fn output(&self, name: u32) -> Option<&Output> {
        self.outputs.iter().find(|output| output.name == name)
    }

    fn output_mut(&mut self, name: u32) -> Option<&mut Output> {
        self.outputs.iter_mut().find(|output| output.name == name)
    }
}

/// An output, and the cursor session on it while the pointer is followed.
struct Output {
    /// The wl_output global's name.
    name: u32,
    output: WlOutput,
    xdg: Option<ZxdgOutputV1>,
    geometry: OutputGeometry,
    cursor: Option<Cursor>,
}

impl Output {
    fn pointer_at(&self) -> Option<PointerAt> {
        let position = self.cursor.as_ref()?.position?;
        let (x, y) = self.geometry.logical(position)?;
        Some(PointerAt {
            output: self.name,
            x,
            y,
            screen: self.geometry.size()?,
        })
    }

    fn destroy(self) {
        if let Some(cursor) = self.cursor {
            cursor.destroy();
        }
        if let Some(xdg) = self.xdg {
            xdg.destroy();
        }
        if self.output.version() >= 3 {
            self.output.release();
        }
    }
}

/// A cursor session, and where it says the pointer's hotspot is: in the output's pixels as the
/// output shows them, while the pointer is on it.
struct Cursor {
    source: ExtImageCaptureSourceV1,
    session: ExtImageCopyCaptureCursorSessionV1,
    position: Option<(i32, i32)>,
}

impl Cursor {
    fn destroy(self) {
        self.session.destroy();
        self.source.destroy();
    }
}

/// What the compositor says about an output's size.
#[derive(Clone, Copy, Debug, PartialEq)]
struct OutputGeometry {
    /// The current mode, in pixels, before the output's transform.
    mode: Option<(i32, i32)>,
    transform: Transform,
    /// Its whole scale (wl_output), for when xdg-output gives no logical size.
    scale: i32,
    /// Its size in logical pixels (xdg-output).
    logical_size: Option<(i32, i32)>,
}

impl Default for OutputGeometry {
    fn default() -> Self {
        Self {
            mode: None,
            transform: Transform::Normal,
            scale: 1,
            logical_size: None,
        }
    }
}

impl OutputGeometry {
    /// Its size in pixels as it shows them: turned a quarter, width and height swap.
    fn pixels(&self) -> Option<(f32, f32)> {
        let (width, height) = self.mode.filter(|&(width, height)| width > 0 && height > 0)?;
        let quarter_turned = matches!(
            self.transform,
            Transform::_90 | Transform::_270 | Transform::Flipped90 | Transform::Flipped270
        );
        let (width, height) = if quarter_turned {
            (height, width)
        } else {
            (width, height)
        };
        Some((width as f32, height as f32))
    }

    /// Its size in logical pixels: xdg-output's, or its pixels over its whole scale.
    fn size(&self) -> Option<(f32, f32)> {
        match self.logical_size {
            Some((width, height)) if width > 0 && height > 0 => Some((width as f32, height as f32)),
            _ => {
                let scale = self.scale.max(1) as f32;
                self.pixels().map(|(width, height)| (width / scale, height / scale))
            }
        }
    }

    /// A position in its pixels as logical pixels, if it is on the output. A cursor session
    /// reports the pointer while any of its image overlaps the output, which can put the hotspot
    /// just off it.
    fn logical(&self, (x, y): (i32, i32)) -> Option<(f32, f32)> {
        let (pixel_width, pixel_height) = self.pixels()?;
        let (width, height) = self.size()?;
        let (x, y) = (x as f32, y as f32);
        (x >= 0.0 && y >= 0.0 && x < pixel_width && y < pixel_height)
            .then(|| (x * width / pixel_width, y * height / pixel_height))
    }
}

/// Follows the pointer while the panel shows, where the compositor lets it.
pub(crate) struct PointerTracker {
    registry: WlRegistry,
    seat: WlSeat,
    xdg_outputs: Option<ZxdgOutputManagerV1>,
    capture: Option<(ExtOutputImageCaptureSourceManagerV1, ExtImageCopyCaptureManagerV1)>,
    pointer: Option<WlPointer>,
}

impl PointerTracker {
    /// Binds the outputs there are now; later ones come through the registry.
    pub(crate) fn bind(globals: &GlobalList, seat: &WlSeat, wayland: &mut Wayland) -> Self {
        let handle = &wayland.handle;
        let sources: Option<ExtOutputImageCaptureSourceManagerV1> = globals.bind(handle, 1..=1, ()).ok();
        let capture: Option<ExtImageCopyCaptureManagerV1> = globals.bind(handle, 1..=1, ()).ok();
        let mut tracker = Self {
            registry: globals.registry().clone(),
            seat: seat.clone(),
            xdg_outputs: globals.bind(handle, 1..=3, ()).ok(),
            capture: sources.zip(capture),
            pointer: None,
        };
        wayland.state.pointer.added = globals
            .contents()
            .clone_list()
            .into_iter()
            .filter(|global| global.interface == WlOutput::interface().name)
            .map(|global| (global.name, global.version))
            .collect();
        tracker.update_outputs(wayland);
        tracker
    }

    /// The compositor says where the pointer is.
    pub(crate) fn can_follow(&self) -> bool {
        self.capture.is_some()
    }

    /// Takes in the outputs added and removed since the last turn. Returns whether there were any.
    pub(crate) fn update_outputs(&mut self, wayland: &mut Wayland) -> bool {
        let state = &mut wayland.state.pointer;
        let removed = std::mem::take(&mut state.removed);
        let added = std::mem::take(&mut state.added);
        let mut changed = false;
        for name in removed {
            if let Some(index) = state.outputs.iter().position(|output| output.name == name) {
                state.outputs.swap_remove(index).destroy();
                changed = true;
            }
        }
        for (name, version) in added {
            let output: WlOutput = self
                .registry
                .bind(name, version.min(OUTPUT_VERSION), &wayland.handle, name);
            let xdg = self
                .xdg_outputs
                .as_ref()
                .map(|manager| manager.get_xdg_output(&output, &wayland.handle, name));
            state.outputs.push(Output {
                name,
                output,
                xdg,
                geometry: OutputGeometry::default(),
                cursor: None,
            });
            changed = true;
        }
        changed
    }

    /// Follows the pointer on every output, from now until [`Self::stop`].
    pub(crate) fn start(&mut self, wayland: &mut Wayland) {
        let Some((sources, capture)) = &self.capture else {
            return;
        };
        let state = &mut wayland.state.pointer;
        if self.pointer.is_none() && state.pointer_capable {
            self.pointer = Some(self.seat.get_pointer(&wayland.handle, ()));
        }
        let Some(pointer) = &self.pointer else {
            return;
        };
        for output in state.outputs.iter_mut().filter(|output| output.cursor.is_none()) {
            let source = sources.create_source(&output.output, &wayland.handle, ());
            let session = capture.create_pointer_cursor_session(&source, pointer, &wayland.handle, output.name);
            output.cursor = Some(Cursor {
                source,
                session,
                position: None,
            });
        }
    }

    pub(crate) fn stop(&mut self, wayland: &mut Wayland) {
        for output in &mut wayland.state.pointer.outputs {
            if let Some(cursor) = output.cursor.take() {
                cursor.destroy();
            }
        }
    }
}

delegate_noop!(State: ZxdgOutputManagerV1);
delegate_noop!(State: ExtOutputImageCaptureSourceManagerV1);
delegate_noop!(State: ExtImageCaptureSourceV1);
delegate_noop!(State: ExtImageCopyCaptureManagerV1);
// The panel takes no input, so the pointer has nothing to say to it.
delegate_noop!(State: ignore WlPointer);

impl Dispatch<WlSeat, ()> for State {
    fn event(state: &mut Self, _: &WlSeat, event: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wl_seat::Event::Capabilities {
            capabilities: WEnum::Value(capabilities),
        } = event
        {
            state.pointer.pointer_capable = capabilities.contains(Capability::Pointer);
        }
    }
}

impl Dispatch<WlOutput, u32> for State {
    fn event(
        state: &mut Self,
        _: &WlOutput,
        event: wl_output::Event,
        name: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(output) = state.pointer.output_mut(*name) else {
            return;
        };
        let geometry = &mut output.geometry;
        match event {
            wl_output::Event::Geometry {
                transform: WEnum::Value(transform),
                ..
            } => geometry.transform = transform,
            wl_output::Event::Mode {
                flags: WEnum::Value(flags),
                width,
                height,
                ..
            } if flags.contains(wl_output::Mode::Current) => geometry.mode = Some((width, height)),
            wl_output::Event::Scale { factor } => geometry.scale = factor,
            _ => {}
        }
    }
}

impl Dispatch<ZxdgOutputV1, u32> for State {
    fn event(
        state: &mut Self,
        _: &ZxdgOutputV1,
        event: zxdg_output_v1::Event,
        name: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zxdg_output_v1::Event::LogicalSize { width, height } = event
            && let Some(output) = state.pointer.output_mut(*name)
        {
            output.geometry.logical_size = Some((width, height));
        }
    }
}

impl Dispatch<ExtImageCopyCaptureCursorSessionV1, u32> for State {
    fn event(
        state: &mut Self,
        _: &ExtImageCopyCaptureCursorSessionV1,
        event: ext_image_copy_capture_cursor_session_v1::Event,
        name: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(cursor) = state
            .pointer
            .output_mut(*name)
            .and_then(|output| output.cursor.as_mut())
        else {
            return;
        };
        match event {
            ext_image_copy_capture_cursor_session_v1::Event::Position { x, y } => cursor.position = Some((x, y)),
            ext_image_copy_capture_cursor_session_v1::Event::Leave => cursor.position = None,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn geometry(
        mode: (i32, i32),
        transform: Transform,
        scale: i32,
        logical_size: Option<(i32, i32)>,
    ) -> OutputGeometry {
        OutputGeometry {
            mode: Some(mode),
            transform,
            scale,
            logical_size,
        }
    }

    #[test]
    fn a_position_in_pixels_becomes_logical_at_a_fractional_scale() {
        // 2880 × 1800 at 180 %: 1600 × 1000 logical pixels.
        let output = geometry((2_880, 1_800), Transform::Normal, 2, Some((1_600, 1_000)));
        assert_eq!(output.size(), Some((1_600.0, 1_000.0)));
        assert_eq!(output.logical((1_440, 900)), Some((800.0, 500.0)));
        assert_eq!(output.logical((0, 0)), Some((0.0, 0.0)));
    }

    #[test]
    fn a_position_off_the_output_is_not_on_it() {
        let output = geometry((1_920, 1_080), Transform::Normal, 1, Some((1_920, 1_080)));
        assert_eq!(output.logical((-1, 10)), None);
        assert_eq!(output.logical((1_920, 10)), None);
        assert_eq!(output.logical((10, 1_080)), None);
        assert_eq!(output.logical((1_919, 1_079)), Some((1_919.0, 1_079.0)));
    }

    #[test]
    fn a_quarter_turned_output_swaps_its_width_and_height() {
        // A 2560 × 1600 panel turned upright at 200 %: 800 × 1280 logical pixels.
        let output = geometry((2_560, 1_600), Transform::_90, 2, Some((800, 1_280)));
        assert_eq!(output.pixels(), Some((1_600.0, 2_560.0)));
        assert_eq!(output.logical((800, 2_000)), Some((400.0, 1_000.0)));
        assert_eq!(output.logical((1_700, 10)), None);
    }

    #[test]
    fn without_xdg_output_the_whole_scale_gives_the_size() {
        let output = geometry((2_880, 1_800), Transform::Normal, 2, None);
        assert_eq!(output.size(), Some((1_440.0, 900.0)));
        assert_eq!(output.logical((2_000, 1_000)), Some((1_000.0, 500.0)));
    }

    #[test]
    fn an_output_without_a_mode_has_no_size() {
        let output = OutputGeometry::default();
        assert_eq!(output.pixels(), None);
        assert_eq!(output.logical((1, 1)), None);
    }
}
