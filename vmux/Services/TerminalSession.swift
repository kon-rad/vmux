import Foundation
import SwiftTerm

/// Abstracts the underlying SSH shell channel that backs a `TerminalSession`.
/// Vending this through a protocol keeps `TerminalSession` unit-testable —
/// the real implementation (T-012) wraps Citadel's TTY API; tests use a stub.
protocol TerminalShellChannel: AnyObject, Sendable {
    /// Bytes flowing from the remote shell back to the UI.
    var inbound: AsyncStream<Data> { get }
    /// Forward bytes from the UI into the remote shell.
    func send(_ data: Data) async throws
    /// Tear the channel down. Implementations should finish the `inbound` stream.
    func close() async
}

@MainActor
@Observable
final class TerminalSession {
    let tabID: UUID
    let projectID: UUID

    @ObservationIgnored let terminal: Terminal

    private(set) var lastByteAt: Date

    @ObservationIgnored private let channel: any TerminalShellChannel
    @ObservationIgnored private let delegate: TerminalSessionDelegate
    @ObservationIgnored private var pumpTask: Task<Void, Never>?

    init(
        tabID: UUID,
        projectID: UUID,
        channel: any TerminalShellChannel,
        cols: Int = 80,
        rows: Int = 24,
        scrollback: Int = 500
    ) {
        self.tabID = tabID
        self.projectID = projectID
        self.channel = channel
        self.lastByteAt = Date()

        let delegate = TerminalSessionDelegate()
        self.delegate = delegate

        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        self.terminal = Terminal(delegate: delegate, options: options)

        delegate.onSend = { [channel] data in
            Task {
                try? await channel.send(data)
            }
        }

        startPump()
    }

    /// Write bytes into the remote shell. Used by SwiftTerm for keyboard input
    /// and by `SpeechCoordinator` for transcribed commands.
    func send(_ data: Data) {
        let channel = self.channel
        Task {
            try? await channel.send(data)
        }
    }

    /// Cancel the inbound pump and close the underlying channel.
    func close() async {
        pumpTask?.cancel()
        pumpTask = nil
        await channel.close()
    }

    private func startPump() {
        let inbound = channel.inbound
        pumpTask = Task { [weak self] in
            for await chunk in inbound {
                if Task.isCancelled { break }
                await self?.handleInbound(chunk)
            }
        }
    }

    private func handleInbound(_ data: Data) {
        terminal.feed(byteArray: [UInt8](data))
        lastByteAt = Date()
    }
}

/// Forwarding delegate: SwiftTerm's `Terminal` requires a delegate, but the
/// only callback we actually need is `send`, which fires when the emulator
/// produces response bytes (e.g. for DA queries) or when our higher-level
/// code wants user keystrokes routed back to the host.
final class TerminalSessionDelegate: TerminalDelegate {
    var onSend: (@Sendable (Data) -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        onSend?(Data(data))
    }
}
