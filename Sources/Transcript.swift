import Foundation

struct Caption: Identifiable, Equatable {
    let id: Int64
    var start: Double
    var end: Double
    var english: String
    var chinese: String = ""
    var final: Bool
}

struct Transcript {
    private(set) var captions: [Caption] = []
    // Recognition revises time ranges. Replace overlapping hypotheses rather than
    // appending every partial result, and invalidate translations after a revision.
    mutating func ingest(start: Double, end: Double, text: String, final: Bool) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }),
              start.isFinite, end.isFinite, end >= start else { return nil }
        let id = Int64((start * 1000).rounded())
        let old = captions.first { $0.id == id }
        if let old, old.final && !final { return nil }
        captions.removeAll { $0.id == id || (!$0.final && $0.start < end && $0.end > start) }
        captions.append(Caption(id: id, start: start, end: end, english: text,
                                chinese: old?.english == text ? old!.chinese : "", final: final))
        captions.sort { $0.start < $1.start }
        return id
    }
    mutating func apply(id: Int64, source: String, translation: String) -> Bool {
        guard let index = captions.firstIndex(where: { $0.id == id && $0.english == source }) else { return false }
        captions[index].chinese = translation
        return true
    }
    func export() -> String {
        captions.map { "[\(Self.timestamp($0.start))] \($0.chinese.isEmpty ? "（尚未翻译）" : $0.chinese)\n\($0.english)" }.joined(separator: "\n\n")
    }
    static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

func runSelfTests() {
    var t = Transcript()
    let id = t.ingest(start: 0, end: 1, text: "We need", final: false)!
    assert(t.apply(id: id, source: "We need", translation: "我们需要"))
    _ = t.ingest(start: 0, end: 2, text: "We need to test.", final: true)
    assert(t.captions.count == 1 && t.captions[0].chinese.isEmpty)
    assert(!t.apply(id: id, source: "We need", translation: "陈旧结果"))
    assert(t.apply(id: id, source: "We need to test.", translation: "我们需要测试。"))
    assert(t.ingest(start: 0, end: 1, text: "We", final: false) == nil)
    _ = t.ingest(start: 2, end: 3, text: "Next", final: false)
    _ = t.ingest(start: 2, end: 4, text: "Next Friday.", final: true)
    assert(t.captions.count == 2 && t.captions[0].chinese == "我们需要测试。")
    assert(t.ingest(start: 4, end: 5, text: "  ", final: true) == nil)
    assert(t.ingest(start: 4, end: 5, text: ".", final: false) == nil)
    assert(t.ingest(start: .nan, end: 5, text: "bad", final: true) == nil)
    assert(t.export().contains("[00:00:00] 我们需要测试。"))
    assert(Transcript.timestamp(3661) == "01:01:01")
    print("PASS: revision replacement, stale translation rejection, final stability, range merge, empty/invalid input, export timestamps")
}
