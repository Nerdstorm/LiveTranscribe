import SwiftUI

/// The scrolling transcript. Partials are secondary; cleaned text replaces raw text in place.
struct TranscriptList: View {
    let lines: [TranscriptLine]
    let isListening: Bool

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                isListening ? "Listening…" : "No transcript yet",
                systemImage: isListening ? "waveform" : "text.bubble",
                description: Text(isListening ? "Start speaking." : "Press Start Transcribing and speak.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(lines) { line in
                            LineRow(line: line).id(line.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: lines) { _, newLines in
                    guard let last = newLines.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct LineRow: View {
    let line: TranscriptLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Text that can still change (a partial, or raw text awaiting cleanup) looks provisional.
            Text(line.text)
                .foregroundStyle(line.isFinal ? .primary : .secondary)
                .italic(!line.isFinal)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            indicator
        }
        .animation(.default, value: line.state)
    }

    @ViewBuilder
    private var indicator: some View {
        switch line.state {
        case .partial:
            EmptyView()
        case .raw(let awaitingCleanup):
            if awaitingCleanup {
                ProgressView()
                    .controlSize(.mini)
                    .help("Cleaning up…")
            }
        case .cleaned:
            if let raw = line.rawText, raw != line.text {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.secondary)
                    .help("Corrected. Raw: \(raw)")
            }
        case .fellBack(let reason):
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .help("Showing raw text: \(reason)")
        }
    }
}
