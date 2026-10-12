import Foundation
import EditingCore

/// 找出成片里"没人说话也没有声音"的停顿，给"去除静音"用。
///
/// 按成片时间判断，而不是素材时间：声音可能已经单独剪过、挪过位置，听得到的才算数——
/// 静音的轨、音量拉到 0 的块都当作没有声音。数据来自时间线波形同一份峰值（每 10 毫秒一格）。
public enum SilenceDetector {
    public struct Options: Equatable, Sendable {
        /// 低于这个电平算安静（dBFS）。
        public var threshold = -40.0
        /// 安静持续多久才算一段停顿。
        public var minimumPause = 0.8
        /// 每段停顿两头各留这么久不剪，话音的起止不会被切掉。
        public var padding = 0.15
        /// 只按麦克风判断（系统声音里一直有背景音乐时用）；麦克风不可用时仍按全部声音。
        public var microphoneOnly = false
        public init() {}

        public static let thresholdRange = -60.0...(-20.0)
        public static let pauseRange = 0.3...5.0
    }

    /// 剪掉之后至少要留下这么长的成片，否则视为"整段都是静音"，不给剪。
    public static let minimumRemaining = 1.0

    /// 参与判断的声音轨：录到了、没静音、音量不为 0。
    public static func audibleTracks(edit: VideoEdit, analysis: TimelineAnalysis) -> [AudioTrack] {
        AudioTrack.allCases.filter { track in
            !(track == .system ? analysis.system : analysis.microphone).isEmpty && edit.audio.effectiveGain(for: track) > 0.001
        }
    }

    /// 这段录制的底噪电平（dBFS，-60…-20）：全部峰值里偏安静的那一档（第 15 百分位）。
    /// 麦克风的底噪因设备和环境差很多，"安静"的门槛按它往上加几分贝来定，比写死一个数靠谱。
    public static func noiseFloor(edit: VideoEdit, analysis: TimelineAnalysis, microphoneOnly: Bool = false) -> Double {
        var tracks = audibleTracks(edit: edit, analysis: analysis)
        if microphoneOnly, tracks.contains(.microphone) { tracks = [.microphone] }
        let count = tracks.map { ($0 == .system ? analysis.system : analysis.microphone).count }.max() ?? 0
        guard count > 0 else { return Options.thresholdRange.lowerBound }
        // 最多取两万格：两小时的录制也只排序这么多。
        let step = max(1, count / 20_000)
        var values: [Float] = []
        values.reserveCapacity(count / step + 1)
        for bin in stride(from: 0, to: count, by: step) {
            var peak: Float = 0
            for track in tracks {
                let peaks = track == .system ? analysis.system : analysis.microphone
                if bin < peaks.count { peak = max(peak, peaks[bin] * edit.audio.effectiveGain(for: track)) }
            }
            values.append(peak)
        }
        values.sort()
        let floor = Double(values[min(values.count - 1, values.count * 15 / 100)])
        return min(Options.thresholdRange.upperBound, max(Options.thresholdRange.lowerBound, 20 * log10(max(floor, 0.000_01))))
    }

    /// 可以剪掉的成片区间，按时间先后。每段都落在同一块录制画面里（不跨片段、不碰卡片），
    /// 两端离片段边缘要么对齐、要么不小于最短片段时长，剪完不会留下抓不住的碎片。
    public static func ranges(edit: VideoEdit, analysis: TimelineAnalysis, options: Options = Options()) -> [Range<Double>] {
        var tracks = audibleTracks(edit: edit, analysis: analysis)
        if options.microphoneOnly, tracks.contains(.microphone) { tracks = [.microphone] }
        let duration = edit.duration
        guard !tracks.isEmpty, duration > 0, options.threshold.isFinite, options.minimumPause.isFinite, options.padding.isFinite else { return [] }
        let rate = TimelineAnalysis.binsPerSecond
        let limit = Float(pow(10, options.threshold / 20))
        // 成片上每 10 毫秒一格：有没有听得到的声音。
        var loud = [Bool](repeating: false, count: Int((duration * rate).rounded(.up)) + 1)
        for track in tracks {
            let peaks = track == .system ? analysis.system : analysis.microphone
            let level = edit.audio.effectiveGain(for: track)
            for clip in edit.resolvedMedia(track == .system ? .system : .microphone) where clip.card == nil {
                let gain = level * clip.gain(for: track)
                guard gain > 0.001, let start = clip.timelineStart else { continue }
                let first = max(0, Int(start * rate)), last = min(loud.count, Int(((start + min(clip.duration, clip.playableDuration)) * rate).rounded(.up)))
                guard first < last else { continue }
                for bin in first..<last {
                    let source = Int((clip.sourceStart + Double(bin) / rate - start) * rate)
                    if source >= 0, source < peaks.count, peaks[source] * gain >= limit { loud[bin] = true }
                }
            }
        }
        let minimumClip = VideoEdit.minimumClipDuration
        var result: [Range<Double>] = []
        let index = TimelineIndex(clips: edit.orderedScreenClips)
        for span in index.spans where index.clips[span.index].card == nil {
            let first = Int((span.start * rate).rounded(.up)), last = min(loud.count, Int(span.end * rate))
            var bin = first
            while bin < last {
                guard !loud[bin] else { bin += 1; continue }
                var end = bin
                while end < last, !loud[end] { end += 1 }
                defer { bin = end }
                let quiet = Double(bin) / rate..<Double(end) / rate
                guard quiet.upperBound - quiet.lowerBound >= options.minimumPause else { continue }
                // 停顿贴着片段开头 / 结尾时那一头不用留边；否则留一点边，再把离边缘太近的收到边缘上。
                var lower = bin == first ? span.start : quiet.lowerBound + options.padding
                var upper = end == last ? span.end : quiet.upperBound - options.padding
                if lower - span.start < minimumClip { lower = span.start }
                if span.end - upper < minimumClip { upper = span.end }
                if upper - lower >= minimumClip { result.append(lower..<upper) }
            }
        }
        let removed = result.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        return duration - removed >= minimumRemaining ? result : []
    }
}
