package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A stream that ends without one text delta. gpt-5-nano could spend its whole `max_completion_tokens`
 * on hidden reasoning and finish with `length` and no content, which read as a bare empty reply. Pins
 * the chunk reader and the message shown instead. Swift twin: `OpenAIStreamNoteTests`, which asserts
 * the same strings.
 */
class AiCoachEmptyStreamTest {

    @Test
    fun readsTheFinishReasonFromTheFinalChunk() {
        val note = AiCoach.openAiStreamNote("""{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}""")
        assertEquals("length", note?.first)
        assertNull(note?.second)
    }

    @Test
    fun readsAnErrorSentInsideTheStream() {
        val note = AiCoach.openAiStreamNote("""{"error":{"message":"Rate limit reached"}}""")
        assertNull(note?.first)
        assertEquals("Rate limit reached", note?.second)
    }

    @Test
    fun aContentChunkCarriesNoNote() {
        assertNull(AiCoach.openAiStreamNote("""{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"""))
        assertNull(AiCoach.openAiStreamNote("[DONE]"))
    }

    @Test
    fun emptyStreamMessages() {
        assertEquals(
            "The provider returned an error: Rate limit reached",
            AiCoach.emptyStreamMessage("stop", "Rate limit reached"),
        )
        assertEquals(
            "The model used its whole reply budget before writing an answer. " +
                "Try again, or choose a smaller or non-reasoning model.",
            AiCoach.emptyStreamMessage("length", null),
        )
        assertEquals("The provider's content filter withheld the reply.", AiCoach.emptyStreamMessage("content_filter", null))
        assertNull("a clean stop with no text has nothing more specific to say", AiCoach.emptyStreamMessage("stop", null))
        assertNull(AiCoach.emptyStreamMessage(null, null))
    }
}
