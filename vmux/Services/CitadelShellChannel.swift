import Foundation
import Citadel
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

extension Citadel.TTYStdinWriter: @unchecked @retroactive Sendable {}

@available(macOS 15.0, *)
extension Citadel.TTYOutput: @unchecked @retroactive Sendable {}

enum CitadelShellChannelError: Error, CustomStringConvertible {
    case notStarted

    var description: String {
        switch self {
        case .notStarted:
            return "Shell channel has not finished opening yet."
        }
    }
}

/// Production `TerminalShellChannel` that opens a PTY-backed shell over an
/// already-connected Citadel `SSHClient`. `connect(...)` returns once the PTY
/// is established (the closure inside Citadel's `withPTY` has captured the
/// stdin writer); after that, `inbound` streams shell output and `send(_:)` /
/// `close()` route through the live channel.
final class CitadelShellChannel: TerminalShellChannel, @unchecked Sendable {
    let inbound: AsyncStream<Data>

    private let inboundCont: AsyncStream<Data>.Continuation
    private let state = NIOLockedValueBox(State())

    private struct State {
        var outbound: TTYStdinWriter?
        var closeContinuation: CheckedContinuation<Void, Never>?
        var isClosed = false
        var runTask: Task<Void, Never>?
    }

    init() {
        var captured: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream<Data> { continuation in
            captured = continuation
        }
        self.inboundCont = captured
    }

    static func connect(
        client: SSHClient,
        cols: Int = 80,
        rows: Int = 24,
        term: String = "xterm-256color"
    ) async throws -> CitadelShellChannel {
        let channel = CitadelShellChannel()
        try await channel.start(client: client, cols: cols, rows: rows, term: term)
        return channel
    }

    func send(_ data: Data) async throws {
        let writer = state.withLockedValue { $0.outbound }
        guard let writer else { throw CitadelShellChannelError.notStarted }
        var buf = ByteBuffer()
        buf.writeBytes(data)
        try await writer.write(buf)
    }

    func close() async {
        let toResume: CheckedContinuation<Void, Never>? = state.withLockedValue { s in
            guard !s.isClosed else { return nil }
            s.isClosed = true
            let cont = s.closeContinuation
            s.closeContinuation = nil
            return cont
        }
        toResume?.resume()
    }

    private func start(
        client: SSHClient,
        cols: Int,
        rows: Int,
        term: String
    ) async throws {
        let inboundCont = self.inboundCont
        let stateBox = self.state

        try await withCheckedThrowingContinuation { (readyCont: CheckedContinuation<Void, Error>) in
            let resumeBox = NIOLockedValueBox<Bool>(false)

            let resumeReady: @Sendable (Result<Void, any Error>) -> Void = { result in
                let didResume = resumeBox.withLockedValue { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                guard didResume else { return }
                switch result {
                case .success: readyCont.resume()
                case .failure(let error): readyCont.resume(throwing: error)
                }
            }

            let signalClose: @Sendable () -> Void = {
                let toResume: CheckedContinuation<Void, Never>? = stateBox.withLockedValue { s in
                    guard !s.isClosed else { return nil }
                    s.isClosed = true
                    let c = s.closeContinuation
                    s.closeContinuation = nil
                    return c
                }
                toResume?.resume()
            }

            let task = Task<Void, Never> {
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: term,
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )

                do {
                    try await client.withPTY(request) { ttyOutput, writer in
                        stateBox.withLockedValue { $0.outbound = writer }
                        resumeReady(.success(()))

                        let pump = Task<Void, Never> {
                            do {
                                for try await chunk in ttyOutput {
                                    if Task.isCancelled { break }
                                    let buf: ByteBuffer
                                    switch chunk {
                                    case .stdout(let b): buf = b
                                    case .stderr(let b): buf = b
                                    }
                                    var b = buf
                                    if let bytes = b.readBytes(length: b.readableBytes) {
                                        inboundCont.yield(Data(bytes))
                                    }
                                }
                            } catch {
                                // Stream ended with an error — fall through to close.
                            }
                            signalClose()
                        }

                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            let shouldResumeNow: Bool = stateBox.withLockedValue { s in
                                if s.isClosed {
                                    return true
                                }
                                s.closeContinuation = cont
                                return false
                            }
                            if shouldResumeNow { cont.resume() }
                        }
                        pump.cancel()
                    }
                } catch {
                    resumeReady(.failure(error))
                }
                inboundCont.finish()
            }

            stateBox.withLockedValue { $0.runTask = task }
        }
    }
}
