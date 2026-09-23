import MLX
import Shared

/// Process-wide MLX configuration, applied once at startup.
public enum MLXRuntime {
    /// Bounds the Metal buffer cache. STT and the LLM share unified memory, so an unbounded
    /// cache grows with every distinct tensor shape.
    public static func configure(gpuCacheLimitMB: Int) {
        Memory.cacheLimit = max(0, gpuCacheLimitMB) * 1_024 * 1_024
        Log.app.info("MLX buffer cache limit: \(gpuCacheLimitMB) MB")
    }
}
