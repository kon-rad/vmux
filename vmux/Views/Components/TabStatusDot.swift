import SwiftUI

/// Pure state derivation for the sidebar tab status dot (T-014).
///
/// Decouples the rendering from the time clock so unit tests can exercise the
/// three states without relying on the wall clock.
enum TabStatusState: Equatable {
    case running        // amber
    case justFinished   // green pulse
    case idle           // gray

    init(isRunning: Bool, lastActivityAt: Date, now: Date) {
        if isRunning {
            self = .running
        } else if now.timeIntervalSince(lastActivityAt) > 5 {
            self = .idle
        } else {
            self = .justFinished
        }
    }
}

/// Sidebar tab row status dot. Re-evaluates every 0.5s via `TimelineView` so the
/// transition from green pulse → gray happens on its own without depending on a
/// SwiftData write to trigger a redraw.
struct TabStatusDot: View {
    let isRunning: Bool
    let lastActivityAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(for: TabStatusState(
                isRunning: isRunning,
                lastActivityAt: lastActivityAt,
                now: context.date
            ))
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(for state: TabStatusState) -> some View {
        switch state {
        case .running:
            Image(systemName: "circle.fill")
                .resizable()
                .foregroundStyle(.orange)
        case .justFinished:
            Image(systemName: "circle.fill")
                .resizable()
                .foregroundStyle(.green)
                .symbolEffect(.pulse, isActive: true)
        case .idle:
            Image(systemName: "circle.fill")
                .resizable()
                .foregroundStyle(.gray)
        }
    }
}
