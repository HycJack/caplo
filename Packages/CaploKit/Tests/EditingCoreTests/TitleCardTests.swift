import Foundation
import Testing
@testable import EditingCore

/// 卡片：画面轨上自带背景与文字的一段，片头 / 章节 / 片尾用。插入时后面的一切让开，卡片上没有录屏与声音，
/// 删掉之后时间轴和片段都回到插入前的样子。
private func recording(_ duration: Double) -> VideoEdit {
    var edit = VideoEdit(duration: duration)
    edit.materializeLayers()
    return edit
}

@Test func insertingACardMakesRoomAndRemovingItRejoinsTheCut() throws {
    var edit = recording(10)
    // 源域遮罩横跨插入点：它要跟着后半段画面走，不能投影到卡片上。
    edit.addMask(MaskSegment(start: 1, duration: 4, x: 0.5, y: 0.5, width: 0.3, height: 0.2))
    let inserted = edit.insertCard(at: 4, duration: 3)
    let id = try #require(inserted)
    try edit.validate(sourceDuration: 10)
    #expect(edit.systemClips == nil && edit.microphoneClips == nil, "插卡片把跟随画面的声音拆成了单独的轨")
    #expect(abs(edit.duration - 13) < 0.001, "成片是 \(edit.duration) 秒")
    let card = try #require(edit.clips.first { $0.id == id })
    #expect(card.timelineStart == 4 && abs(card.duration - 3) < 0.001)
    // 卡片上没有源时刻：镜头、光标、遮罩都画不上去；声音轨在这一段留空。
    #expect(edit.sourceTime(at: 5) == nil)
    #expect(edit.maskSpans().allSatisfy { $0.end <= 4.001 || $0.start >= 6.999 })
    #expect(!edit.mediaClips(.system).contains { ($0.timelineStart ?? 0) < 7 && ($0.timelineStart ?? 0) + $0.duration > 4.001 })
    // 后半段画面整体后移，源起点不变。
    let tail = try #require(edit.clips.first { $0.card == nil && abs(($0.timelineStart ?? 0) - 7) < 0.001 })
    #expect(abs(tail.sourceStart - 4) < 0.001)
    // 卡片的字照常画出来，画面层在卡片正中完全淡出。
    #expect(edit.activeTexts(at: 5.5).contains { $0.id == card.card?.text.id })
    #expect(edit.stage(at: 5.5).alpha < 0.01)

    // 在卡片上加一段文字（钉在成片时间上）：删卡片时它要跟着删，不能留下来盖到前移过来的画面上。
    var onCard = TextSegment(start: 0, duration: 2, text: "卡片上的字"); onCard.timelineStart = 4.5
    edit.addText(onCard)
    edit.removeCard(id: id)
    try edit.validate(sourceDuration: 10)
    #expect(edit.text(id: onCard.id) == nil, "卡片删了，钉在卡片上的文字还在")
    #expect(abs(edit.duration - 10) < 0.001)

    // 横跨插入点的跟随镜头：插入点之后的运镜关键帧跟着卡片后移，删卡片后回到原处。
    var follow = recording(10)
    var zoom = FocusSegment(start: 2, duration: 4, x: 0.5, y: 0.5); zoom.timelineStart = 2; zoom.sampledPath = true
    zoom.path = [FocusKeyframe(time: 0, x: 0.2, y: 0.5, scale: 1.8, move: 0), FocusKeyframe(time: 3, x: 0.8, y: 0.5, scale: 1.8, move: 0)]
    follow.focuses = [zoom]
    let insertedFollow = follow.insertCard(at: 4, duration: 3)
    let followCard = try #require(insertedFollow)
    #expect(follow.focuses.first?.path?.map(\.time) == [0, 6], "插卡片后运镜没跟着后移：\(follow.focuses.first?.path?.map(\.time) ?? [])")
    follow.removeCard(id: followCard)
    #expect(follow.focuses.first?.path?.map(\.time) == [0, 3])
    // 插入时切开的口子合回去了：画面与声音都还是一整块。
    #expect(edit.clips.count == 1 && abs(edit.clips[0].duration - 10) < 0.001)
    #expect(edit.mediaClips(.system).count == 1 && edit.mediaClips(.microphone).count == 1)

    // 旧工程：声音轨与画面一一对得上（从没单独剪过）→ 打开时收回成跟随画面，单块音量挪到画面片段上；
    // 用户分离过的再打开仍是独立的；收回时音量回到画面片段。
    var legacy = recording(10)
    legacy.detachAudio(); legacy.audioDetached = nil
    legacy.systemClips?[0].systemGain = 0.5
    legacy.prepareLayerEditing(camera: false, system: true, microphone: true)
    #expect(legacy.systemClips == nil && legacy.microphoneClips == nil && legacy.clips[0].systemGain == 0.5, "没剪过的旧声音轨没有收回成跟随画面")
    legacy.detachAudio()
    legacy.prepareLayerEditing(camera: false, system: true, microphone: true)
    #expect(legacy.systemClips != nil, "分离过的声音再打开又被收回了")
    legacy.attachAudio()
    #expect(legacy.systemClips == nil && legacy.clips[0].systemGain == 0.5)
}

