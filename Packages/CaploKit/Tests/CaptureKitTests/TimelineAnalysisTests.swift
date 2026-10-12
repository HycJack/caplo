import Foundation
import AVFoundation
import Testing
import ProjectKit
@testable import ExportKit

/// 波形代理：10 毫秒精度、音轨相对片段的起始偏移对齐、金字塔任意区间峰值。
@Test func waveformPeaksAlignToSegmentOffsetAtTenMillisecondResolution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "波形精度")
    // 2 秒立体声：0.50–0.75 秒是幅度 0.5 的 1 kHz 正弦，其余静音；音轨相对片段晚 0.30 秒开始。
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
    buffer.frameLength = buffer.frameCapacity
    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for index in 0..<96_000 {
            let time = Double(index) / 48_000
            channels[channel][index] = time >= 0.5 && time < 0.75 ? Float(sin(time * 1000 * 2 * .pi)) * 0.5 : 0
        }
    }
    let path = "Media/system.caf"
    let file = try AVAudioFile(forWriting: url.appendingPathComponent(path), settings: format.settings)
    try file.write(from: buffer)
    var document = try ProjectStorage.load(url)
    var segment = SegmentRecord(id: 0, duration: 2.5, files: [.systemAudio: path])
    segment.mediaOffsets = [.systemAudio: 0.3]
    document.segments = [segment]

    let analysis = try await TimelineAnalysis.load(url: url, document: document)
    #expect(analysis.microphone.isEmpty)
    #expect(analysis.system.count == 250)
    // 声音落在工程时间 0.80–1.05 秒：之前与之后的格子安静，之内的格子接近 0.5（边界两格不计）。
    #expect(analysis.system[0..<79].allSatisfy { $0 < 0.001 })
    #expect(analysis.system[81..<104].allSatisfy { $0 > 0.4 && $0 <= 0.51 })
    #expect(analysis.system[106..<250].allSatisfy { $0 < 0.001 })
    #expect(analysis.systemPeak(from: 0, to: 0.79) < 0.001)
    #expect(analysis.systemPeak(from: 0.81, to: 0.82) > 0.4)
    #expect(analysis.systemPeak(from: 0.815, to: 0.816) > 0.4)
    #expect(analysis.systemPeak(from: 0, to: 2.5) > 0.4)
    #expect(analysis.systemPeak(from: 1.06, to: 2.5) < 0.001)
    #expect(analysis.microphonePeak(from: 0, to: 2.5) == 0)

    // 第二次读命中工程内的峰值缓存，结果一致；另一条声音的文件丢了只空出它自己，这一条照常有波形。
    document.segments[0].files[.microphone] = "Media/missing.caf"
    let again = try await TimelineAnalysis.load(url: url, document: document)
    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Cache/Peaks/system.peaks").path), "峰值没有缓存")
    #expect(again.system == analysis.system && again.microphone.isEmpty, "一个文件缺失让整条波形都没了")
}


/// 去除静音：够长的停顿两头留边后才剪，短停顿不动，贴着片尾的停顿剪到底；静音的轨不算数。
@Test func silenceDetectorFindsLongPausesAndLeavesPaddingAroundSpeech() throws {
    // 10 秒麦克风：0–2、5–6、6.5–8 秒有声，2–5 秒长停顿，6–6.5 秒短停顿，8 秒起一直安静到结尾。
    let peaks = (0..<1000).map { bin -> Float in
        let time = Double(bin) / 100
        return (time < 2 || (time >= 5 && time < 6) || (time >= 6.5 && time < 8)) ? 0.3 : 0.001
    }
    let analysis = TimelineAnalysis(microphone: peaks)
    var edit = VideoEdit(duration: 10)
    edit.materializeLayers()
    // 底噪取偏安静的那一档：这里是 0.001，也就是 -60 dB；面板在它上面加余量当门槛。
    #expect(abs(SilenceDetector.noiseFloor(edit: edit, analysis: analysis) - (-60)) < 0.5)
    let ranges = SilenceDetector.ranges(edit: edit, analysis: analysis)
    #expect(ranges.count == 2)
    #expect(abs(ranges[0].lowerBound - 2.15) < 0.011 && abs(ranges[0].upperBound - 4.85) < 0.011)
    #expect(abs(ranges[1].lowerBound - 8.15) < 0.011 && abs(ranges[1].upperBound - 10) < 0.001)
    var muted = edit; muted.audio.muted = [.microphone]
    #expect(SilenceDetector.ranges(edit: muted, analysis: analysis).isEmpty)
    // 检测出来的区间交给剪除：成片正好短了这么多，剩下的每一格都不在长停顿里。
    let removed = edit.cutTimelineRanges(ranges)
    try edit.validate(sourceDuration: 10)
    #expect(abs(edit.duration - (10 - removed)) < 0.001 && abs(removed - 4.55) < 0.03)
    #expect(SilenceDetector.ranges(edit: edit, analysis: analysis).isEmpty, "剪完还能再检出停顿")
}
