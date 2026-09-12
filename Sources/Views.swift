import SwiftUI
import AppKit
import Translation

struct SubtitleView: View {
    @ObservedObject var model: AppModel
    var floating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(model.active ? Color.mint : Color.gray).frame(width: 6, height: 6)
                Text(model.engineTest ? "听见 · 引擎自检" : model.demo ? "听见 · 示例字幕" : model.active ? "听见 · 正在翻译" : "听见 · 字幕预览")
                Spacer()
                if floating {
                    Button { model.pinned.toggle() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }.help("切换置顶")
                    Button { model.hideOverlay() } label: { Image(systemName: "xmark") }.help("隐藏字幕，可从菜单栏重新打开")
                } else { Text("EN → 简体中文") }
            }
            .font(.system(size: 11)).foregroundStyle(Color(red: 0.72, green: 0.79, blue: 0.89))
            .buttonStyle(.plain)
            CaptionTimeline(model: model)

        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: floating ? .infinity : nil, alignment: .topLeading)
        .background(Color(red: 0.09, green: 0.12, blue: 0.17).opacity(model.opacity), in: RoundedRectangle(cornerRadius: 14))
    }
}


// Each surface owns its reading position; incoming revisions never move a reader
// who has paged or scrolled into history. Only “回到最新” resumes following.
private struct CaptionScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
    var contentHeight: CGFloat = 0
}

