//! The dictation panel on screen: an overlay (wlr-layer-shell) that follows the mouse pointer, its
//! circle just below and to the right of it, as the Mac's HUD does. [`PointerTracker`] says where
//! the pointer is; where the compositor can't say, the panel sits at the bottom of the screen,
//! clear of the dock.
//!
//! lt-dictation-ui draws it and places it; this puts the pixels in shared memory at the screen's
//! scale, moves the level and the spinner at 30 frames a second, and moves the panel with the
//! pointer as often as the compositor draws, each paced by the compositor's frame callbacks. The
//! panel never takes the keyboard, and takes no clicks: they go through to the window below.

use std::time::{Duration, Instant};

use lt_dictation_ui::{Animation, BubbleSide, Indicator, PanelContent, PanelPlacement, PanelView, Rendered, Theme};
use wayland_client::globals::GlobalList;
use wayland_client::protocol::wl_callback::{self, WlCallback};
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_region::WlRegion;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::protocol::wl_shm::WlShm;
use wayland_client::protocol::wl_surface::{self, WlSurface};
use wayland_client::{Connection, Dispatch, QueueHandle, delegate_noop};
use wayland_protocols::wp::fractional_scale::v1::client::wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1;
use wayland_protocols::wp::fractional_scale::v1::client::wp_fractional_scale_v1::{self, WpFractionalScaleV1};
use wayland_protocols::wp::viewporter::client::wp_viewport::WpViewport;
use wayland_protocols::wp::viewporter::client::wp_viewporter::WpViewporter;
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1};
use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::{
    self, Anchor, KeyboardInteractivity, ZwlrLayerSurfaceV1,
};

use crate::event_loop::{State, Wayland};
use crate::pointer::PointerTracker;
use crate::session::PanelConfiguration;
use crate::shm::Buffers;

/// How often the level and the spinner move.
const FRAME_INTERVAL: Duration = Duration::from_millis(33);
/// One turn of the spinner.
const SPIN_PERIOD: Duration = Duration::from_secs(1);
/// Above the bottom of the screen and clear of the dock, where the pointer can't be followed.
const BOTTOM_MARGIN: i32 = 60;
/// How long the panel waits to hear where the pointer is before it shows at the bottom of the
/// screen instead. Cursor sessions say at once.
const POINTER_WAIT: Duration = Duration::from_millis(150);
const LAYER_NAMESPACE: &str = "live-transcribe-panel";

/// Where the panel's surface is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Anchoring {
    /// By the pointer, on the output with this global name. A surface stays on its output, so
    /// the panel gets a new one when the pointer moves to another.
    Pointer { output: u32 },
    /// At the bottom of the screen the compositor chooses.
    Bottom,
}

struct Surface {
    id: u64,
    anchoring: Anchoring,
    surface: WlSurface,
    layer: ZwlrLayerSurfaceV1,
    viewport: Option<WpViewport>,
    fractional: Option<WpFractionalScaleV1>,
    /// The size last given, in logical pixels.
    size: Option<(u32, u32)>,
    /// By the pointer: the margins last given (left, top), and the side the bubble is drawn on.
    at: Option<(i32, i32)>,
    side: BubbleSide,
    /// It shows nothing until its first configure is acknowledged.
    ready: bool,
}

impl Surface {
    fn destroy(self) {
        // The role and the extensions go before the surface they belong to.
        self.layer.destroy();
        if let Some(viewport) = self.viewport {
            viewport.destroy();
        }
        if let Some(fractional) = self.fractional {
            fractional.destroy();
        }
        self.surface.destroy();
    }
}

