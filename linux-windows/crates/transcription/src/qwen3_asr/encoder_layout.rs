use std::ops::Range;

/// Mel frames the encoder's convolutions take at a time (`n_window` × 2).
pub const CHUNK_FRAMES: usize = 100;
/// Chunks whose rows attend to each other (`n_window_infer` / [`CHUNK_FRAMES`]).
pub const CHUNKS_PER_WINDOW: usize = 8;

/// How mlx-audio-swift's Qwen3-ASR encodes one clip, and how many placeholders its prompt gives
/// the clip.
///
/// - The clip's mel frames are cut into chunks of [`CHUNK_FRAMES`], the last one shorter, and
///   every chunk is zero-padded to the longest; three 3×3 convolutions of stride 2 make 13 rows of
///   a full chunk.
/// - Of each chunk's rows the encoder keeps as many as [`placeholders`] counts for the chunk's
///   frames, at most all of them. For a short last chunk padded to 100 frames that count takes in
///   some rows computed over the padding, as mlx-audio-swift does.
/// - The kept rows attend to each other in windows of [`CHUNKS_PER_WINDOW`] chunks.
/// - The prompt gets [`placeholders`] of the clip's frames, and the kept rows replace them from
///   the first. The count can be a few more than the rows; the rest keep the placeholder token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncoderLayout {
    frames: usize,
    chunk_lengths: Vec<usize>,
    padded_length: usize,
    convolved_length: usize,
    chunk_rows: Vec<usize>,
    windows: Vec<Range<usize>>,
}

impl EncoderLayout {
    pub fn new(frames: usize) -> Self {
        assert!(frames > 0, "a clip has at least one frame");
        let chunk_lengths: Vec<usize> = (0..frames)
            .step_by(CHUNK_FRAMES)
            .map(|start| CHUNK_FRAMES.min(frames - start))
            .collect();
        let padded_length = chunk_lengths[0];
        let convolved_length = convolved(convolved(convolved(padded_length)));
        let chunk_rows: Vec<usize> = chunk_lengths
            .iter()
            .map(|&length| convolved_length.min(placeholders(length)))
            .collect();
        let mut windows = Vec::new();
        let mut row = 0;
        for rows in chunk_rows.chunks(CHUNKS_PER_WINDOW) {
            let count: usize = rows.iter().sum();
            windows.push(row..row + count);
            row += count;
        }
        Self {
            frames,
            chunk_lengths,
            padded_length,
            convolved_length,
            chunk_rows,
            windows,
        }
    }

    pub fn frames(&self) -> usize {
        self.frames
    }

    /// Frames in each chunk, in order: all [`CHUNK_FRAMES`] but the last.
    pub fn chunk_lengths(&self) -> &[usize] {
        &self.chunk_lengths
    }

    /// The length every chunk is zero-padded to: the longest chunk's.
    pub fn padded_length(&self) -> usize {
        self.padded_length
    }

    /// Rows the convolutions make of a padded chunk.
    pub fn convolved_length(&self) -> usize {
        self.convolved_length
    }

    /// Rows the encoder keeps of each chunk, from its first.
    pub fn chunk_rows(&self) -> &[usize] {
        &self.chunk_rows
    }

    /// The attention windows, as ranges of the kept rows (every chunk's, one after another).
    pub fn windows(&self) -> &[Range<usize>] {
        &self.windows
    }

    /// Rows the encoder makes of the clip.
    pub fn rows(&self) -> usize {
        self.chunk_rows.iter().sum()
    }

    /// The placeholders the prompt gives the clip.
    pub fn placeholders(&self) -> usize {
        placeholders(self.frames)
    }
}

/// The `<|audio_pad|>` placeholders mlx-audio-swift's prompt gives `frames` mel frames, and the
/// rows its encoder keeps of a chunk of that many (`getFeatExtractOutputLengths`).
///
/// Qwen's processor adds (frames / 100) × 13 in integers. mlx-audio-swift divides a whole-number
/// array by 100, which MLX does in float32, so the fraction of the last 100 frames counts too, and
/// the sum is truncated: 541 frames get 76 placeholders, where Qwen's count is 71. The Sinhala
/// model was trained on this count, so it is copied, float32 steps and truncation included.
pub fn placeholders(frames: usize) -> usize {
    let leave = (frames % CHUNK_FRAMES) as i64;
    let after_first = (leave - 1).div_euclid(2) + 1;
    let after_third = ((after_first - 1).div_euclid(2) + 1 - 1).div_euclid(2) + 1;
    (after_third as f32 + frames as f32 / 100.0 * 13.0) as usize
}

/// Rows a 3×3 convolution with stride 2 and padding 1 makes of `length` rows.
fn convolved(length: usize) -> usize {
    (length - 1) / 2 + 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_placeholders_as_mlx_audio_swift_does() {
        // Qwen's own counts are 71, 77, 87 and 170.
        assert_eq!(placeholders(541), 76);
        assert_eq!(placeholders(591), 88);
        assert_eq!(placeholders(671), 96);
        assert_eq!(placeholders(1_303), 170);
        assert_eq!(placeholders(100), 13);
        assert_eq!(placeholders(1), 1);
    }

    #[test]
    fn keeps_rows_computed_over_the_padding_of_a_short_last_chunk() {
        let layout = EncoderLayout::new(591);
        assert_eq!(layout.chunk_lengths(), [100, 100, 100, 100, 100, 91]);
        assert_eq!(layout.padded_length(), 100);
        assert_eq!(layout.convolved_length(), 13);
        // A 91-frame chunk convolves to 12 rows, but its count is 23, so all 13 of the padded
        // chunk's rows are kept.
        assert_eq!(layout.chunk_rows(), [13, 13, 13, 13, 13, 13]);
        assert_eq!(layout.rows(), 78);
        assert_eq!(layout.placeholders(), 88);
        assert_eq!(layout.windows(), std::slice::from_ref(&(0..78)));
    }

    #[test]
    fn a_single_chunk_is_padded_to_its_own_length() {
        let layout = EncoderLayout::new(41);
        assert_eq!(layout.padded_length(), 41);
        assert_eq!(layout.convolved_length(), 6);
        assert_eq!(layout.chunk_rows(), [6]);
    }

    #[test]
    fn windows_hold_eight_chunks() {
        let layout = EncoderLayout::new(1_000);
        assert_eq!(layout.chunk_rows().len(), 10);
        assert_eq!(layout.windows(), [0..104, 104..130]);
        assert_eq!(layout.rows(), 130);
    }
}
