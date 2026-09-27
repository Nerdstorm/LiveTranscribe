//! The dictation panel on screen. While a field with an input method has focus it is the input
//! method's popup, which the compositor puts just below the text cursor (COSMIC puts it above when
//! there's no room below); otherwise it is an overlay (wlr-layer-shell) at the bottom of the
//! screen, clear of the dock, as the Mac's HUD sits above the Dock.
//!
//! lt-dictation-ui draws it; this puts the pixels in shared memory at the screen's scale, moves the meter
//! and the spinner at 30 frames a second while the compositor shows them, and turns a click on the
//! × into [`SessionEvent::CancelClicked`]. The panel never takes the keyboard, and only the × takes
//! clicks: elsewhere they go through to the window below.

use std::time::{Duration, Instant};

use lt_dictation_ui::{Animation, Margins, PanelContent, PanelView, Rendered, Theme};
use wayland_client::globals::GlobalList;
use wayland_client::protocol::wl_callback::{self, WlCallback};
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_pointer::{self, ButtonState, WlPointer};
use wayland_client::protocol::wl_region::WlRegion;
use wayland_client::protocol::wl_seat::{self, Capability, WlSeat};
use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::protocol::wl_surface::{self, WlSurface};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum, delegate_noop};
use wayland_protocols::wp::cursor_shape::v1::client::wp_cursor_shape_device_v1::{Shape, WpCursorShapeDeviceV1};
use wayland_protocols::wp::cursor_shape::v1::client::wp_cursor_shape_manager_v1::WpCursorShapeManagerV1;
use wayland_protocols::wp::fractional_scale::v1::client::wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1;
use wayland_protocols::wp::fractional_scale::v1::client::wp_fractional_scale_v1::{self, WpFractionalScaleV1};
use wayland_protocols::wp::viewporter::client::wp_viewport::WpViewport;
use wayland_protocols::wp::viewporter::client::wp_viewporter::WpViewporter;
use wayland_protocols_misc::zwp_input_method_v2::client::zwp_input_method_v2::ZwpInputMethodV2;
use wayland_protocols_misc::zwp_input_method_v2::client::zwp_input_popup_surface_v2::{self, ZwpInputPopupSurfaceV2};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::{
    self, Anchor, KeyboardInteractivity, ZwlrLayerSurfaceV1,
};

use crate::event_loop::{State, Wayland};
use crate::session::{PanelConfiguration, SessionEvent};
use crate::shm::Buffers;

/// How often the meter and the spinner move.
const FRAME_INTERVAL: Duration = Duration::from_millis(33);
/// One turn of the spinner.
const SPIN_PERIOD: Duration = Duration::from_secs(1);
/// Transparent space above and below the capsule at the cursor. The popup touches the cursor, so
/// with the shadow's margin the capsule sits 10 px from it, as the Mac's HUD does.
const CURSOR_GAP: f32 = 6.0;
/// Above the bottom of the screen and clear of the dock, as the Mac's HUD sits 60 pt above the
/// Dock.
const OVERLAY_MARGIN: i32 = 60;
/// Focus moving from one field to another deactivates the input method for a moment: the panel
/// waits this long before leaving the cursor for the bottom of the screen.
const PLACEMENT_SETTLE: Duration = Duration::from_millis(150);
const LAYER_NAMESPACE: &str = "live-transcribe-panel";
/// linux/input-event-codes.h
const BTN_LEFT: u32 = 0x110;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Placement {
    /// Below the text cursor, as the input method's popup.
    AtCursor,
    /// At the bottom of the screen, as an overlay.
    Overlay,
}

enum Role {
    Popup(ZwpInputPopupSurfaceV2),
    Layer(ZwlrLayerSurfaceV1),
}

