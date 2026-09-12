import AppKit
import SwiftUI
import Speech
import Translation

@MainActor
final class AppModel: ObservableObject {
    @Published var transcript = Transcript()
    @Published var phase = "准备就绪"
    @Published var error: String?
    @Published var active = false
    @Published var busy = false
    @Published var applications: [MeetingApplication] = []
    @Published var selectedApplicationID = ""
    @Published var demo = false
    @Published var engineTest = false
    @Published var level = 0.0
    @Published var selectedSourceName = ""
    @Published var modelsReady = false
    @Published var modelStatus = "正在检查本地模型…"
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published var bilingual = true
    @Published var fontSize = 24.0
    @Published var opacity = 0.92
    @Published var pinned = true { didSet { overlay?.level = pinned ? .floating : .normal } }
    @Published var clickThrough = false { didSet { overlay?.ignoresMouseEvents = clickThrough } }
    @Published var overlayVisible = false
    @Published var selectedTab = 0
    private var overlay: NSPanel?
    private var capture: AudioCapture?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var pending: [Int64: String] = [:]
    private var session: TranslationSession?
    private var translationFailed = false
    private var generation = UUID()
    private var timeOffset = 0.0
    private var lastSignal = Date()
    private var lastResult = Date()
    var current: Caption? { transcript.captions.last }
    var selectedApplication: MeetingApplication? { applications.first { $0.id == selectedApplicationID } }
    var sourceName: String { active ? selectedSourceName : selectedApplication?.name ?? "请选择会议软件" }

    func refreshApplications() {
        guard !active, !busy else { return }
        let preferred = ["us.zoom.xos", "com.tencent.meeting", "com.microsoft.teams2", "com.microsoft.teams"]
        var seen = Set<String>()
        applications = NSWorkspace.shared.runningApplications.compactMap { app -> MeetingApplication? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            let name = id == "us.zoom.xos" ? "Zoom" : id == "com.tencent.meeting" ? "腾讯会议" : app.localizedName ?? id
            return MeetingApplication(id: id, name: name, pid: app.processIdentifier)
        }.sorted {
            let a = preferred.firstIndex(of: $0.id) ?? 100
            let b = preferred.firstIndex(of: $1.id) ?? 100
            return a == b ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : a < b
        }
        if !applications.contains(where: { $0.id == selectedApplicationID }) { selectedApplicationID = applications.first?.id ?? "" }
    }

    func checkModels() async {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            modelStatus = "这台 Mac 暂不支持本地英文识别。"; return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let speechStatus = await AssetInventory.status(forModules: [transcriber])
        let translationStatus = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        modelsReady = speechStatus == .installed && translationStatus == .installed
        modelStatus = modelsReady ? "英文识别与中文翻译模型已就绪" : "首次使用需准备英文识别与中英翻译模型"
        if modelsReady { session = makeTranslationSession() }
    }

    private func makeTranslationSession() -> TranslationSession {
        TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"), preferredStrategy: .lowLatency)
    }

