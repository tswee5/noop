import XCTest
@testable import Strand

/// A stream that ends without one text delta. gpt-5-nano could spend its whole `max_completion_tokens`
/// on hidden reasoning and finish with `length` and no content, and the Coach showed a bare
/// "(no reply)". Pins the chunk reader and the message shown instead. Kotlin twin:
/// `AiCoachEmptyStreamTest`, which asserts the same strings.
final class OpenAIStreamNoteTests: XCTestCase {

    func testReadsTheFinishReasonFromTheFinalChunk() {
        let note = OpenAIClient.streamNote(#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#)
        XCTAssertEqual(note?.finishReason, "length")
        XCTAssertNil(note?.error)
    }

    func testReadsAnErrorSentInsideTheStream() {
        let note = OpenAIClient.streamNote(#"{"error":{"message":"Rate limit reached"}}"#)
        XCTAssertNil(note?.finishReason)
        XCTAssertEqual(note?.error, "Rate limit reached")
    }

    func testAContentChunkCarriesNoNote() {
        XCTAssertNil(OpenAIClient.streamNote(
            #"{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#))
        XCTAssertNil(OpenAIClient.streamNote("[DONE]"))
    }

    func testEmptyStreamMessages() {
        func message(_ finish: String?, _ error: String?) -> String? {
            guard case .emptyReply(let m)? = OpenAIClient.emptyStreamError(finishReason: finish, error: error)
            else { return nil }
            return m
        }
        XCTAssertEqual(message("stop", "Rate limit reached"), "The provider returned an error: Rate limit reached")
        XCTAssertEqual(message("length", nil), "The model used its whole reply budget before writing an answer. "
            + "Try again, or choose a smaller or non-reasoning model.")
        XCTAssertEqual(message("content_filter", nil), "The provider's content filter withheld the reply.")
        XCTAssertNil(message("stop", nil), "a clean stop with no text has nothing more specific to say")
        XCTAssertNil(message(nil, nil))
    }
}