/// The panel's surface, made for one placement: a surface's role can't change.
struct Surface {
    id: u64,
    placement: Placement,
    surface: WlSurface,
    role: Role,
    viewport: Option<WpViewport>,
    fractional: Option<WpFractionalScaleV1>,
    /// The size last given, in logical pixels.
    size: Option<(u32, u32)>,
    /// The input region last given: the × in whole logical pixels, or nothing.
    input_region: Option<Option<[i32; 4]>>,
    /// An overlay shows nothing until its first configure is acknowledged.
    ready: bool,
}

impl Surface {
    fn destroy(self) {
        // The role and the extensions go before the surface they belong to.
        match self.role {
            Role::Popup(popup) => popup.destroy(),
            Role::Layer(layer) => layer.destroy(),
        }
        if let Some(viewport) = self.viewport {
            viewport.destroy();
        }
        if let Some(fractional) = self.fractional {
            fractional.destroy();
        }
        self.surface.destroy();
    }
}

/// What the compositor has said about the panel's surface and the pointer over it.
#[derive(Default)]
pub(crate) struct PanelState {
    /// The surface on screen. Events carry their surface's id, and those for one gone are dropped.
    surface: Option<(u64, WlSurface)>,
    /// An overlay's configure, to acknowledge.
    configure: Option<u32>,
    closed: bool,
    /// The compositor has shown the last frame, so the next can be drawn.
    frame_done: bool,
    /// The scale the compositor prefers: in 120ths (fractional-scale-v1), or whole.
    scale_120: Option<u32>,
    buffer_scale: Option<i32>,
    rescaled: bool,
    pointer_capable: bool,
    /// Where the pointer is over the panel, in logical pixels.
    pointer_at: Option<(f64, f64)>,
    /// The pointer came onto the panel with this serial; its shape is still to set.
    entered: Option<u32>,
    clicks: Vec<(f64, f64)>,
}

impl PanelState {
    fn is_current(&self, id: u64) -> bool {
        self.surface.as_ref().is_some_and(|(current, _)| *current == id)
    }

    /// The scale to draw at: the compositor's fractional scale where a viewport can use it,
    /// otherwise its whole one.
    fn scale(&self, has_viewport: bool) -> f32 {
        match (has_viewport, self.scale_120) {
            (true, Some(scale)) => scale as f32 / 120.0,
            _ => self.buffer_scale.unwrap_or(1).max(1) as f32,
        }
    }
}

pub(crate) struct Panel {
    view: PanelView,
    level: Box<dyn Fn() -> f32 + Send>,
    seat: WlSeat,
    compositor: WlCompositor,
    shm: WlShm,
    layer_shell: Option<ZwlrLayerShellV1>,
    viewporter: Option<WpViewporter>,
    fractional_scale: Option<WpFractionalScaleManagerV1>,
    cursor_shape: Option<WpCursorShapeManagerV1>,
    pointer: Option<(WlPointer, Option<WpCursorShapeDeviceV1>)>,
    buffers: Buffers,
    content: Option<PanelContent>,
    theme: Theme,
    surface: Option<Surface>,
    last_id: u64,
    /// The content, size or scale changed since the panel was last drawn.
    dirty: bool,
    last_frame: Option<Instant>,
    /// Where a click cancels on what is on screen: left, top, right, bottom.
    cancel: Option<[f32; 4]>,
    /// Since when no field has had focus while the panel is at the cursor.
    unfocused_since: Option<Instant>,
    /// The compositor closed the overlay: it stays closed until the content changes.
    closed: bool,
    started: Instant,
}