    func prepareModels() {
        guard !busy, !active else { return }
        stopDemo()
        busy = true; error = nil; phase = "正在准备本地模型…"
        preparationTask = Task {
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw AppError.message("当前设备不支持英文识别。") }
                let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    phase = "正在下载英文识别模型，首次可能需要几分钟…"
                    try await request.downloadAndInstall()
                }
                try Task.checkCancellation()
                phase = "正在准备中英翻译模型…"
                if translationConfiguration == nil {
                    translationConfiguration = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"), preferredStrategy: .lowLatency)
                } else { translationConfiguration?.invalidate() }
            } catch { self.error = "模型准备失败：\(error.localizedDescription)"; phase = "模型未就绪"; busy = false }
        }
    }

    func prepareTranslation(using session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            await checkModels()
            phase = modelsReady ? "本地模型已就绪，可以开始会议翻译" : "模型尚未就绪，请稍后重试"
        } catch { self.error = "中英翻译模型准备失败：\(error.localizedDescription)"; phase = "模型未就绪" }
        busy = false
    }

    func start() {
        guard !active, !busy, modelsReady else { return }
        refreshApplications()
        guard let application = selectedApplication else { error = "请先打开会议软件，在右侧选择后开始。"; return }
        if demo { stopDemo(); transcript = Transcript() }
        busy = true; error = nil; phase = "正在连接所选会议软件…"
        generation = UUID()
        let token = generation
        timeOffset = (transcript.captions.last?.end ?? -0.01) + 0.01
        Task {
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw AppError.message("英文识别模型不可用。") }
                let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw AppError.message("未找到兼容的音频格式。") }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = analyzer
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(300))
                resultTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard let self, self.generation == token else { return }
                            let text = String(result.text.characters)
                            self.receive(start: result.range.start.seconds + self.timeOffset,
                                         end: CMTimeRangeGetEnd(result.range).seconds + self.timeOffset,
                                         text: text, final: result.isFinal)
                        }
                    } catch {
                        guard let self, self.generation == token, !Task.isCancelled,
                              !(error is CancellationError) else { return }
                        self.error = "英文识别中断：\(error.localizedDescription)"
                        Task { await self.stop() }
                    }
                }
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
                let capture = AudioCapture()
                capture.onSource = { [weak self] name in Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.selectedSourceName = name
                } }
                capture.onLevel = { [weak self] value in Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.level = value
                    if value > 0.015 { self.lastSignal = Date() }
                } }
                capture.onError = { [weak self] message in Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.error = message
                    await self.stop()
                } }
                self.capture = capture
                phase = "正在连接 \(application.name) 的音频…"
                try await capture.start(application: application, format: format, continuation: continuation)
                guard generation == token else { await capture.stop(); return }
                active = true; busy = false; phase = "正在聆听 · \(sourceName)"; lastSignal = Date(); lastResult = Date()
                showOverlay()
                healthTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard let self, self.active, !Task.isCancelled else { return }
                        if Date().timeIntervalSince(self.lastSignal) > 10 { self.phase = "未检测到声音，请确认所选软件正在播放；首次使用请允许音频访问" }
                        else if Date().timeIntervalSince(self.lastResult) > 20 { self.phase = "已收到声音，等待可识别的英文语音…" }
                        else { self.phase = "正在翻译 · \(self.sourceName)" }
                    }
                }
            } catch {
                self.error = error is CancellationError ? nil : "启动失败：\(error.localizedDescription)\n请确认所选软件正在运行并播放声音；只需音频访问权限。"
                await cleanup(cancel: true)
                busy = false; phase = error is CancellationError ? "已取消选择，未采集音频" : "未开始采集"
            }
        }
    }

    private func receive(start: Double, end: Double, text: String, final: Bool) {
        lastResult = Date()
        guard let id = transcript.ingest(start: start, end: end, text: text, final: final),
              let row = transcript.captions.first(where: { $0.id == id }) else { return }
        if row.chinese.isEmpty && !translationFailed { pending[id] = row.english }
        let valid = Set(transcript.captions.map(\.id))
        pending = pending.filter { valid.contains($0.key) }
        runTranslationQueue()
    }

    private func runTranslationQueue() {
        guard translateTask == nil, !pending.isEmpty else { return }
        let token = generation
        translateTask = Task { [weak self] in
            // Throttle/coalesce partial hypotheses without cancelling every request.
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, self.generation == token, !Task.isCancelled else { return }
            while !self.pending.isEmpty, !Task.isCancelled, self.generation == token {
                guard let id = self.pending.keys.min(), let source = self.pending.removeValue(forKey: id) else { break }
                if self.session == nil { self.session = self.makeTranslationSession() }
                do {
                    let translated = try await self.session!.translate(source)
                    guard self.generation == token, !Task.isCancelled else { break }
                    _ = self.transcript.apply(id: id, source: source, translation: translated.targetText)
                } catch {
                    if !Task.isCancelled, self.generation == token {
                        self.error = "中文翻译暂不可用：\(error.localizedDescription)。英文识别继续保留，可稍后点击「重试翻译」。"
                        self.translationFailed = true
                    }
                    // Don't hammer a missing model or broken service with retries.
                    self.pending.removeAll()
                    break
                }
            }
            if self.generation == token { self.translateTask = nil }
        }
    }

    func retryTranslation() {
        error = nil
        translationFailed = false
        session = makeTranslationSession()
        for caption in transcript.captions where caption.chinese.isEmpty { pending[caption.id] = caption.english }
        runTranslationQueue()
    }

    func testEngines() {
        guard !active, !busy, modelsReady else { return }
        resetTranscript()
        busy = true; phase = "引擎自检：生成测试语音 → 英文识别 → 中文翻译…"
        Task {
            do {
                let result = try await EngineSelfTest.run()
                let id = transcript.ingest(start: 0, end: 5, text: result.english, final: true)!
                _ = transcript.apply(id: id, source: result.english, translation: result.chinese)
                phase = "引擎自检通过 · 真实识别及翻译（合成测试语音）"
                demo = true
                engineTest = true
                showOverlay()
            } catch { self.error = "引擎自检失败：\(error.localizedDescription)"; phase = "自检未通过" }
            busy = false
        }
    }

    func stop() async {
        guard active || capture != nil || analyzer != nil else { return }
        active = false; busy = true; phase = "正在结束本次采集…"
        await cleanup(cancel: false)
        busy = false; phase = "已暂停 · 继续后保留本次记录"
    }

    private func cleanup(cancel: Bool) async {
        // Mark the consumer cancelled before ending the analyzer: it can emit a
        // cancellation result immediately, which isn't a user-facing failure.
        if cancel { resultTask?.cancel() }
        healthTask?.cancel(); healthTask = nil
        await capture?.stop(); capture = nil
        let old = analyzer; analyzer = nil
        if let old {
            if cancel { await old.cancelAndFinishNow() }
            else {
                do { try await old.finalizeAndFinishThroughEndOfInput() }
                catch { if self.error == nil { self.error = "结束识别时出现问题：\(error.localizedDescription)" } }
            }
        }
        if !cancel { await resultTask?.value }
        resultTask?.cancel(); resultTask = nil
        level = 0; active = false
    }

    func startDemo() {
        guard !active, !busy else { return }
        resetTranscript()
        demo = true; phase = "界面演示 · 使用预设文本，不采集音频"
        let rows = [
            ("We need to finish the first round of testing by next Friday.", "我们需要在下周五之前完成第一轮测试。"),
            ("Let's focus on the issues in the sign-in flow first.", "我们先处理登录流程中的问题。"),
            ("Could you share the updated designs with us by tomorrow?", "你能在明天之前把更新后的设计发给我们吗？"),
            ("Absolutely. I'll also include a summary of the user feedback.", "可以。我还会附上一份用户反馈摘要。"),
            ("Please make sure the new version works well on smaller screens.", "请确保新版本在较小的屏幕上也能正常使用。"),
            ("We will review the results together in our next meeting.", "我们将在下次会议中一起回顾结果。"),
            ("Does anyone have questions about the timeline?", "大家对时间安排有什么问题吗？"),
            ("Thank you everyone. Let's keep in touch this week.", "谢谢大家，我们这周保持联系。")
        ]
        showOverlay()
        demoTask = Task {
            for (i, row) in rows.enumerated() {
                guard !Task.isCancelled else { return }
                let id = transcript.ingest(start: Double(i * 4), end: Double(i * 4 + 3), text: row.0, final: true)!
                _ = transcript.apply(id: id, source: row.0, translation: row.1)
                try? await Task.sleep(for: .seconds(4))
            }
            phase = "演示结束 · 点击「开始翻译」使用真实音频"
        }
    }

    func stopDemo() { demoTask?.cancel(); demoTask = nil; demo = false; engineTest = false }

    func resetTranscript() {
        guard !active, !busy else { return }
        stopDemo(); generation = UUID()
        translateTask?.cancel(); translateTask = nil
        session?.cancel(); session = nil
        pending.removeAll(); transcript = Transcript(); error = nil; translationFailed = false
        phase = "准备就绪"
    }

    func showOverlay() {
        if overlay == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                                styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "听见 · 悬浮字幕"
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.level = pinned ? .floating : .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.minSize = NSSize(width: 580, height: 320)
            panel.contentView = NSHostingView(rootView: SubtitleView(model: self, floating: true))
            // Avoid accidental exposure in screen sharing where the capture stack respects this flag.
            // It is not a guarantee for third-party capture; README explains this limitation.
            panel.sharingType = .none
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.midX - 410, y: f.minY + 60))
            }
            overlay = panel
        }
        overlay?.ignoresMouseEvents = clickThrough
        overlay?.orderFrontRegardless(); overlayVisible = true
    }

    func hideOverlay() { overlay?.orderOut(nil); overlayVisible = false }
    func exportTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "听见-会议记录.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.transcript.export().write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}