struct CaptionTimeline: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var metrics = CaptionScrollMetrics()
    private var chineseSize: CGFloat { compact ? 13 : model.fontSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.transcript.captions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("让理解，跟上对话。")
                        .font(.system(size: chineseSize, weight: .medium))
                    Text("字幕将逐句保留，向上滚动可查看之前的内容。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: compact ? 14 : 16) {
                        ForEach(model.transcript.captions) { caption in
                            VStack(alignment: .leading, spacing: 5) {
                                if compact {
                                    Text(Transcript.timestamp(caption.start))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(caption.chinese.isEmpty ? "正在翻译…" : caption.chinese)
                                    .font(.system(size: chineseSize, weight: .medium))
                                    .foregroundStyle(compact ? Color.primary : .white)
                                    .fixedSize(horizontal: false, vertical: true)
                                if model.bilingual || compact {
                                    Text(caption.english)
                                        .font(.system(size: compact ? 11 : max(12, model.fontSize * 0.58)))
                                        .foregroundStyle(compact ? Color.secondary : Color(red: 0.75, green: 0.80, blue: 0.88))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(caption.id)
                        }
                    }.padding(.trailing, 8)
                }
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking { following = false }
                }
                .onScrollGeometryChange(for: CaptionScrollMetrics.self) { geometry in
                    CaptionScrollMetrics(offset: geometry.contentOffset.y,
                                         height: geometry.containerSize.height,
                                         contentHeight: geometry.contentSize.height)
                } action: { old, new in
                    metrics = new
                    if following && old.contentHeight != new.contentHeight { position.scrollTo(edge: .bottom) }
                }
                .onChange(of: model.transcript.captions) { _, _ in
                    if following { position.scrollTo(edge: .bottom) }
                }
            }
            HStack(spacing: 10) {
                Button {
                    following = false
                    position.scrollTo(y: max(0, metrics.offset - max(100, metrics.height * 0.8)))
                } label: { Label("上一页", systemImage: "chevron.up") }
                .disabled(model.transcript.captions.isEmpty || metrics.offset <= 1)
                Text(following ? "跟随最新 · \(model.transcript.captions.count) 条" : "正在查看历史")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    following = true
                    position.scrollTo(edge: .bottom)
                } label: { Label("回到最新", systemImage: "arrow.down.to.line") }
                .disabled(model.transcript.captions.isEmpty)
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
        }
        .onChange(of: model.transcript.captions.isEmpty) { _, empty in
            if empty { following = true; position.scrollTo(edge: .top) }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) { Image(systemName: "headphones"); Text("让理解，跟上对话") }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("专注会议，中文就在眼前。")
                    .font(.system(size: 25, weight: .medium)).padding(.top, 8).padding(.bottom, 26)
                HStack { Label("实时字幕", systemImage: "captions.bubble"); Spacer(); Text(model.engineTest ? "合成语音自检" : model.demo ? "预设文本演示" : "本地处理").foregroundStyle(.secondary) }
                    .font(.system(size: 12)).padding(.bottom, 12)
                SubtitleView(model: model).frame(minHeight: 320, maxHeight: .infinity)
                HStack(spacing: 10) {
                    if model.active {
                        Button { Task { await model.stop() } } label: { Label("暂停翻译", systemImage: "pause.fill") }
                            .buttonStyle(.borderedProminent).disabled(model.busy)
                    } else {
                        Button { model.start() } label: { Label(model.transcript.captions.isEmpty || model.demo ? "开始翻译" : "继续翻译", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(model.busy || !model.modelsReady || model.selectedApplication == nil)
                    }
                    Button { model.showOverlay() } label: { Label("悬浮字幕", systemImage: "rectangle.on.rectangle") }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }.controlSize(.large).padding(.top, 18)
                HStack(spacing: 10) {
                    ProgressView(value: model.level).frame(width: 68).tint(.mint)
                    Text(model.phase).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }.padding(.top, 13)
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("需要处理", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .medium))
                        Text(error).font(.system(size: 11)).textSelection(.enabled)
                        HStack {
                            Button("重试翻译") { model.retryTranslation() }.disabled(!model.modelsReady || model.demo)
                            Button("关闭提示") { model.error = nil }
                        }.font(.system(size: 11))
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10)).padding(.top, 16)
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Label("设备上的 AI", systemImage: "cpu").font(.system(size: 13, weight: .medium)); Spacer(); if model.modelsReady { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
                    Text(model.modelStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        if !model.modelsReady {
                            Button("准备本地模型") { model.prepareModels() }.disabled(model.busy || model.active)
                        }
                        Button("字幕演示") { model.startDemo() }.disabled(model.busy || model.active)
                        if model.modelsReady {
                            Button("引擎自检") { model.testEngines() }.disabled(model.busy || model.active)
                        }
                        Spacer()
                        Text("无需 API Key").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                Text("识别与翻译在本机完成。首次下载模型需要联网；原始音频不落盘。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
            }.padding(28).frame(minWidth: 490, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 18) {
                Picker("面板", selection: $model.selectedTab) { Text("字幕设置").tag(0); Text("本次记录").tag(1) }.pickerStyle(.segmented)
                if model.selectedTab == 0 { settings } else { history }
                Spacer(minLength: 0)
            }.padding(20).frame(minWidth: 280, idealWidth: 300, maxWidth: 340, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("听见 · 会议字幕 0.2.1")
        .translationTask(model.translationConfiguration) { session in await model.prepareTranslation(using: session) }
        .task { model.refreshApplications(); await model.checkModels() }
    }

    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("会议软件").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.refreshApplications() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).help("刷新正在运行的软件").disabled(model.busy || model.active)
                    }
                    Picker("选择会议软件", selection: $model.selectedApplicationID) {
                        if model.applications.isEmpty { Text("请先打开会议软件").tag("") }
                        ForEach(model.applications) { application in Text(application.name).tag(application.id) }
                    }.labelsHidden().disabled(model.busy || model.active)
                    Label(model.active ? "只采集 \(model.sourceName)" : "按应用采集声音", systemImage: "app.badge.checkmark")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("选好软件后点击「开始翻译」。Zoom、腾讯会议优先显示；打开新软件后可刷新列表。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("不共享屏幕，不采集麦克风。切换软件前请先暂停翻译。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack { Text("英语"); Spacer(); Image(systemName: "arrow.right").foregroundStyle(.secondary); Spacer(); Text("简体中文") }.font(.system(size: 13))
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("字幕显示").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("字幕显示", selection: $model.bilingual) { Text("仅中文").tag(false); Text("中英双语").tag(true) }.pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("中文字幕字号"); Spacer(); Text("\(Int(model.fontSize)) pt").monospacedDigit() }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Slider(value: $model.fontSize, in: 18...36, step: 1).accessibilityLabel("中文字幕字号")
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("背景不透明度"); Spacer(); Text("\(Int(model.opacity * 100))%").monospacedDigit() }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Slider(value: $model.opacity, in: 0.6...1).accessibilityLabel("背景不透明度")
                }
                Toggle("字幕窗口置顶", isOn: $model.pinned).toggleStyle(.switch).controlSize(.small)
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("鼠标穿透", isOn: $model.clickThrough).toggleStyle(.switch).controlSize(.small)
                    Text("开启后可点击字幕下方的会议。通过本窗口或菜单栏恢复操作。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                Label("拖动字幕空白处移动窗口，拖动边缘调整大小。", systemImage: "hand.draw")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.top, 5)
        }
    }
    var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("\(model.transcript.captions.count) 条字幕").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Button("导出") { model.exportTranscript() }.disabled(model.transcript.captions.isEmpty) }
            if model.transcript.captions.isEmpty {
                ContentUnavailableView("还没有字幕", systemImage: "text.bubble", description: Text("开始会议翻译或播放字幕演示。"))
            } else {
                CaptionTimeline(model: model, compact: true)
            }
            Button("清空本次记录") { model.resetTranscript() }.disabled(model.active || model.busy || model.transcript.captions.isEmpty)
            Text("记录只保存在内存中，退出即清除。需要留存时请先导出。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
