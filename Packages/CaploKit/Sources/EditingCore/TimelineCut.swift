import Foundation

/// 剪掉成片上的一段时间并合拢（去除静音用）。
///
/// 普通的"删除片段"会在原处留下空白；这里要的是"抽掉这一段、后面的接上来"。做法与插入 / 删除卡片同一套：
/// 先在区间两端把各条轨切开，删掉落在区间里的块，再把区间之后的一切整体前移。
/// 遮罩、文字、字幕、按键、光标存的是素材时间，素材一挪它们的投影自然跟着走，不用动。
extension VideoEdit {
    /// `ranges` 是成片时间；重叠的区间只取靠后的那个，卡片不动。返回实际剪掉的总时长。
    @discardableResult
    public mutating func cutTimelineRanges(_ ranges: [Range<Double>]) -> Double {
        let total = duration
        // 从后往前剪：前面的区间还没被后面的前移影响，不用边剪边换算。
        let ordered = ranges.filter { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound >= 0
            && $0.upperBound <= total + 0.0001 && $0.upperBound - $0.lowerBound >= 1.0 / 60 }
            .sorted { $0.lowerBound > $1.lowerBound }
        guard !ordered.isEmpty else { return 0 }
        materializeLayers()
        var removed = 0.0, limit = Double.infinity
        for range in ordered where range.upperBound <= limit + 0.0001 {
            limit = range.lowerBound
            let a = range.lowerBound, b = range.upperBound
            // 先切后端再切前端：前端那一刀落在后端切出来的头块上。
            splitTracks(at: b)
            splitTracks(at: a)
            var gone = Set<UUID>()
            for role in [TimelineMedia.screen, .camera, .system, .microphone] where ownsTrack(role) {
                let values = role == .screen ? clips : mediaClips(role)
                let kept = values.filter { clip in
                    guard clip.card == nil, let start = clip.timelineStart,
                          start >= a - 0.0001, start + clip.duration <= b + 0.0001 else { return true }
                    gone.insert(clip.id); return false
                }
                guard kept.count != values.count else { continue }
                if role == .screen { clips = kept } else { setMediaClips(role, kept) }
            }
            // 镜头：整个落在区间里的删掉；只有一头伸进区间的裁到区间边上（保留运镜相位）；
            // 横跨整个区间的留给下面的前移去缩短，它会连运镜路径一起处理。
            focuses = focuses.compactMap { focus in
                guard let start = focus.timelineStart else { return focus }
                let end = start + focus.duration
                if end <= a + 0.0001 || start >= b - 0.0001 { return focus }
                if start >= a - 0.0001, end <= b + 0.0001 { gone.insert(focus.id); return nil }
                if start < a, end > b { return focus }
                let lower = start < a ? start : b, upper = start < a ? a : end
                guard upper - lower >= 1.0 / 30 else { gone.insert(focus.id); return nil }
                var copy = focus
                copy.timelineStart = lower; copy.duration = upper - lower
                if focus.transitionOffset == nil && focus.transitionDuration == nil {
                    copy.transitionOffset = lower - start; copy.transitionDuration = focus.duration
                } else if let offset = focus.transitionOffset, focus.transitionDuration != nil {
                    copy.transitionOffset = offset + lower - start
                }
                return copy
            }
            layerOrder?.removeAll { gone.contains($0) }
            rippleTimeline(from: b, by: a - b)
            removed += b - a
        }
        constrainTimelineFocuses()
        normalizeTimelineRows()
        normalizeSchemaVersion(layered: true)
        return removed
    }
}
