import AVFoundation
import Foundation
import Speech
import Translation

// Only synthetic test speech is temporarily written. Meeting capture never writes audio.
private final class TestSpeech: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("tingjian-test-\(UUID().uuidString).caf")
    static let sentence = "We need to finish the first round of testing by next Friday."

    @MainActor
    func create() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let utterance = AVSpeechUtterance(string: Self.sentence)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.45
            synthesizer.write(utterance) { [weak self] buffer in self?.consume(buffer) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.finish(error: AppError.message("测试语音生成超时，请确认系统英文朗读声音可用。"))
            }
        }
    }
    private func consume(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { finish(error: nil); return }
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
            lock.unlock()
        } catch { lock.unlock(); finish(error: error) }
    }
    private func finish(error: Error?) {
        lock.lock()
        guard let c = continuation else { lock.unlock(); return }
        continuation = nil; file = nil
        let empty = frames == 0
        lock.unlock()
        if let error { try? FileManager.default.removeItem(at: url); c.resume(throwing: error) }
        else if empty { try? FileManager.default.removeItem(at: url); c.resume(throwing: AppError.message("系统没有生成测试音频。")) }
        else { c.resume(returning: url) }
    }
}

enum EngineSelfTest {
    @MainActor
    static func run(translate: @MainActor (String) async throws -> String) async throws -> (english: String, chinese: String) {
        let generator = TestSpeech()
        let url = try await generator.create()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw AppError.message("没有可用的英文识别模型。")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results {
                if result.isFinal { text += String(result.text.characters) + " " }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { await analyzer.cancelAndFinishNow() }
        }
        defer { timeout.cancel(); results.cancel() }
        do {
            let file = try AVAudioFile(forReading: url)
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let english = try await results.value
            guard english.lowercased().contains("testing") else {
                throw AppError.message("测试音频识别结果未包含预期词 testing：\(english)")
            }
            let chinese = try await translate(english)
            guard !chinese.isEmpty else { throw AppError.message("翻译引擎返回空文本。") }
            return (english, chinese)
        } catch { await analyzer.cancelAndFinishNow(); throw error }
    }
}
