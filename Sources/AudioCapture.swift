import Foundation
import AppKit
import AVFoundation
import CoreAudio
import Speech

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct MeetingApplication: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let pid: pid_t
}

// Inclusion-only targeting. A missing process never falls back to a global tap.
func belongsToApplication(processBundleID: String, processPID: pid_t, application: MeetingApplication) -> Bool {
    processPID == application.pid || processBundleID == application.id || processBundleID.hasPrefix(application.id + ".")
}

private enum HAL {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw AppError.message("\(action)失败（Core Audio \(status)）。如系统提示，请仅允许音频访问；无需开启录屏。")
        }
    }
    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "读取音频进程")
        return value
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "读取音频进程标识")
        return value?.takeRetainedValue() as String? ?? ""
    }
    static func processes() throws -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "枚举音频进程")
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try objects.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!), "枚举音频进程")
        }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

// Core Audio process tap: only the selected application's output is included.
// No ScreenCaptureKit, screen picker, global tap, microphone, or default-device mutation.
final class AudioCapture: @unchecked Sendable {
    private let controlQueue = DispatchQueue(label: "app.tingjian.tap-control")
    private let audioQueue = DispatchQueue(label: "app.tingjian.tap-audio", qos: .userInitiated)
    private var tapID: AudioObjectID = 0
    private var deviceID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var target: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var lastMeter = Date.distantPast
    private var reportedFailure = false
    var onLevel: (@Sendable (Double) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onSource: (@Sendable (String) -> Void)?

    func start(application: MeetingApplication, format: AVAudioFormat,
               continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    try self.configure(application: application, target: format, continuation: continuation)
                    ready.resume()
                } catch {
                    self.destroyResources()
                    continuation.finish()
                    ready.resume(throwing: error)
                }
            }
        }
    }

    private func configure(application: MeetingApplication, target: AVAudioFormat,
                           continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        guard !application.id.isEmpty, application.pid > 0,
              application.id != Bundle.main.bundleIdentifier else {
            throw AppError.message("请选择一个正在运行的会议软件。")
        }
        var processIDs: [AudioObjectID] = []
        var bundleIDs: Set<String> = [application.id]
        for object in try HAL.processes() {
            guard let pid = try? HAL.uint32(object, kAudioProcessPropertyPID),
                  let bundle = try? HAL.string(object, kAudioProcessPropertyBundleID) else { continue }
            if belongsToApplication(processBundleID: bundle, processPID: pid_t(bitPattern: pid), application: application) {
                processIDs.append(object)
                if !bundle.isEmpty { bundleIDs.insert(bundle) }
            }
        }
        // macOS 26 bundle targeting also covers the app starting audio after capture begins.
        let description = CATapDescription(monoMixdownOfProcesses: processIDs)
        description.bundleIDs = Array(bundleIDs).sorted()
        description.isExclusive = false
        description.isPrivate = true
        description.isProcessRestoreEnabled = true
        description.muteBehavior = .unmuted
        description.name = "听见 · \(application.name)"
        description.uuid = UUID()
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "创建指定应用音频采集")
        var tapAddress = HAL.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try HAL.check(AudioObjectGetPropertyData(tapID, &tapAddress, 0, nil, &size, &asbd), "读取应用音频格式")
        guard asbd.mSampleRate > 0, asbd.mBytesPerFrame > 0,
              let source = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw AppError.message("无法读取该应用的音频格式。请在会议中播放声音后重试。")
        }
        // A private tap-only aggregate exposes the tap to an IOProc. It is never
        // installed as the user's input/output device and disappears with this app.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "听见应用音频",
            kAudioAggregateDeviceUIDKey: "local.tingjian.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "连接应用音频")
        audioQueue.sync {
            self.target = target
            self.inputFormat = source
            self.converter = converter
            self.continuation = continuation
            self.reportedFailure = false
            self.lastMeter = .distantPast
        }
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, audioQueue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }, "注册应用音频回调")
        try HAL.check(AudioDeviceStart(deviceID, ioProc), "开始应用音频采集")
        onSource?(application.name)
    }

    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controlQueue.async { self.destroyResources(); done.resume() }
        }
    }
    private func destroyResources() {
        if deviceID != 0, let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        if deviceID != 0 { AudioHardwareDestroyAggregateDevice(deviceID); deviceID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        audioQueue.sync {
            continuation?.finish(); continuation = nil
            target = nil; inputFormat = nil; converter = nil
        }
    }
    private func fail(_ message: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        onError?(message)
    }
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard let format = inputFormat, let target, let converter, let continuation else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mData != nil else { return }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let count = Int(first.mDataByteSize / bytesPerFrame)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard buffers.count == destination.count else { fail("所选应用的音频通道布局发生变化，请暂停后重新开始。"); return }
        for i in buffers.indices {
            guard let src = buffers[i].mData, let dst = destination[i].mData,
                  buffers[i].mDataByteSize >= destination[i].mDataByteSize else { return }
            memcpy(dst, src, Int(destination[i].mDataByteSize))
        }
        if Date().timeIntervalSince(lastMeter) > 0.15 {
            lastMeter = Date()
            if let values = pcm.floatChannelData?[0] {
                var sum: Double = 0
                for i in 0..<count { sum += Double(values[i] * values[i]) }
                onLevel?(min(1, sqrt(sum / Double(count)) * 8))
            }
        }
        let output: AVAudioPCMBuffer
        if format == target { output = pcm }
        else {
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(count) * target.sampleRate / format.sampleRate) + 64)) else { return }
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: converted, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true; inputStatus.pointee = .haveData
                return pcm
            }
            guard result != .error, error == nil else { fail("应用音频转换失败：\(error?.localizedDescription ?? "未知错误")"); return }
            guard converted.frameLength > 0 else { return }
            output = converted
        }
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
            fail("识别处理速度不足，请暂停后重试。")
        }
    }
}