/// What the compositor has said about the panel's surface.
#[derive(Default)]
pub(crate) struct PanelState {
    /// The surface on screen. Events carry their surface's id, and those for one gone are dropped.
    surface: Option<(u64, WlSurface)>,
    /// Its configure, to acknowledge.
    configure: Option<u32>,
    closed: bool,
    /// The compositor has shown the last frame, so the next can be drawn.
    frame_done: bool,
    /// The scale the compositor prefers: in 120ths (fractional-scale-v1), or whole.
    scale_120: Option<u32>,
    buffer_scale: Option<i32>,
    rescaled: bool,
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
    compositor: WlCompositor,
    shm: WlShm,
    layer_shell: ZwlrLayerShellV1,
    viewporter: Option<WpViewporter>,
    fractional_scale: Option<WpFractionalScaleManagerV1>,
    pointer: PointerTracker,
    buffers: Buffers,
    content: Option<PanelContent>,
    /// The content's size in logical pixels.
    size: (u32, u32),
    theme: Theme,
    surface: Option<Surface>,
    last_id: u64,
    /// The content, size or scale changed since the panel was last drawn.
    dirty: bool,
    last_frame: Option<Instant>,
    /// Since when the panel has waited to hear where the pointer is.
    waiting_since: Option<Instant>,
    /// The compositor closed the panel: it stays closed until the content changes.
    closed: bool,
    started: Instant,
}

impl Panel {
    /// The panel, if the compositor can show one (wlr-layer-shell).
    pub(crate) fn bind(
        globals: &GlobalList,
        seat: &WlSeat,
        wayland: &mut Wayland,
        configuration: PanelConfiguration,
    ) -> Option<Self> {
        let handle = &wayland.handle;
        let bound = globals
            .bind(handle, 4..=6, ())
            .and_then(|compositor| Ok((compositor, globals.bind(handle, 1..=1, ())?)))
            .and_then(|(compositor, shm)| Ok((compositor, shm, globals.bind(handle, 1..=4, ())?)));
        let (compositor, shm, layer_shell) = bound
            .inspect_err(|error| tracing::warn!("No dictation panel: {error}"))
            .ok()?;
        let viewporter = globals.bind(handle, 1..=1, ()).ok();
        let fractional_scale = globals.bind(handle, 1..=1, ()).ok();
        Some(Self {
            view: configuration.view,
            level: configuration.level,
            compositor,
            shm,
            layer_shell,
            viewporter,
            fractional_scale,
            pointer: PointerTracker::bind(globals, seat, wayland),
            buffers: Buffers::default(),
            content: None,
            size: (0, 0),
            theme: Theme::Dark,
            surface: None,
            last_id: 0,
            dirty: true,
            last_frame: None,
            waiting_since: None,
            closed: false,
            started: Instant::now(),
        })
    }

    /// The panel follows the pointer; otherwise it sits at the bottom of the screen.
    pub(crate) fn follows_pointer(&self) -> bool {
        self.pointer.can_follow()
    }

    pub(crate) fn show(&mut self, content: Option<PanelContent>) {
        if content == self.content {
            return;
        }
        if self.content.is_none() && content.is_some() {
            // It follows the desktop's light or dark mode as it appears.
            self.theme = Theme::detect();
        }
        if let Some(content) = &content {
            self.size = self.view.size(content);
        }
        self.content = content;
        self.dirty = true;
        self.closed = false;
    }

    /// Brings the screen up to date: the panel where it belongs, drawn and moved when due.
    pub(crate) fn update(&mut self, wayland: &mut Wayland, now: Instant) {
        self.pointer.update_outputs(wayland);
        if std::mem::take(&mut wayland.state.panel.closed) {
            tracing::info!("The compositor closed the dictation panel");
            self.hide(wayland);
            self.closed = true;
        }
        let content = match self.content.clone() {
            Some(content) if !self.closed => content,
            _ => {
                self.hide(wayland);
                self.pointer.stop(wayland);
                self.waiting_since = None;
                return;
            }
        };
        self.pointer.start(wayland);
        if let Some(anchoring) = self.anchoring(wayland, now) {
            self.place(wayland, anchoring);
            self.draw_if_due(wayland, &content, now);
        }
    }

    /// When the panel next needs the session: its next frame, or the end of the wait to hear where
    /// the pointer is. The pointer moving, and the compositor showing a frame, wake the session
    /// by themselves.
    pub(crate) fn deadline(&self, state: &PanelState) -> Option<Instant> {
        let animated = self.content.as_ref().is_some_and(PanelContent::is_animated)
            && self.surface.as_ref().is_some_and(|surface| surface.ready)
            && state.frame_done;
        let frame = animated.then(|| self.last_frame.map_or_else(Instant::now, |last| last + FRAME_INTERVAL));
        let waiting = self.waiting_since.map(|since| since + POINTER_WAIT);
        frame.into_iter().chain(waiting).min()
    }

