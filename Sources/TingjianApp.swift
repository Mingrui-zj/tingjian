import SwiftUI
import AppKit
import Speech
import Translation

@main
struct TingjianApp: App {
    @StateObject private var model = AppModel()
    init() {
        if CommandLine.arguments.contains("--self-test") { runSelfTests(); exit(0) }
    }
    var body: some Scene {
        WindowGroup(id: "main") { MainView(model: model) }
            .defaultSize(width: 1060, height: 840)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandMenu("字幕") {
                    Button("显示悬浮字幕") { model.showOverlay() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("隐藏悬浮字幕") { model.hideOverlay() }
                    Toggle("鼠标穿透", isOn: $model.clickThrough)
                    Button("导出本次记录") { model.exportTranscript() }.disabled(model.transcript.captions.isEmpty)
                }
            }
        MenuBarExtra("听见", systemImage: model.active ? "waveform" : "captions.bubble") {
            MenuContent(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.phase)
        Divider()
        Button("打开听见") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if model.active { Button("暂停翻译") { Task { await model.stop() } }.disabled(model.busy) }
        else { Button("开始翻译") { model.start() }.disabled(model.busy || !model.modelsReady) }
        Button(model.overlayVisible ? "隐藏悬浮字幕" : "显示悬浮字幕") { if model.overlayVisible { model.hideOverlay() } else { model.showOverlay() } }
        Toggle("鼠标穿透", isOn: $model.clickThrough)
        Divider()
        Button("退出听见") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
