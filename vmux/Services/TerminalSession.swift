import Foundation
import SwiftTerm
import UIKit

/// Abstracts the underlying SSH shell channel that backs a `TerminalSession`.
/// Vending this through a protocol keeps `TerminalSession` unit-testable —
/// production uses `CitadelShellChannel`; tests use a stub.
protocol TerminalShellChannel: AnyObject, Sendable {
    /// Bytes flowing from the remote shell back to the UI.
    var inbound: AsyncStream<Data> { get }
    /// Forward bytes from the UI into the remote shell.
    func send(_ data: Data) async throws
    /// Tear the channel down. Implementations should finish the `inbound` stream.
    func close() async
}

/// Lifecycle state of a `TerminalSession`. Drives the disconnect banner in
/// `TerminalWindowView` (T-024). Transitions are:
///   `.connecting` → `.connected` once the first byte arrives from the shell.
///   any → `.disconnected(reason:)` when `SSHConnectionManager` reports the
///   underlying client closed, or when the channel's inbound stream ends.
enum SessionStatus: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(reason: String)
}

@MainActor
@Observable
final class TerminalSession {
    let tabID: UUID
    let projectID: UUID

    /// The SwiftTerm UIKit view that renders the shell. The SwiftUI bridge in
    /// `TerminalWindowView` embeds this view directly so the session and the
    /// rendered terminal share the same `SwiftTerm.Terminal` instance.
    @ObservationIgnored let terminalView: TerminalView

    private(set) var lastByteAt: Date
    private(set) var status: SessionStatus = .connecting

    @ObservationIgnored private let channel: any TerminalShellChannel
    @ObservationIgnored private let viewDelegate: TerminalViewDelegateAdapter
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    init(
        tabID: UUID,
        projectID: UUID,
        channel: any TerminalShellChannel,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) {
        self.tabID = tabID
        self.projectID = projectID
        self.channel = channel
        self.lastByteAt = Date()

        let view = TerminalView(frame: frame)
        self.terminalView = view

        let adapter = TerminalViewDelegateAdapter()
        self.viewDelegate = adapter
        adapter.onSend = { [channel] data in
            Task { try? await channel.send(data) }
        }
        view.terminalDelegate = adapter

        startPump()
    }

    /// Convenience accessor for the underlying SwiftTerm parser.
    var terminal: Terminal { terminalView.getTerminal() }

    /// Write bytes into the remote shell. Used by `SpeechCoordinator` for
    /// transcribed commands; SwiftTerm keystrokes route through the delegate.
    func send(_ data: Data) {
        let channel = self.channel
        Task { try? await channel.send(data) }
    }

    /// Cancel the inbound pump and close the underlying channel.
    func close() async {
        if isClosed { return }
        isClosed = true
        pumpTask?.cancel()
        pumpTask = nil
        await channel.close()
    }

    /// External transitions used by `SSHConnectionManager`/`TerminalSessionRegistry`
    /// when the underlying SSH client closes for the project. The session itself
    /// transitions to `.connected` on first byte and to `.disconnected` when its
    /// inbound stream ends naturally — this method covers the SSH-driven case.
    func setStatus(_ newStatus: SessionStatus) {
        if status != newStatus {
            status = newStatus
        }
    }

    private func startPump() {
        let inbound = channel.inbound
        pumpTask = Task { @MainActor [weak self] in
            for await chunk in inbound {
                if Task.isCancelled { break }
                self?.handleInbound(chunk)
            }
            self?.handlePumpEnded()
        }
    }

    private func handleInbound(_ data: Data) {
        if data.isEmpty { return }
        if status == .connecting {
            status = .connected
        }
        let bytes = [UInt8](data)
        terminalView.feed(byteArray: ArraySlice(bytes))
        lastByteAt = Date()
    }

    private func handlePumpEnded() {
        if isClosed { return }
        if case .disconnected = status { return }
        status = .disconnected(reason: "Shell channel closed.")
    }
}

/// Forwarding delegate: SwiftTerm's `TerminalView` requires a delegate to
/// receive user keystrokes. We only need `send`; the other callbacks have no-op
/// defaults until later tasks need them (title bar, link tapping, etc.).
final class TerminalViewDelegateAdapter: TerminalViewDelegate {
    var onSend: (@Sendable (Data) -> Void)?

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onSend?(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
