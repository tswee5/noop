import Foundation
import StrandAnalytics

struct OpenAIClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Standard params first (gpt-4 family). Newer/reasoning models reject `temperature` and want
        // `max_completion_tokens`; if the provider 400s about either, retry with the modern shape.
        do {
            return try await chat(key: key, model: model, wire: wire, modernParams: false, session: session)
        } catch let AICoachError.server(code, detail) where code == 400 && Self.wantsModernParams(detail) {
            return try await chat(key: key, model: model, wire: wire, modernParams: true, session: session)
        }
    }

    /// Pure: does a 400 body say the model wants the modern shape (`max_completion_tokens`, no
    /// `temperature`)? gpt-5 and the o-series reject the standard params this way.
    static func wantsModernParams(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return d.contains("max_completion_tokens") || d.contains("max_tokens")
            || d.contains("temperature") || d.contains("unsupported")
    }

    /// `max_completion_tokens` for the modern-params leg. That leg fronts REASONING models, whose
    /// hidden thinking tokens count against this cap: at 4096, gpt-5-nano could spend all of it
    /// thinking over the metrics context and finish with `length` and no text at all. A cap, not a
    /// target. Matches Android `REASONING_REPLY_BUDGET`.
    static let reasoningReplyBudget = 16_384

    /// Pure: the non-text parts of one stream chunk, read only to explain a stream that ended with
    /// no text: the choice's `finish_reason`, or an `error` object a server may send inside a 200.
    static func streamNote(_ payload: String) -> (finishReason: String?, error: String?)? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let finish = (obj["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
        let error = (obj["error"] as? [String: Any])?["message"] as? String
        return (finish == nil && error == nil) ? nil : (finish, error)
    }

    /// The error for a stream that completed without a single text delta, which the Coach would
    /// otherwise show as a bare "(no reply)". Nil when there is nothing more specific to say.
    static func emptyStreamError(finishReason: String?, error: String?) -> AICoachError? {
        if let error, !error.isEmpty {
            return .emptyReply("The provider returned an error: \(error)")
        }
        if finishReason == "length" {
            return .emptyReply("The model used its whole reply budget before writing an answer. "
                + "Try again, or choose a smaller or non-reasoning model.")
        }
        if finishReason == "content_filter" {
            return .emptyReply("The provider's content filter withheld the reply.")
        }
        return nil
    }

    /// K1: Stream via `stream: true`. Same body as `send`, with `stream: true` added. SSE parsing
    /// via `SseDeltas.openAiDelta`. Same modern-params retry on 400 as `send`, streamed: the 400
    /// arrives as the HTTP status before any delta, so nothing has been shown when it retries.
    /// Byte-parity pin in `SseDeltasTests.openAiReassembleMatchesFullReply`.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        do {
            try await streamChat(key: key, model: model, wire: wire, modernParams: false,
                                 session: session, onDelta: onDelta)
        } catch let AICoachError.server(code, detail) where code == 400 && Self.wantsModernParams(detail) {
            try await streamChat(key: key, model: model, wire: wire, modernParams: true,
                                 session: session, onDelta: onDelta)
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.openAI.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into chat-capable ids (gpt*/o*). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return (id.hasPrefix("gpt") || id.hasPrefix("o")) ? id : nil
        }
    }

    // MARK: Private

    private func streamChat(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var body: [String: Any] = ["model": model, "messages": wire, "stream": true]
        if modernParams {
            body["max_completion_tokens"] = Self.reasoningReplyBudget
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 4096
        }

        var req = URLRequest(url: AIProvider.openAI.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var wroteText = false
        var finishReason: String?
        var streamError: String?
        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.openAiDelta(payload) {
                wroteText = true
                onDelta(delta)
            } else if let note = Self.streamNote(payload) {
                finishReason = note.finishReason ?? finishReason
                streamError = note.error ?? streamError
            }
        }
        if !wroteText, let error = Self.emptyStreamError(finishReason: finishReason, error: streamError) {
            throw error
        }
    }

    /// `modernParams`: use `max_completion_tokens`, drop `temperature` — required by reasoning models.
    private func chat(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": wire]
        // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
        // reply complete (a cap, not a target — the system prompt keeps it short). Matches Gemini + Android.
        if modernParams {
            body["max_completion_tokens"] = Self.reasoningReplyBudget
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 4096
        }

        var req = URLRequest(url: AIProvider.openAI.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        return content
    }
}
