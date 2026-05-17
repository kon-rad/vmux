import AVFoundation
import Foundation

/// Wraps one `AVAudioConverter` configured to downsample from the input node's
/// native format into the exact format Gemini Live requires: PCM, 16-bit
/// signed integer, 16 kHz, mono, interleaved, little-endian. On Apple
/// platforms the native byte order for `pcmFormatInt16` is little-endian, so
/// no explicit byte swap is needed.
///
/// `@unchecked Sendable`: the production caller (`AVAudioPipeline`) only invokes
/// `convert` from a single audio render thread per `AudioFormatConverter`
/// instance, so the wrapped `AVAudioConverter` is effectively serialized.
final class AudioFormatConverter: @unchecked Sendable {
    static let outputSampleRate: Double = 16_000
    private static let bytesPerOutputFrame = MemoryLayout<Int16>.size

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Convert one input buffer into PCM16 16 kHz mono bytes ready to send to
    /// Gemini Live. Returns nil on conversion error or for empty input.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFrames = buffer.frameLength
        guard inputFrames > 0 else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let projectedFrames = AVAudioFrameCount((Double(inputFrames) * ratio).rounded(.up))
        let capacity = max(projectedFrames + 1024, 1024)

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        var consumed = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error || convertError != nil { return nil }
        guard let channelData = outBuffer.int16ChannelData?[0] else { return nil }
        let byteCount = Int(outBuffer.frameLength) * Self.bytesPerOutputFrame
        guard byteCount > 0 else { return nil }
        return Data(bytes: channelData, count: byteCount)
    }
}
