//! The dictation panel on Windows: a small window of the app's own that follows the mouse
//! pointer, its circle just below and to the right of it, as the Mac's HUD does. lt-dictation-ui
//! draws it and places it; this shows the pixels in a webview window (`ui/panel.html` paints each
//! frame on a canvas), moves the level and the spinner at 30 frames a second, and moves the window
//! with the pointer, within the work area of the screen the pointer is on.
//!
//! A window is made for each dictation and closed after it. It is shown without being activated
//! and can't be: it never takes the keyboard from the app being typed into. It takes no clicks
//! either: they go through to the window below. It stays out of the taskbar, above other windows.

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use lt_dictation_ui::{Animation, BubbleSide, Indicator, PanelContent, PanelPlacement, PanelView, Rendered, Theme};
use tauri::{AppHandle, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use super::Screen;
use crate::dictation::desktop::PanelConfiguration;

/// How often the panel follows the pointer.
const TICK: Duration = Duration::from_millis(16);
/// How often the level and the spinner move.
const FRAME_INTERVAL: Duration = Duration::from_millis(33);
/// One turn of the spinner.
const SPIN_PERIOD: Duration = Duration::from_secs(1);

enum Command {
    Attach(AppHandle, Screen),
    Show(Option<PanelContent>),
}

/// The panel's handle; its thread draws and moves it.
pub(super) struct Panel {
    commands: Sender<Command>,
}

impl Panel {
    pub(super) fn start(configuration: PanelConfiguration) -> Self {
        let (commands, received) = mpsc::channel();
        let spawned = thread::Builder::new()
            .name("panel".to_owned())
            .spawn(move || Drawer::new(configuration).run(&received));
        if let Err(error) = spawned {
            tracing::error!("The dictation panel couldn't start: {error}");
        }
        Self { commands }
    }

    /// The app's windows are up, so the panel can open its own from now on.
    pub(super) fn attach(&self, app: &AppHandle) {
        let screen = Screen::default();
        // The page asks for its frames through the app's state.
        app.manage(screen.clone());
        let _ = self.commands.send(Command::Attach(app.clone(), screen));
    }

    /// Shows the panel with `content`, or hides it.
    pub(super) fn show(&self, content: Option<PanelContent>) {
        let _ = self.commands.send(Command::Show(content));
    }
}

/// The panel's window, while it is open.
struct Shown {
    window: WebviewWindow,
    /// Where it was last put, and its size in pixels.
    at: Option<PhysicalPosition<i32>>,
    size: Option<PhysicalSize<u32>>,
    /// What the last frame was drawn for.
    drawn: Option<(BubbleSide, f64)>,
    last_frame: Option<Instant>,
    /// The content changed since the last frame.
    dirty: bool,
}

/// The work area of the screen the pointer is on, in its logical pixels, as the placement takes
/// it, and how to get back to the desktop's pixels.
struct Spot {
    pointer: (f32, f32),
    screen: (f32, f32),
    origin: PhysicalPosition<i32>,
    scale: f64,
}

impl Spot {
    fn physical(&self, placement: &PanelPlacement) -> PhysicalPosition<i32> {
        let pixels = |logical: f32| (f64::from(logical) * self.scale).round() as i32;
        PhysicalPosition::new(self.origin.x + pixels(placement.x), self.origin.y + pixels(placement.y))
    }
}

struct Drawer {
    view: PanelView,
    level: Box<dyn Fn() -> f32 + Send>,
    app: Option<(AppHandle, Screen)>,
    content: Option<PanelContent>,
    theme: Theme,
    shown: Option<Shown>,
    /// Windows made so far, for each one's label: a closing window keeps its label a moment.
    opened: u64,
    /// The window couldn't open for this content, and isn't tried again until the next.
    failed: bool,
    started: Instant,
}

impl Drawer {
    fn new(configuration: PanelConfiguration) -> Self {
        Self {
            view: configuration.view,
            level: configuration.level,
            app: None,
            content: None,
            theme: Theme::Dark,
            shown: None,
            opened: 0,
            failed: false,
            started: Instant::now(),
        }
    }

    fn run(mut self, commands: &Receiver<Command>) {
        loop {
            // Nothing moves while the panel is hidden.
            let command = if self.content.is_some() {
                commands.recv_timeout(TICK)
            } else {
                commands.recv().map_err(|_| RecvTimeoutError::Disconnected)
            };
            match command {
                Ok(Command::Attach(app, screen)) => self.app = Some((app, screen)),
                Ok(Command::Show(content)) => self.show(content),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.hide();
                    return;
                }
            }
            self.update(Instant::now());
        }
    }

    fn show(&mut self, content: Option<PanelContent>) {
        if content == self.content {
            return;
        }
        if self.content.is_none() && content.is_some() {
            // It follows the apps' light or dark mode as it appears.
            self.theme = Theme::detect();
            self.failed = false;
        }
        self.content = content;
        if let Some(shown) = &mut self.shown {
            shown.dirty = true;
        }
    }

    /// Brings the screen up to date: the panel where it belongs, drawn when due.
    fn update(&mut self, now: Instant) {
        let Some(content) = self.content.clone() else {
            return self.hide();
        };
        let Some((app, screen)) = self.app.clone() else {
            return;
        };
        if self.failed {
            return;
        }
        let Some(spot) = spot(&app) else {
            return;
        };
        let (width, height) = self.view.size(&content);
        let placement = PanelPlacement::beside(spot.pointer, (width as f32, height as f32), spot.screen);
        let position = spot.physical(&placement);
        if self.shown.is_none() {
            match self.open(&app, position) {
                Ok(window) => {
                    self.shown = Some(Shown {
                        window,
                        at: None,
                        size: None,
                        drawn: None,
                        last_frame: None,
                        dirty: true,
                    });
                }
                Err(error) => {
                    tracing::warn!("The dictation panel couldn't open: {error}");
                    self.failed = true;
                    return;
                }
            }
        }
        let Some(shown) = &mut self.shown else {
            return;
        };
        let frame_due = content.is_animated() && shown.last_frame.is_none_or(|last| now >= last + FRAME_INTERVAL);
        if shown.dirty || frame_due || shown.drawn != Some((placement.side, spot.scale)) {
            let level = match content.indicator {
                Indicator::Level { .. } => (self.level)(),
                _ => 0.0,
            };
            let spin = (now.duration_since(self.started).as_secs_f32() / SPIN_PERIOD.as_secs_f32()).fract();
            let rendered = self.view.render(
                &content,
                Animation { level, spin },
                spot.scale as f32,
                self.theme,
                placement.side,
            );
            let pixels = PhysicalSize::new(rendered.pixmap.width(), rendered.pixmap.height());
            if shown.size != Some(pixels) {
                report(shown.window.set_size(pixels));
                shown.size = Some(pixels);
            }
            // Until the page has asked for frames, the frame is drawn again at the next tick.
            if screen.send(frame(&rendered)) {
                shown.dirty = false;
                shown.drawn = Some((placement.side, spot.scale));
                shown.last_frame = Some(now);
            }
        }
        if shown.at != Some(position) {
            report(shown.window.set_position(position));
            shown.at = Some(position);
        }
    }

    /// Opens the panel's window at `position`, shown but not activated.
    fn open(&mut self, app: &AppHandle, position: PhysicalPosition<i32>) -> tauri::Result<WebviewWindow> {
        self.opened += 1;
        let label = format!("panel-{}", self.opened);
        let window = WebviewWindowBuilder::new(app, label, WebviewUrl::App("panel.html".into()))
            .title("Live Transcribe dictation")
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .focused(false)
            .focusable(false)
            .visible(true)
            .inner_size(1.0, 1.0)
            .build()?;
        window.set_position(position)?;
        window.set_ignore_cursor_events(true)?;
        Ok(window)
    }

    fn hide(&mut self) {
        let Some(shown) = self.shown.take() else {
            return;
        };
        if let Some((_, screen)) = &self.app {
            screen.disconnect();
        }
        report(shown.window.destroy());
    }
}

