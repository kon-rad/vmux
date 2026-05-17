import SwiftUI

/// Top-center translucent pill that mirrors `SpeechCoordinator.partialTranscript`
/// while a Gemini Live session is streaming into the focused terminal.
///
/// Visibility rules (T-017):
///   • Becomes visible as soon as `text` is non-empty.
///   • Stays visible for 2.0 s after the last change to `text`.
///   • If `text` clears (commit / focus change), the pill hides immediately —
///     there's nothing to display so the 2 s grace would only flash empty.
struct TranscriptPill: View {
    let text: String

    @State private var isVisible: Bool = false
    @State private var hideTask: Task<Void, Never>?

    private let hideDelayNanos: UInt64 = 2_000_000_000

    var body: some View {
        Group {
            if isVisible && !text.isEmpty {
                HStack(spacing: 8) {
                    Text(verbatim: "🎙")
                        .font(.title3)
                    Text(verbatim: "\"\(text)\"")
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.25), radius: 6, y: 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Dictation transcript")
                .accessibilityValue(text)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .onChange(of: text, initial: true) { _, newValue in
            handleTextChange(newValue)
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func handleTextChange(_ newValue: String) {
        hideTask?.cancel()
        if newValue.isEmpty {
            isVisible = false
            return
        }
        isVisible = true
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hideDelayNanos)
            if Task.isCancelled { return }
            isVisible = false
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        TranscriptPill(text: "echo hello world")
        TranscriptPill(text: "")
        TranscriptPill(text: "list every file in the home directory and pipe it through grep")
    }
    .padding()
    .frame(width: 600, height: 400)
}