    /// By the pointer, on the output it is on. At the bottom of the screen when the compositor
    /// can't say where it is, or doesn't say in time. `None` while waiting to hear.
    fn anchoring(&mut self, wayland: &Wayland, now: Instant) -> Option<Anchoring> {
        let pointer = &wayland.state.pointer;
        if let Some(at) = pointer.pointer() {
            self.waiting_since = None;
            return Some(Anchoring::Pointer { output: at.output });
        }
        if let Some(surface) = &self.surface {
            // Between outputs, or off them for a moment: it stays where it is, unless its output
            // has gone.
            return Some(match surface.anchoring {
                Anchoring::Pointer { output } if pointer.wl_output(output).is_none() => Anchoring::Bottom,
                anchoring => anchoring,
            });
        }
        if !self.pointer.can_follow() {
            return Some(Anchoring::Bottom);
        }
        let since = *self.waiting_since.get_or_insert(now);
        if now < since + POINTER_WAIT {
            return None;
        }
        self.waiting_since = None;
        tracing::debug!("No cursor session said where the pointer is, so the panel is at the bottom of the screen");
        Some(Anchoring::Bottom)
    }

    fn place(&mut self, wayland: &mut Wayland, anchoring: Anchoring) {
        if self
            .surface
            .as_ref()
            .is_some_and(|surface| surface.anchoring == anchoring)
        {
            return;
        }
        self.hide(wayland);
        self.last_id += 1;
        let id = self.last_id;
        let handle = &wayland.handle;
        let output = match anchoring {
            Anchoring::Pointer { output } => wayland.state.pointer.wl_output(output),
            Anchoring::Bottom => None,
        };
        let surface = self.compositor.create_surface(handle, id);
        let layer = self.layer_shell.get_layer_surface(
            &surface,
            output,
            Layer::Overlay,
            LAYER_NAMESPACE.to_owned(),
            handle,
            id,
        );
        // The size is the same at any scale.
        let (width, height) = self.size;
        layer.set_size(width, height);
        match anchoring {
            Anchoring::Pointer { .. } => {
                // Its margins are from the output's corner, whatever panels and docks claim.
                layer.set_anchor(Anchor::Top | Anchor::Left);
                layer.set_exclusive_zone(-1);
            }
            Anchoring::Bottom => {
                layer.set_anchor(Anchor::Bottom);
                layer.set_margin(0, 0, BOTTOM_MARGIN, 0);
            }
        }
        layer.set_keyboard_interactivity(KeyboardInteractivity::None);
        // An empty input region: clicks go through to the window below.
        let region = self.compositor.create_region(handle, ());
        surface.set_input_region(Some(&region));
        region.destroy();
        let viewport = self
            .viewporter
            .as_ref()
            .map(|viewporter| viewporter.get_viewport(&surface, handle, ()));
        let fractional = self
            .fractional_scale
            .as_ref()
            .filter(|_| viewport.is_some())
            .map(|manager| manager.get_fractional_scale(&surface, handle, id));
        // The first commit, without a buffer, asks for its configure.
        surface.commit();
        let state = &mut wayland.state.panel;
        state.surface = Some((id, surface.clone()));
        state.configure = None;
        state.frame_done = true;
        self.surface = Some(Surface {
            id,
            anchoring,
            surface,
            layer,
            viewport,
            fractional,
            size: Some((width, height)),
            at: None,
            side: BubbleSide::Trailing,
            ready: false,
        });
        self.dirty = true;
        tracing::debug!("The dictation panel is now {anchoring:?}");
    }

