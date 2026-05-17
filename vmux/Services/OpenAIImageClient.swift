import Foundation

/// Result of a panorama generation request. `warning` is non-nil when a
/// fallback path was used (e.g. the requested model or image size was not
/// accepted by the API).
struct GenerationResult: Equatable, Sendable {
    let pngBytes: Data
    let warning: String?
}

/// Errors surfaced by `OpenAIImageClient.generatePanorama` after all
/// fallbacks have been attempted.
enum OpenAIImageClientError: Error, Equatable {
    case invalidResponse
    case http(status: Int, message: String)
    case missingImageData
    case base64DecodeFailed
}

/// Posts to the OpenAI Images API and decodes the returned PNG. Implements the
/// model and size fallbacks documented in PRD §10:
/// - HTTP 404 or HTTP 400 with `error.code == "invalid_model"` → retry once
///   with `gpt-image-1` and surface a model warning.
/// - HTTP 400 with `error.code == "invalid_size"` → retry once with
///   `1024x1024` and surface a size warning.
actor OpenAIImageClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!
    static let promptSuffix = ". Fully immersive 360-degree equirectangular panorama, seamless horizontal wrap, no visible seam, evenly lit, no text, no watermarks."

    static let primaryModel = "gpt-image-2"
    static let fallbackModel = "gpt-image-1"
    static let primarySize = "2048x1024"
    static let fallbackSize = "1024x1024"

    static let modelWarning = "gpt-image-2 unavailable; used gpt-image-1 (may not be true 360°)"
    static let sizeWarning = "size 2048x1024 unavailable; used 1024x1024 (visible seam may appear)"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generatePanorama(prompt: String, apiKey: String) async throws -> GenerationResult {
        let wrappedPrompt = prompt + Self.promptSuffix
        var model = Self.primaryModel
        var size = Self.primarySize
        var modelWarning: String?
        var sizeWarning: String?
        var modelFallbackUsed = false
        var sizeFallbackUsed = false

        for attempt in 0..<3 {
            do {
                let bytes = try await postAndDecode(
                    model: model,
                    prompt: wrappedPrompt,
                    size: size,
                    apiKey: apiKey
                )
                return GenerationResult(
                    pngBytes: bytes,
                    warning: combinedWarning(model: modelWarning, size: sizeWarning)
                )
            } catch let error as OpenAIImageClientError {
                guard attempt < 2 else { throw error }
                switch classify(error) {
                case .invalidModel where !modelFallbackUsed:
                    modelFallbackUsed = true
                    modelWarning = Self.modelWarning
                    model = Self.fallbackModel
                case .invalidSize where !sizeFallbackUsed:
                    sizeFallbackUsed = true
                    sizeWarning = Self.sizeWarning
                    size = Self.fallbackSize
                default:
                    throw error
                }
            }
        }

        throw OpenAIImageClientError.invalidResponse
    }

    // MARK: - Request

    private func postAndDecode(
        model: String,
        prompt: String,
        size: String,
        apiKey: String
    ) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            prompt: prompt,
            size: size
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIImageClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = parseErrorMessage(data: data) ?? "HTTP \(http.statusCode)"
            throw OpenAIImageClientError.http(status: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ImagesAPIResponse.self, from: data)
        guard let first = decoded.data.first, let b64 = first.b64_json else {
            throw OpenAIImageClientError.missingImageData
        }
        guard let bytes = Data(base64Encoded: b64) else {
            throw OpenAIImageClientError.base64DecodeFailed
        }
        return bytes
    }

    static func encodeRequestBody(model: String, prompt: String, size: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "size": size,
            "response_format": "b64_json",
            "n": 1,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Fallback classification

    private enum FallbackReason {
        case invalidModel
        case invalidSize
        case other
    }

    private func classify(_ error: OpenAIImageClientError) -> FallbackReason {
        guard case let .http(status, message) = error else { return .other }
        let lowered = message.lowercased()
        if status == 404 {
            return .invalidModel
        }
        if status == 400 {
            if lowered.contains("invalid_model") || lowered.contains("model_not_found") {
                return .invalidModel
            }
            if lowered.contains("invalid_size") {
                return .invalidSize
            }
        }
        return .other
    }

    private func combinedWarning(model: String?, size: String?) -> String? {
        let parts = [model, size].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private func parseErrorMessage(data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
                let type: String?
            }
            let error: Detail?
        }
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let detail = envelope.error else {
            return String(data: data, encoding: .utf8)
        }
        let bits = [detail.code, detail.type, detail.message]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return bits.isEmpty ? nil : bits.joined(separator: " | ")
    }

    // MARK: - Response shape

    private struct ImagesAPIResponse: Decodable {
        struct Item: Decodable {
            let b64_json: String?
        }
        let data: [Item]
    }
}
