import Foundation

/// 音乐块引用的音频文件，以及这一块怎么放：音量、淡入淡出、是否循环。
///
/// 音乐轨复用 `VideoClip` 与素材块的全部时间线机制（拖动、切开、复制、换行），区别只在"源"：
/// 录制素材共用一条连续的源时间，音乐块的 `sourceStart` 则是它自己这个文件里的时刻。
/// 块内第 t 秒放的是文件的 `sourceStart + t`；开了循环就对文件总长取模，没开则不允许超出文件结尾。
public struct MusicSource: Codable, Equatable, Sendable {
    /// 工程内相对路径，限定在 `Media/Music/` 下。
    public var file: String
    /// 文件总长（秒），导入时量好；拖边与循环都按它算，不必每次去读文件。
    public var length: Double
    /// 原文件名（不含扩展名），做块的默认名称。
    public var name: String?
    public var volume: Float = 0.5
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    public var loops = false

    public init(file: String, length: Double, name: String? = nil) { self.file = file; self.length = length; self.name = name }

    public static let maximumFade = 10.0

    var isValid: Bool {
        file.hasPrefix("Media/Music/") && !file.contains("..") && length.isFinite && length > 0
            && volume.isFinite && (0...1).contains(volume)
            && fadeIn.isFinite && (0...Self.maximumFade).contains(fadeIn) && fadeOut.isFinite && (0...Self.maximumFade).contains(fadeOut)
    }

    /// 这一块实际用的淡入、淡出时长：两段加起来不超过块长，超了就按比例压短。
    public func fades(in duration: Double) -> (fadeIn: Double, fadeOut: Double) {
        let total = fadeIn + fadeOut
        guard total > duration, total > 0 else { return (fadeIn, fadeOut) }
        return (fadeIn * duration / total, fadeOut * duration / total)
    }
}

extension VideoEdit {
    /// 音乐块上限：防损坏的工程文件拖垮合成，正常使用远到不了。
    public static let musicLimit = 500

    var validMusic: Bool {
        guard let musicClips else { return true }
        guard musicClips.count <= Self.musicLimit, Set(musicClips.map(\.id)).count == musicClips.count else { return false }
        return musicClips.allSatisfy { clip in
            guard let music = clip.music, music.isValid, let start = clip.timelineStart, start.isFinite, start >= 0,
                  clip.duration.isFinite, clip.duration >= 1.0 / 60, clip.sourceStart.isFinite, clip.sourceStart >= 0, clip.sourceStart < music.length else { return false }
            return music.loops || clip.sourceStart + clip.duration <= music.length + 0.001
        }
    }

    /// 比较素材用的音乐列表：音量与淡入淡出只改混音参数，抹掉；块的增删、位置、长短、循环才算素材变化。
    static func musicShape(_ values: [VideoClip]?) -> [VideoClip] {
        (values ?? []).map { clip in
            var copy = clip
            copy.music?.volume = 0; copy.music?.fadeIn = 0; copy.music?.fadeOut = 0; copy.music?.name = nil; copy.title = nil
            return copy
        }
    }

    /// 加一块音乐：从 `time` 起，放到文件结尾或成片结尾为止（哪个先到算哪个）。返回新块的 ID；成片上放不下时返回 nil。
    @discardableResult public mutating func addMusic(_ source: MusicSource, at time: Double) -> UUID? {
        let limit = duration
        guard source.isValid, time.isFinite, limit - max(0, time) >= Self.minimumClipDuration else { return nil }
        var clip = VideoClip(sourceStart: 0, duration: min(source.length, limit - max(0, time)))
        clip.timelineStart = max(0, time); clip.music = source
        guard clip.duration >= 1.0 / 60 else { return nil }
        // 层序里追加在最后：音乐行排在时间线最下面。
        if layerOrder != nil { layerOrder = orderedLayerIDs + [clip.id] }
        setMediaClips(.music, (musicClips ?? []) + [clip])
        return clip.id
    }

    /// 拖音乐块。整块平移不出成片范围；左缘最多拉回文件开头（循环的块可以一直拉到时间线起点）；
    /// 右缘最多到文件结尾（循环的块不受此限）且不超过成片结尾。
    mutating func dragMusic(id: UUID, edge: FocusDragEdge, delta: Double) {
        guard var values = musicClips, let number = values.firstIndex(where: { $0.id == id }), let music = values[number].music else { return }
        var clip = values[number]
        let start = clip.timelineStart ?? 0, minimum = min(Self.minimumClipDuration, clip.duration), limit = duration
        switch edge {
        case .body:
            clip.timelineStart = min(max(0, limit - clip.duration), max(0, start + delta))
        case .leading:
            let room = music.loops ? start : min(start, clip.sourceStart)
            let change = min(clip.duration - minimum, max(-room, delta))
            clip.timelineStart = start + change; clip.duration -= change
            var source = (clip.sourceStart + change).truncatingRemainder(dividingBy: music.length)
            if source < 0 { source += music.length }
            clip.sourceStart = min(source, music.length - 0.00001)
        case .trailing:
            let longest = min(max(minimum, limit - start), music.loops ? .infinity : music.length - clip.sourceStart)
            clip.duration = min(longest, max(minimum, clip.duration + delta))
        }
        values[number] = clip; setMediaClips(.music, values)
    }

    /// 音乐不延长成片：画面变短之后，伸出成片结尾的那一截裁掉，整块都在结尾之外的去掉。
    public mutating func constrainMusic() {
        guard let musicClips, !musicClips.isEmpty else { return }
        let limit = duration
        var values = musicClips.filter { ($0.timelineStart ?? 0) <= limit - 1.0 / 60 }
        for number in values.indices {
            values[number].duration = min(values[number].duration, limit - (values[number].timelineStart ?? 0))
            // 关掉循环之后，超出文件结尾的那一截也收回来。
            if let music = values[number].music, !music.loops { values[number].duration = min(values[number].duration, max(1.0 / 60, music.length - values[number].sourceStart)) }
        }
        if values != musicClips { setMediaClips(.music, values) }
    }
}
