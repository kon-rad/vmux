import SwiftUI
import SwiftData

struct TerminalWindowView: View {
    @Environment(\.modelContext) private var modelContext
    let tabID: UUID

    @State private var session: TerminalSession?
    @State private var loadError: String?
    @State private var isLoading = false
    private let focusStore = FocusStore.shared

    private var isFocused: Bool {
        focusStore.focusedTabID == tabID
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 400)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.65 : 0), lineWidth: 2)
                .animation(.easeInOut(duration: 0.2), value: isFocused)
                .allowsHitTesting(false)
        )
        .onHover { hovering in
            focusStore.reportHover(tabID: tabID, hovering: hovering)
        }
        .task(id: tabID) {
            await loadSession()
        }
    }

    private var titleBar: some View {
        let tab = lookupTab()
        return HStack(spacing: 8) {
            Text(tab?.title ?? "Terminal")
                .font(.headline)
            if let projectName = tab?.project?.name {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let session {
            SwiftTermView(session: session)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if case .disconnected(let reason) = session.status {
                        disconnectBanner(reason: reason)
                            .padding(.top, 12)
                    }
                }
        } else if let loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Couldn't open terminal")
                    .font(.headline)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    Task { await loadSession(forceReload: true) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func lookupTab() -> vmux.Tab? {
        let id = tabID
        var descriptor = FetchDescriptor<vmux.Tab>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    @MainActor
    private func loadSession(forceReload: Bool = false) async {
        if let existing = TerminalSessionRegistry.shared.sessionIfExists(tabID: tabID),
           !forceReload {
            session = existing
            loadError = nil
            return
        }
        guard let tab = lookupTab() else {
            loadError = "Tab no longer exists."
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            session = try await TerminalSessionRegistry.shared.session(for: tab)
        } catch {
            session = nil
            loadError = String(describing: error)
        }
    }

    private func disconnectBanner(reason: String) -> some View {
        Button {
            Task { await reconnect() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disconnected — Reconnect")
                        .font(.headline)
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func reconnect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            session = try await TerminalSessionRegistry.shared.reconnect(tabID: tabID)
            loadError = nil
        } catch {
            session = nil
            loadError = String(describing: error)
        }
    }
}
