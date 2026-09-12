import Foundation
import Speech
import Translation
import AVFoundation

@main
struct EngineProbe {
    static func main() async {
        print("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            print("English locale unsupported"); exit(2)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let speechStatus = await AssetInventory.status(forModules: [transcriber])
        print("Speech model: \(speechStatus)")
        let translationStatus = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        print("Translation models: \(translationStatus)")
        if translationStatus == .installed {
            do {
                let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"), preferredStrategy: .lowLatency)
                let result = try await session.translate("We need to finish the first round of testing by next Friday.")
                print("TRANSLATION: \(result.targetText)")
                guard !result.targetText.isEmpty else { exit(3) }
            } catch { print("Translation error: \(error)"); exit(3) }
        }
        if CommandLine.arguments.count > 1, speechStatus == .installed {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let results = Task { () throws -> String in
                    var final = ""
                    for try await result in transcriber.results {
                        if result.isFinal { final += String(result.text.characters) + " " }
                    }
                    return final
                }
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let text = try await results.value
                print("TRANSCRIPTION: \(text)")
                guard text.lowercased().contains("testing") else { exit(4) }
            } catch { print("Transcription error: \(error)"); exit(4) }
        }
    }
}