impl Panel {
    pub(crate) fn bind(
        globals: &GlobalList,
        seat: &WlSeat,
        handle: &QueueHandle<State>,
        configuration: PanelConfiguration,
    ) -> Option<Self> {
        let compositor: WlCompositor = globals
            .bind(handle, 4..=6, ())
            .inspect_err(|error| tracing::warn!("No dictation panel: {error}"))
            .ok()?;
        let shm: WlShm = globals
            .bind(handle, 1..=1, ())
            .inspect_err(|error| tracing::warn!("No dictation panel: {error}"))
            .ok()?;
        Some(Self {
            view: configuration.view,
            level: configuration.level,
            seat: seat.clone(),
            compositor,
            shm,
            layer_shell: globals.bind(handle, 1..=4, ()).ok(),
            viewporter: globals.bind(handle, 1..=1, ()).ok(),
            fractional_scale: globals.bind(handle, 1..=1, ()).ok(),
            cursor_shape: globals.bind(handle, 1..=1, ()).ok(),
            pointer: None,
            buffers: Buffers::default(),
            content: None,
            theme: Theme::Dark,
            surface: None,
            last_id: 0,
            dirty: true,
            last_frame: None,
            cancel: None,
            unfocused_since: None,
            closed: false,
            started: Instant::now(),
        })
    }

    /// The panel can show at the bottom of the screen.
    pub(crate) fn has_overlay(&self) -> bool {
        self.layer_shell.is_some()
    }

    pub(crate) fn show(&mut self, content: Option<PanelContent>) {
        if content == self.content {
            return;
        }
        if self.content.is_none() && content.is_some() {
            // It follows the desktop's light or dark mode as it appears.
            self.theme = Theme::detect();
        }
        self.content = content;
        self.dirty = true;
        self.closed = false;
    }

    /// Brings the screen up to date: the panel where it belongs, drawn when due. `focused` is the
    /// input method while a field has focus. Returns a click on the ×.
    pub(crate) fn update(
        &mut self,
        wayland: &mut Wayland,
        focused: Option<&ZwpInputMethodV2>,
        now: Instant,
    ) -> Option<SessionEvent> {
        self.follow_pointer(wayland);
        let cancelled = self.take_clicks(wayland);
        if std::mem::take(&mut wayland.state.panel.closed) {
            tracing::info!("The compositor closed the dictation panel");
            self.hide(wayland);
            self.closed = true;
        }
        match self.content.clone() {
            Some(content) if !self.closed => match self.placement(focused.is_some(), now) {
                Some(placement) => {
                    self.place(wayland, placement, focused, &content, now);
                    self.draw_if_due(wayland, &content, now);
                }
                None => self.hide(wayland),
            },
            _ => self.hide(wayland),
        }
        cancelled.then_some(SessionEvent::CancelClicked)
    }

    /// When the panel next needs the session: its next frame, or the end of the wait before it
    /// leaves the cursor.
    pub(crate) fn deadline(&self, state: &PanelState) -> Option<Instant> {
        let settle = self.unfocused_since.map(|since| since + PLACEMENT_SETTLE);
        let animated = self.content.as_ref().is_some_and(PanelContent::is_animated)
            && self.surface.as_ref().is_some_and(|surface| surface.ready)
            && state.frame_done;
        let frame = animated.then(|| self.last_frame.map_or_else(Instant::now, |last| last + FRAME_INTERVAL));
        settle.into_iter().chain(frame).min()
    }

    /// At the cursor while a field has focus, and for a moment after in case focus is only moving
    /// between fields; otherwise at the bottom of the screen.
    fn placement(&mut self, focused: bool, now: Instant) -> Option<Placement> {
        if focused {
            self.unfocused_since = None;
            return Some(Placement::AtCursor);
        }
        let at_cursor = self
            .surface
            .as_ref()
            .is_some_and(|surface| surface.placement == Placement::AtCursor);
        if at_cursor && now < *self.unfocused_since.get_or_insert(now) + PLACEMENT_SETTLE {
            return Some(Placement::AtCursor);
        }
        self.unfocused_since = None;
        self.layer_shell.is_some().then_some(Placement::Overlay)
    }

