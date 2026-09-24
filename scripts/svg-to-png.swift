// Renders an SVG to a PNG with WebKit, the engine Safari uses, so the PNG matches what the
// website shows. The PNG is exactly the size asked for, in sRGB, with transparency kept.
//
// Usage: svg-to-png <input.svg> <output.png> <width> [<height>]
//
// Used by render-icons.sh, which compiles it. WebKit draws at the screen's scale and the result
// is scaled down to the size asked for, which smooths the edges (see `Bitmap.scaled`).
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

struct RenderError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class SVGRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let width: Int
    private let height: Int
    private let output: URL

    init(width: Int, height: Int, output: URL) {
        self.width = width
        self.height = height
        self.output = output
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        super.init()
        // Keeps the SVG's transparent areas transparent instead of white.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
    }

    func render(svg: String) {
        // Inlined rather than loaded as an image, so it has fully drawn when loading finishes.
        let markup = svg.replacingOccurrences(of: #"<\?xml[^>]*\?>"#, with: "", options: .regularExpression)
        let html = """
            <!doctype html><html><head><style>
            html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
            svg { display: block; width: \(width)px; height: \(height)px; }
            </style></head><body>\(markup)</body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { snapshot() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    private func snapshot() {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width, height: height)
        webView.takeSnapshot(with: configuration) { [self] image, error in
            guard let image else {
                finish(.failure(error ?? RenderError(description: "WebKit returned no snapshot")))
                return
            }
            finish(Result { try write(image) })
        }
    }

    /// Scales `image` to `width` × `height` and writes it as a PNG.
    private func write(_ image: NSImage) throws {
        guard let snapshot = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderError(description: "WebKit's snapshot has no bitmap")
        }
        let bitmap = try Bitmap.scaled(snapshot, width: width, height: height)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError(description: "Couldn't create \(output.path)") }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError(description: "Couldn't write \(output.path)")
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            exit(0)
        case .failure(let error):
            FileHandle.standardError.write(Data("svg-to-png: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// sRGB bitmaps, 8 bits a channel with premultiplied alpha.
enum Bitmap {
    /// `image` at `width` × `height`.
    ///
    /// WebKit draws at the screen's scale, so a snapshot is usually a whole multiple of the size
    /// asked for. Each pixel is then the average of the block of snapshot pixels it covers, which
    /// keeps an edge on the pixel grid sharp: Core Graphics' scaling spreads it into the next
    /// pixel, which blurs the 16-pixel icon. A snapshot of any other size is scaled by Core
    /// Graphics.
    static func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let factor = image.width / width
        guard factor >= 1, image.width == width * factor, image.height == height * factor else {
            let context = try context(width: width, height: height)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return try makeImage(context)
        }
        let source = try context(width: image.width, height: image.height)
        source.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let result = try context(width: width, height: height)
        guard let input = source.data?.assumingMemoryBound(to: UInt8.self),
              let output = result.data?.assumingMemoryBound(to: UInt8.self)
        else { throw RenderError(description: "Couldn't read a bitmap's pixels") }
        let area = factor * factor
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<4 {
                    var sum = 0
                    for row in 0..<factor {
                        let start = input + (y * factor + row) * source.bytesPerRow + x * factor * 4 + channel
                        for column in 0..<factor {
                            sum += Int(start[column * 4])
                        }
                    }
                    output[y * result.bytesPerRow + x * 4 + channel] = UInt8((sum + area / 2) / area)
                }
            }
        }
        return try makeImage(result)
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw RenderError(description: "Couldn't create a \(width)×\(height) bitmap") }
        return context
    }

    private static func makeImage(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw RenderError(description: "Couldn't make an image of a \(context.width)×\(context.height) bitmap")
        }
        return image
    }
}

let arguments = CommandLine.arguments
guard (4...5).contains(arguments.count),
      let width = Int(arguments[3]), width > 0,
      let height = arguments.count == 5 ? Int(arguments[4]) : width, height > 0
else {
    FileHandle.standardError.write(Data("usage: svg-to-png <input.svg> <output.png> <width> [<height>]\n".utf8))
    exit(2)
}
let svg: String
do {
    svg = try String(contentsOfFile: arguments[1], encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("svg-to-png: can't read \(arguments[1]): \(error.localizedDescription)\n".utf8))
    exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    let renderer = SVGRenderer(width: width, height: height, output: URL(fileURLWithPath: arguments[2]))
    renderer.render(svg: svg)
    // WebKit reports nothing for some broken input, so give up rather than wait forever.
    Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
        FileHandle.standardError.write(Data("svg-to-png: timed out rendering \(arguments[1])\n".utf8))
        exit(1)
    }
    withExtendedLifetime(renderer) { application.run() }
}
