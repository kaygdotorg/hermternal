import HermternalCore
import Testing

@Test("dictation volatile updates replace one tail without duplication")
func volatileReplacement() {
    var assembler = DictationAssembler(base: "say: ", insertionOffset: 5)
    #expect(assembler.apply(DictationUpdate(text: "hel", isFinal: false)) == "say: hel")
    #expect(assembler.apply(DictationUpdate(text: "hello", isFinal: false)) == "say: hello")
    #expect(assembler.apply(DictationUpdate(text: "hello", isFinal: true)) == "say: hello")
    #expect(assembler.apply(DictationUpdate(text: " world", isFinal: false)) == "say: hello world")
    #expect(assembler.finish() == "say: hello world")
}

@Test("dictation preserves text on both sides of an insertion")
func insertionPosition() {
    var assembler = DictationAssembler(base: "before after", insertionOffset: 7)
    #expect(assembler.apply(DictationUpdate(text: "new", isFinal: true)) == "before newafter")
}

@Test("dictation clamps insertion offsets and finishes a volatile tail")
func insertionBoundaries() {
    var atStart = DictationAssembler(base: "base", insertionOffset: -10)
    #expect(atStart.apply(DictationUpdate(text: "x", isFinal: false)) == "xbase")
    #expect(atStart.finish() == "xbase")

    var atEnd = DictationAssembler(base: "base", insertionOffset: 100)
    #expect(atEnd.apply(DictationUpdate(text: "x", isFinal: false)) == "basex")
    #expect(atEnd.finish() == "basex")
}