    fn place(
        &mut self,
        wayland: &mut Wayland,
        placement: Placement,
        focused: Option<&ZwpInputMethodV2>,
        content: &PanelContent,
        now: Instant,
    ) {
        if self
            .surface
            .as_ref()
            .is_some_and(|surface| surface.placement == placement)
        {
            return;
        }
        self.hide(wayland);
        self.last_id += 1;
        let id = self.last_id;
        let handle = &wayland.handle;
        let surface = self.compositor.create_surface(handle, id);
        let role = match (placement, focused, &self.layer_shell) {
            (Placement::AtCursor, Some(input_method), _) => {
                Role::Popup(input_method.get_input_popup_surface(&surface, handle, id))
            }
            (Placement::Overlay, _, Some(layer_shell)) => {
                let layer = layer_shell.get_layer_surface(
                    &surface,
                    None,
                    Layer::Overlay,
                    LAYER_NAMESPACE.to_owned(),
                    handle,
                    id,
                );
                // The size is the same at any scale.
                let rendered = self.render(content, 1.0, placement, now);
                layer.set_size(rendered.width, rendered.height);
                layer.set_anchor(Anchor::Bottom);
                layer.set_margin(0, 0, OVERLAY_MARGIN, 0);
                layer.set_keyboard_interactivity(KeyboardInteractivity::None);
                Role::Layer(layer)
            }
            // `placement` only asks for what this desktop has.
            _ => {
                surface.destroy();
                return;
            }
        };
        let viewport = self
            .viewporter
            .as_ref()
            .map(|viewporter| viewporter.get_viewport(&surface, handle, ()));
        let fractional = self
            .fractional_scale
            .as_ref()
            .filter(|_| viewport.is_some())
            .map(|manager| manager.get_fractional_scale(&surface, handle, id));
        let ready = match role {
            Role::Popup(_) => true,
            Role::Layer(_) => {
                // An overlay's first commit, without a buffer, asks for its configure.
                surface.commit();
                false
            }
        };
        let state = &mut wayland.state.panel;
        state.surface = Some((id, surface.clone()));
        state.configure = None;
        state.frame_done = true;
        state.pointer_at = None;
        self.surface = Some(Surface {
            id,
            placement,
            surface,
            role,
            viewport,
            fractional,
            size: None,
            input_region: None,
            ready,
        });
        self.dirty = true;
        tracing::debug!("The dictation panel is now {placement:?}");
    }

    fn draw_if_due(&mut self, wayland: &mut Wayland, content: &PanelContent, now: Instant) {
        let state = &mut wayland.state.panel;
        if let Some(serial) = state.configure.take()
            && let Some(surface) = &mut self.surface
            && let Role::Layer(layer) = &surface.role
        {
            layer.ack_configure(serial);
            surface.ready = true;
            self.dirty = true;
        }
        if std::mem::take(&mut state.rescaled) {
            self.dirty = true;
        }
        if !self.surface.as_ref().is_some_and(|surface| surface.ready) {
            return;
        }
        let frame_due = content.is_animated()
            && state.frame_done
            && self.last_frame.is_none_or(|last| now >= last + FRAME_INTERVAL);
        if self.dirty || frame_due {
            self.draw(wayland, content, now);
        }
    }