/// 旧版"全屏卡段"（定格片段 + 绑着它的全屏文字 + 人像定格）读取时换成卡片，成片长度与文字都不变。
@Test func legacyHoldCardsBecomeCards() throws {
    var edit = recording(10)
    let head = try #require(edit.clips.first?.id)
    let split = edit.splitMedia(.screen, id: head, at: 4)
    let tail = try #require(split)
    edit.rippleTimeline(from: 4, by: 3)
    var frozen = VideoClip(sourceStart: 4, duration: 3)
    frozen.timelineStart = 4; frozen.mediaDuration = 1.0 / 30; frozen.holdSource = head; frozen.title = "定格卡段"
    edit.clips.append(frozen)
    var still = VideoClip(sourceStart: 4, duration: 3)
    still.timelineStart = 4; still.mediaDuration = 1.0 / 30; still.holdSource = UUID()
    edit.cameraClips = (edit.cameraClips ?? []) + [still]
    var text = TextPreset.title.segment(start: 4, duration: 3)
    text.text = "第 2 章"; text.layout = .fullscreen; text.timelineStart = 4; text.holdClipID = frozen.id
    edit.addText(text)
    #expect(abs(edit.duration - 13) < 0.001)

    edit.migrateLegacyHoldCards()
    try edit.validate(sourceDuration: 10)
    #expect(abs(edit.duration - 13) < 0.001, "迁移后成片是 \(edit.duration) 秒")
    #expect(edit.textList.isEmpty)
    let card = try #require(edit.clips.first { $0.id == frozen.id }?.card)
    #expect(card.text.text == "第 2 章" && card.text.holdClipID == nil)
    #expect(edit.clips.first { $0.id == frozen.id }?.title == nil)
    #expect(!(edit.cameraClips ?? []).contains { $0.id == still.id })
    #expect(edit.clips.contains { $0.id == tail })
}

/// 去除静音用的"剪掉一段并合拢"：后面的内容前移补上，声音不被拆轨，叠加层与镜头留在各自的内容上。
@Test func cuttingTimelineRangesClosesTheGapAndKeepsEverythingOnItsContent() throws {
    var edit = recording(10)
    // 源域遮罩盖着素材 6–8 秒：剪掉前面两秒之后它应当出现在成片 4–6 秒。
    edit.addMask(MaskSegment(start: 6, duration: 2, x: 0.5, y: 0.5, width: 0.3, height: 0.2))
    func pinned(_ start: Double, _ duration: Double) -> FocusSegment {
        var focus = FocusSegment(start: start, duration: duration, x: 0.5, y: 0.5); focus.timelineStart = start; return focus
    }
    // 三个钉在成片上的镜头：尾巴伸进剪掉的区间、整个落在区间里、在区间之后。
    let trimmed = pinned(1, 2), swallowed = pinned(2.5, 1), later = pinned(5, 1)
    edit.focuses = [trimmed, swallowed, later]
    let removed = edit.cutTimelineRanges([8..<9.5, 2..<4])
    try edit.validate(sourceDuration: 10)
    #expect(abs(removed - 3.5) < 0.001 && abs(edit.duration - 6.5) < 0.001, "剪掉 \(removed) 秒，成片 \(edit.duration) 秒")
    #expect(edit.systemClips == nil && edit.microphoneClips == nil, "去静音把跟随画面的声音拆成了单独的轨")
    let clips = edit.clips.sorted { ($0.timelineStart ?? 0) < ($1.timelineStart ?? 0) }
    #expect(clips.map { ($0.timelineStart ?? -1).rounded(toPlaces: 3) } == [0, 2, 6])
    #expect(clips.map { $0.sourceStart.rounded(toPlaces: 3) } == [0, 4, 9.5])
    #expect(abs((edit.sourceTime(at: 2.5) ?? 0) - 4.5) < 0.001)
    #expect(edit.maskSpans().map { [$0.start.rounded(toPlaces: 3), $0.end.rounded(toPlaces: 3)] } == [[4, 6]])
    #expect(edit.focuses.first { $0.id == swallowed.id } == nil)
    let head = try #require(edit.focuses.first { $0.id == trimmed.id })
    #expect(abs((head.timelineStart ?? 0) - 1) < 0.001 && abs(head.duration - 1) < 0.001)
    let moved = try #require(edit.focuses.first { $0.id == later.id })
    #expect(abs((moved.timelineStart ?? 0) - 3) < 0.001 && abs(moved.duration - 1) < 0.001)
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double { let scale = pow(10, Double(places)); return (self * scale).rounded() / scale }
}