/// Where the pointer is, on which screen's work area.
fn spot(app: &AppHandle) -> Option<Spot> {
    let pointer = app.cursor_position().ok()?;
    let monitor = app
        .monitor_from_point(pointer.x, pointer.y)
        .ok()
        .flatten()
        .or_else(|| app.primary_monitor().ok().flatten())?;
    let area = monitor.work_area();
    let scale = monitor.scale_factor();
    let logical = |length: f64| (length / scale) as f32;
    Some(Spot {
        pointer: (
            logical(pointer.x - f64::from(area.position.x)),
            logical(pointer.y - f64::from(area.position.y)),
        ),
        screen: (
            logical(f64::from(area.size.width)),
            logical(f64::from(area.size.height)),
        ),
        origin: area.position,
        scale,
    })
}

/// A drawn panel as the page takes it: its width and height in pixels (little-endian), then its
/// pixels, R, G, B, A.
fn frame(rendered: &Rendered) -> Vec<u8> {
    let (width, height) = (rendered.pixmap.width(), rendered.pixmap.height());
    let pixels = rendered.rgba8888();
    let mut frame = Vec::with_capacity(8 + pixels.len());
    frame.extend(width.to_le_bytes());
    frame.extend(height.to_le_bytes());
    frame.extend(pixels);
    frame
}

fn report(result: tauri::Result<()>) {
    if let Err(error) = result {
        tracing::warn!("Couldn't move the dictation panel: {error}");
    }
}

#[cfg(test)]
mod tests {
    use lt_dictation_ui::load_interface_font;

    use super::*;

    #[test]
    fn a_frame_is_its_size_in_pixels_then_its_pixels() {
        let view = PanelView::new(load_interface_font().expect("Segoe UI, or another sans-serif font"));
        let content = PanelContent {
            indicator: Indicator::Spinner,
            message: None,
        };
        let rendered = view.render(&content, Animation::default(), 1.5, Theme::Dark, BubbleSide::Trailing);
        let (width, height) = (rendered.pixmap.width(), rendered.pixmap.height());
        let frame = frame(&rendered);
        assert_eq!(frame[..4], width.to_le_bytes());
        assert_eq!(frame[4..8], height.to_le_bytes());
        assert_eq!(frame.len(), 8 + (width * height * 4) as usize);
    }
}