    fn draw(&mut self, wayland: &mut Wayland, content: &PanelContent, now: Instant) {
        let Some((placement, has_viewport)) = self
            .surface
            .as_ref()
            .map(|surface| (surface.placement, surface.viewport.is_some()))
        else {
            return;
        };
        let scale = wayland.state.panel.scale(has_viewport);
        let rendered = self.render(content, scale, placement, now);
        let (pixel_width, pixel_height) = (rendered.pixmap.width(), rendered.pixmap.height());
        let buffer = match self.buffers.fill(
            &self.shm,
            &wayland.handle,
            pixel_width,
            pixel_height,
            &rendered.argb8888(),
        ) {
            Ok(Some(buffer)) => buffer,
            // The compositor still holds every buffer; one it lets go brings another turn.
            Ok(None) => return,
            Err(error) => {
                tracing::warn!("Couldn't draw the dictation panel: {error}");
                return;
            }
        };
        let Some(surface) = &mut self.surface else {
            return;
        };
        let size = (rendered.width, rendered.height);
        if surface.size != Some(size) {
            if let Role::Layer(layer) = &surface.role {
                layer.set_size(size.0, size.1);
            }
            if let Some(viewport) = &surface.viewport {
                viewport.set_destination(logical(size.0), logical(size.1));
            }
            surface.size = Some(size);
        }
        if surface.viewport.is_none() {
            // Drawn at the whole scale, which divides the buffer's size.
            surface.surface.set_buffer_scale(scale as i32);
        }
        let cancel = rendered.cancel.map(|area| {
            [
                area.left().floor() as i32,
                area.top().floor() as i32,
                area.width().ceil() as i32,
                area.height().ceil() as i32,
            ]
        });
        if surface.input_region != Some(cancel) {
            let region = self.compositor.create_region(&wayland.handle, ());
            if let Some([x, y, width, height]) = cancel {
                region.add(x, y, width, height);
            }
            surface.surface.set_input_region(Some(&region));
            region.destroy();
            surface.input_region = Some(cancel);
        }
        surface.surface.attach(Some(&buffer), 0, 0);
        surface.surface.damage_buffer(0, 0, i32::MAX, i32::MAX);
        surface.surface.frame(&wayland.handle, surface.id);
        surface.surface.commit();
        wayland.state.panel.frame_done = false;
        self.cancel = rendered
            .cancel
            .map(|area| [area.left(), area.top(), area.right(), area.bottom()]);
        self.dirty = false;
        self.last_frame = Some(now);
    }

    fn render(&self, content: &PanelContent, scale: f32, placement: Placement, now: Instant) -> Rendered {
        let margins = match placement {
            Placement::AtCursor => Margins {
                top: CURSOR_GAP,
                bottom: CURSOR_GAP,
            },
            Placement::Overlay => Margins::default(),
        };
        let level = match content {
            PanelContent::Listening { .. } => (self.level)(),
            _ => 0.0,
        };
        let spin = (now.duration_since(self.started).as_secs_f32() / SPIN_PERIOD.as_secs_f32()).fract();
        self.view
            .render(content, Animation { level, spin }, scale, self.theme, margins)
    }

    fn hide(&mut self, wayland: &mut Wayland) {
        if let Some(surface) = self.surface.take() {
            surface.destroy();
            let state = &mut wayland.state.panel;
            state.surface = None;
            state.configure = None;
            state.pointer_at = None;
            state.frame_done = true;
            self.cancel = None;
            self.last_frame = None;
            self.dirty = true;
        }
        self.unfocused_since = None;
    }

    /// Takes the seat's pointer once it has one, and gives it an arrow over the panel.
    fn follow_pointer(&mut self, wayland: &mut Wayland) {
        let state = &mut wayland.state.panel;
        if self.pointer.is_none() && state.pointer_capable {
            let pointer = self.seat.get_pointer(&wayland.handle, ());
            let shape = self
                .cursor_shape
                .as_ref()
                .map(|manager| manager.get_pointer(&pointer, &wayland.handle, ()));
            self.pointer = Some((pointer, shape));
        }
        if let Some(serial) = state.entered.take()
            && let Some((_, Some(shape))) = &self.pointer
        {
            shape.set_shape(serial, Shape::Default);
        }
    }

    /// Whether the × was clicked since the last turn.
    fn take_clicks(&self, wayland: &mut Wayland) -> bool {
        let clicks = std::mem::take(&mut wayland.state.panel.clicks);
        clicks.into_iter().any(|(x, y)| {
            let (x, y) = (x as f32, y as f32);
            self.cancel
                .is_some_and(|[left, top, right, bottom]| x >= left && x <= right && y >= top && y <= bottom)
        })
    }
}

fn logical(length: u32) -> i32 {
    i32::try_from(length).unwrap_or(i32::MAX)
}

