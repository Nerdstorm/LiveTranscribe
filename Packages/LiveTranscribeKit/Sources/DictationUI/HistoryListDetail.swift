import Persistence
import SwiftUI

/// One row of the history list: when, where, and the first two lines of what was inserted.
struct HistoryListRow: View {
    let record: DictationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(HistoryListFormat.time(record.createdAt))
                Text("·").accessibilityHidden(true)
                Text(HistoryListFormat.appName(record))
                    .lineLimit(1)
                if record.fellBack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("Cleanup didn't apply; the text was inserted as heard")
                        .accessibilityLabel("Cleanup didn't apply")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(record.cleanedText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The selected dictation: the inserted text beside what was heard, how it was cleaned up and
/// delivered, and what can be done with it.
struct HistoryListDetail: View {
    let record: DictationRecord
    let onCopy: () -> Void
    let onCopyOriginal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    textBlock("Inserted", record.cleanedText)
                    if record.rawText == record.cleanedText {
                        textBlock("What you said", "Same as inserted: cleanup made no changes.", secondary: true)
                    } else {
                        textBlock("What you said", record.rawText)
                    }
                    facts
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Copy", action: onCopy)
                    .help("Copy the inserted text")
                Button("Copy Original", action: onCopyOriginal)
                    .help("Copy what you said, before cleanup")
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
                    .help("Delete this dictation from history")
            }
            .padding(12)
        }
    }

    private func textBlock(_ title: String, _ text: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(secondary ? HierarchicalShapeStyle.secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            fact("When", HistoryListFormat.time(record.createdAt))
            fact("App", HistoryListFormat.appName(record))
            fact("Cleanup", HistoryListFormat.cleanupLevel(record.cleanupLevel))
            if record.fellBack {
                fact("Not cleaned up", record.fallbackReason ?? "Reason not recorded")
            }
            fact("Delivery", HistoryListFormat.delivery(record.delivery))
            fact("Audio", HistoryListFormat.seconds(fromMs: record.audioDurationMs))
            fact("Latency", HistoryListFormat.milliseconds(record.latencyMs))
        }
        .font(.callout)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
