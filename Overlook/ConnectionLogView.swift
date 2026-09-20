import SwiftUI

/// The log's footprint in the Connections panel: the last problem and a way into the full log.
///
/// The events themselves live in `ConnectionLogPanel`. What belongs here is the one line the
/// operator wants while they are already looking at the connection — whether anything has gone
/// wrong, and when. Everything else is a click away.
struct ConnectionLogSummary: View {
    @EnvironmentObject private var logStore: ConnectionLogStore

    let onOpenLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
                .padding(.vertical, 2)

            if let problem = logStore.lastProblem {
                // Re-renders on the minute so "4 min ago" doesn't go stale while the panel sits
                // open, without the log publishing anything.
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Image(systemName: problem.level >= .error
                                  ? "exclamationmark.triangle.fill"
                                  : "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundColor(ConnectionLogRow.color(for: problem.level))

                            Text("Last problem · \(Self.agoText(seconds: context.date.timeIntervalSince(problem.date)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text(problem.message)
                            .font(.caption)
                            .foregroundColor(ConnectionLogRow.color(for: problem.level))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(problem.message)
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("No problems recorded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button(action: onOpenLog) {
                Text(logStore.events.isEmpty ? "Open Connection Log" : "Open Connection Log (\(logStore.events.count))")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .padding(.top, 1)
        }
    }

    private static func agoText(seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h \(minutes % 60) min ago"
    }
}

/// The toolbar's log button: `doc.text`, with a dot while warnings or errors have arrived since
/// the panel was last opened.
///
/// Deliberately never disabled. Settings and OCR both need a live session; the log is wanted
/// most in the minute after a drop, which is exactly when there isn't one.
struct ConnectionLogToolbarButton: View {
    @EnvironmentObject private var logStore: ConnectionLogStore

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The padding is what makes room for the dot: an overlay adds nothing to layout, and
            // both the toolbar item and the fullscreen HUD clip their content, so a badge hung
            // past the trailing edge would be cut in half.
            Image(systemName: "doc.text")
                .padding(2)
                .overlay(alignment: .topTrailing) {
                    if logStore.unseenProblemCount > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                }
        }
        .help(helpText)
    }

    private var helpText: String {
        let count = logStore.unseenProblemCount
        guard count > 0 else { return "Connection Log" }
        return "Connection Log — \(count) new problem\(count == 1 ? "" : "s")"
    }
}