delegate_noop!(State: WlCompositor);
delegate_noop!(State: WlRegion);
delegate_noop!(State: ZwlrLayerShellV1);
delegate_noop!(State: WpViewporter);
delegate_noop!(State: WpViewport);
delegate_noop!(State: WpFractionalScaleManagerV1);
delegate_noop!(State: WpCursorShapeManagerV1);
delegate_noop!(State: WpCursorShapeDeviceV1);

impl Dispatch<WlSeat, ()> for State {
    fn event(state: &mut Self, _: &WlSeat, event: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wl_seat::Event::Capabilities {
            capabilities: WEnum::Value(capabilities),
        } = event
        {
            state.panel.pointer_capable = capabilities.contains(Capability::Pointer);
        }
    }
}

impl Dispatch<WlSurface, u64> for State {
    fn event(
        state: &mut Self,
        _: &WlSurface,
        event: wl_surface::Event,
        id: &u64,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let panel = &mut state.panel;
        if let wl_surface::Event::PreferredBufferScale { factor } = event
            && panel.is_current(*id)
            && panel.buffer_scale != Some(factor)
        {
            panel.buffer_scale = Some(factor);
            panel.rescaled = true;
        }
    }
}

impl Dispatch<WpFractionalScaleV1, u64> for State {
    fn event(
        state: &mut Self,
        _: &WpFractionalScaleV1,
        event: wp_fractional_scale_v1::Event,
        id: &u64,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let panel = &mut state.panel;
        if let wp_fractional_scale_v1::Event::PreferredScale { scale } = event
            && panel.is_current(*id)
            && panel.scale_120 != Some(scale)
        {
            panel.scale_120 = Some(scale);
            panel.rescaled = true;
        }
    }
}

impl Dispatch<WlCallback, u64> for State {
    fn event(
        state: &mut Self,
        _: &WlCallback,
        event: wl_callback::Event,
        id: &u64,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_callback::Event::Done { .. } = event
            && state.panel.is_current(*id)
        {
            state.panel.frame_done = true;
        }
    }
}

impl Dispatch<ZwlrLayerSurfaceV1, u64> for State {
    fn event(
        state: &mut Self,
        _: &ZwlrLayerSurfaceV1,
        event: zwlr_layer_surface_v1::Event,
        id: &u64,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let panel = &mut state.panel;
        if !panel.is_current(*id) {
            return;
        }
        match event {
            zwlr_layer_surface_v1::Event::Configure { serial, .. } => panel.configure = Some(serial),
            zwlr_layer_surface_v1::Event::Closed => panel.closed = true,
            _ => {}
        }
    }
}

impl Dispatch<ZwpInputPopupSurfaceV2, u64> for State {
    fn event(
        _: &mut Self,
        _: &ZwpInputPopupSurfaceV2,
        event: zwp_input_popup_surface_v2::Event,
        _: &u64,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zwp_input_popup_surface_v2::Event::TextInputRectangle { x, y, width, height } = event {
            tracing::debug!("The text cursor is at {x}, {y}, {width} × {height}");
        }
    }
}

impl Dispatch<WlPointer, ()> for State {
    fn event(state: &mut Self, _: &WlPointer, event: wl_pointer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        let panel = &mut state.panel;
        match event {
            wl_pointer::Event::Enter {
                serial,
                surface,
                surface_x,
                surface_y,
            } => {
                if panel.surface.as_ref().is_some_and(|(_, current)| *current == surface) {
                    panel.pointer_at = Some((surface_x, surface_y));
                    panel.entered = Some(serial);
                }
            }
            wl_pointer::Event::Leave { .. } => panel.pointer_at = None,
            wl_pointer::Event::Motion {
                surface_x, surface_y, ..
            } => {
                if panel.pointer_at.is_some() {
                    panel.pointer_at = Some((surface_x, surface_y));
                }
            }
            wl_pointer::Event::Button {
                button,
                state: WEnum::Value(ButtonState::Pressed),
                ..
            } if button == BTN_LEFT => {
                if let Some(at) = panel.pointer_at {
                    panel.clicks.push(at);
                }
            }
            _ => {}
        }
    }
}
