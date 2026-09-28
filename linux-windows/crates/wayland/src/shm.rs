//! The panel's pixels in shared memory (wl_shm, ARGB8888). Each buffer is a memory file the
//! compositor maps; the session writes it with positioned writes rather than mapping it too, and
//! reuses it once the compositor releases it.

use std::fs::File;
use std::os::fd::AsFd;
use std::os::unix::fs::FileExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use rustix::fs::{MemfdFlags, memfd_create};
use wayland_client::protocol::wl_buffer::{self, WlBuffer};
use wayland_client::protocol::wl_shm::{Format, WlShm};
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::{Connection, Dispatch, QueueHandle, delegate_noop};

use crate::event_loop::State;

/// One on screen, one waiting to be, and one being drawn.
const MAX_BUFFERS: usize = 3;

struct Slot {
    file: File,
    pool: WlShmPool,
    buffer: WlBuffer,
    width: u32,
    height: u32,
    /// The compositor holds it until it says it has let it go.
    busy: Arc<AtomicBool>,
}

impl Slot {
    fn new(shm: &WlShm, handle: &QueueHandle<State>, width: u32, height: u32) -> std::io::Result<Self> {
        let too_large = || std::io::Error::other("the panel is too large for a buffer");
        let stride = width.checked_mul(4).ok_or_else(too_large)?;
        let size = stride.checked_mul(height).ok_or_else(too_large)?;
        let file = File::from(memfd_create("live-transcribe-panel", MemfdFlags::CLOEXEC)?);
        file.set_len(u64::from(size))?;
        let pool = shm.create_pool(file.as_fd(), i32::try_from(size).map_err(|_| too_large())?, handle, ());
        let busy = Arc::new(AtomicBool::new(false));
        let buffer = pool.create_buffer(
            0,
            i32::try_from(width).map_err(|_| too_large())?,
            i32::try_from(height).map_err(|_| too_large())?,
            i32::try_from(stride).map_err(|_| too_large())?,
            Format::Argb8888,
            handle,
            Arc::clone(&busy),
        );
        Ok(Self {
            file,
            pool,
            buffer,
            width,
            height,
            busy,
        })
    }

    fn is_busy(&self) -> bool {
        self.busy.load(Ordering::Acquire)
    }

    fn destroy(self) {
        self.buffer.destroy();
        self.pool.destroy();
    }
}

#[derive(Default)]
pub(crate) struct Buffers {
    slots: Vec<Slot>,
}

impl Buffers {
    /// A buffer `width` by `height` holding `pixels` (ARGB8888, rows packed), in use from now
    /// until the compositor releases it. `None` while every buffer is still in use.
    pub(crate) fn fill(
        &mut self,
        shm: &WlShm,
        handle: &QueueHandle<State>,
        width: u32,
        height: u32,
        pixels: &[u8],
    ) -> std::io::Result<Option<WlBuffer>> {
        // Buffers of another size are no more use once the compositor has let them go.
        let (keep, stale): (Vec<Slot>, Vec<Slot>) = self
            .slots
            .drain(..)
            .partition(|slot| (slot.width, slot.height) == (width, height) || slot.is_busy());
        stale.into_iter().for_each(Slot::destroy);
        self.slots = keep;

        let free = self
            .slots
            .iter()
            .position(|slot| (slot.width, slot.height) == (width, height) && !slot.is_busy());
        let index = match free {
            Some(index) => index,
            None if self.slots.len() < MAX_BUFFERS => {
                self.slots.push(Slot::new(shm, handle, width, height)?);
                self.slots.len() - 1
            }
            None => return Ok(None),
        };
        let slot = &self.slots[index];
        slot.file.write_all_at(pixels, 0)?;
        slot.busy.store(true, Ordering::Release);
        Ok(Some(slot.buffer.clone()))
    }
}

delegate_noop!(State: WlShmPool);
delegate_noop!(State: ignore WlShm);

impl Dispatch<WlBuffer, Arc<AtomicBool>> for State {
    fn event(
        _: &mut Self,
        _: &WlBuffer,
        event: wl_buffer::Event,
        busy: &Arc<AtomicBool>,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_buffer::Event::Release = event {
            busy.store(false, Ordering::Release);
        }
    }
}