    fn draw_if_due(&mut self, wayland: &mut Wayland, content: &PanelContent, now: Instant) {
        let state = &mut wayland.state.panel;
        if let Some(serial) = state.configure.take()
            && let Some(surface) = &mut self.surface
        {
            surface.layer.ack_configure(serial);
            surface.ready = true;
            self.dirty = true;
        }
        if std::mem::take(&mut state.rescaled) {
            self.dirty = true;
        }
        let frame_done = state.frame_done;
        let Some(surface) = self.surface.as_ref().filter(|surface| surface.ready) else {
            return;
        };
        let placement = self.placement(wayland, surface.anchoring);
        let moved = placement.is_some_and(|(at, _)| surface.at != Some(at));
        if placement.is_some_and(|(_, side)| side != surface.side) {
            // The bubble changes sides.
            self.dirty = true;
        }
        let frame_due =
            content.is_animated() && frame_done && self.last_frame.is_none_or(|last| now >= last + FRAME_INTERVAL);
        if self.dirty || frame_due {
            self.draw(wayland, content, placement, now);
        } else if moved
            && frame_done
            && let Some((at, _)) = placement
        {
            self.move_to(wayland, at);
        }
    }

    /// By the pointer: the panel's margins from its output's corner, and the bubble's side.
    fn placement(&self, wayland: &Wayland, anchoring: Anchoring) -> Option<((i32, i32), BubbleSide)> {
        let Anchoring::Pointer { output } = anchoring else {
            return None;
        };
        let pointer = wayland.state.pointer.pointer_on(output)?;
        let (width, height) = self.size;
        let placement = PanelPlacement::beside((pointer.x, pointer.y), (width as f32, height as f32), pointer.screen);
        Some(((placement.x.round() as i32, placement.y.round() as i32), placement.side))
    }

    fn draw(
        &mut self,
        wayland: &mut Wayland,
        content: &PanelContent,
        placement: Option<((i32, i32), BubbleSide)>,
        now: Instant,
    ) {
        let Some((has_viewport, side)) = self.surface.as_ref().map(|surface| {
            (
                surface.viewport.is_some(),
                placement.map_or(surface.side, |(_, side)| side),
            )
        }) else {
            return;
        };
        let scale = wayland.state.panel.scale(has_viewport);
        let rendered = self.render(content, scale, side, now);
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
            surface.layer.set_size(size.0, size.1);
            surface.size = Some(size);
        }
        if let Some(viewport) = &surface.viewport {
            viewport.set_destination(logical(size.0), logical(size.1));
        } else {
            // Drawn at the whole scale, which divides the buffer's size.
            surface.surface.set_buffer_scale(scale as i32);
        }
        if let Some((at, _)) = placement
            && surface.at != Some(at)
        {
            surface.layer.set_margin(at.1, 0, 0, at.0);
            surface.at = Some(at);
        }
        surface.side = side;
        surface.surface.attach(Some(&buffer), 0, 0);
        surface.surface.damage_buffer(0, 0, i32::MAX, i32::MAX);
        surface.surface.frame(&wayland.handle, surface.id);
        surface.surface.commit();
        wayland.state.panel.frame_done = false;
        self.dirty = false;
        self.last_frame = Some(now);
    }

    /// Moves the panel without drawing it again.
    fn move_to(&mut self, wayland: &mut Wayland, at: (i32, i32)) {
        let Some(surface) = &mut self.surface else {
            return;
        };
        surface.layer.set_margin(at.1, 0, 0, at.0);
        surface.at = Some(at);
        surface.surface.frame(&wayland.handle, surface.id);
        surface.surface.commit();
        wayland.state.panel.frame_done = false;
    }

    fn render(&self, content: &PanelContent, scale: f32, side: BubbleSide, now: Instant) -> Rendered {
        let level = match content.indicator {
            Indicator::Level { .. } => (self.level)(),
            _ => 0.0,
        };
        let spin = (now.duration_since(self.started).as_secs_f32() / SPIN_PERIOD.as_secs_f32()).fract();
        self.view
            .render(content, Animation { level, spin }, scale, self.theme, side)
    }

    fn hide(&mut self, wayland: &mut Wayland) {
        if let Some(surface) = self.surface.take() {
            surface.destroy();
            let state = &mut wayland.state.panel;
            state.surface = None;
            state.configure = None;
            state.frame_done = true;
            self.last_frame = None;
            self.dirty = true;
        }
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
