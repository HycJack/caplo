import Foundation
import Testing
@testable import EditingCore

/// 音乐轨的核心规则：不延长成片、拖边受文件长度限制、循环取模、只改音量不算素材变化、旧工程照常打开。
@Test func musicBlocksStayInsideThePictureAndWrapWhenLooping() throws {
    var edit = VideoEdit(duration: 10)
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    let added = edit.addMusic(MusicSource(file: "Media/Music/a.m4a", length: 4, name: "曲子"), at: 2)
    let id = try #require(added)
    func clip() -> VideoClip { edit.mediaClips(.music).first { $0.id == id }! }
    // 音乐比剩下的成片短：放到文件结尾为止；成片长度不变，行排在最下面。
    #expect(clip().timelineStart == 2 && clip().duration == 4 && edit.duration == 10)
    #expect(edit.timelineRows.last == [id])
    try edit.validate(sourceDuration: 10)

    // 不循环：右缘最多到文件结尾，左缘最多拉回文件开头。
    edit.dragMedia(.music, id: id, edge: .trailing, delta: 5, sourceDuration: 10)
    #expect(clip().duration == 4)
    edit.dragMedia(.music, id: id, edge: .leading, delta: 1, sourceDuration: 10)
    #expect(clip().timelineStart == 3 && clip().sourceStart == 1 && clip().duration == 3)
    edit.dragMedia(.music, id: id, edge: .leading, delta: -5, sourceDuration: 10)
    #expect(clip().timelineStart == 2 && clip().sourceStart == 0)

    // 循环：右缘可以拖过文件长度，但不超过成片结尾；切在第二遍里，后半段从文件对应位置接着放。
    var values = edit.musicClips!; values[0].music?.loops = true; values[0].music?.fadeIn = 1; values[0].music?.fadeOut = 1; edit.musicClips = values
    edit.dragMedia(.music, id: id, edge: .trailing, delta: 50, sourceDuration: 10)
    #expect(clip().duration == 8)
    let split = edit.splitMedia(.music, id: id, at: 7)
    let tail = try #require(split)
    let second = try #require(edit.mediaClips(.music).first { $0.id == tail })
    #expect(abs(second.sourceStart - 1) < 0.0001 && second.duration == 3)
    #expect(clip().music?.fadeOut == 0 && second.music?.fadeIn == 0 && second.music?.fadeOut == 1)
    try edit.validate(sourceDuration: 10)

    // 整块平移不出成片；画面变短后伸出去的一截裁掉、整块在外面的去掉。
    edit.dragMedia(.music, id: tail, edge: .body, delta: 100, sourceDuration: 10)
    #expect(edit.mediaClips(.music).first { $0.id == tail }?.timelineStart == 7)
    edit.clips[0].duration = 6
    edit.constrainMusic()
    #expect(edit.mediaClips(.music).map(\.id) == [id] && clip().duration == 4 && edit.duration == 6)

    // 音量、淡入淡出只换混音参数；循环与位置才算素材变化。音乐的任何改动都不算画面变化。
    var louder = edit; louder.musicClips![0].music?.volume = 1; louder.musicClips![0].music?.fadeIn = 2
    #expect(louder.hasSameMedia(as: edit) && louder.gainSignature != edit.gainSignature && !louder.differsVisually(from: edit))
    var moved = edit; moved.musicClips![0].timelineStart = 0
    #expect(!moved.hasSameMedia(as: edit) && !moved.differsVisually(from: edit))

    // 存取往返；没有音乐字段的旧工程照常解码。
    let decoded = try JSONDecoder().decode(VideoEdit.self, from: try JSONEncoder().encode(edit))
    #expect(decoded == edit)
    var plain = edit; plain.setMediaClips(.music, [])
    let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
    #expect(plain.musicClips == nil && !text.contains("music"))
    // 超出文件结尾又没开循环的块是坏数据。
    var broken = edit; broken.musicClips![0].music?.loops = false; broken.musicClips![0].sourceStart = 3
    #expect(throws: EditError.self) { try broken.validate(sourceDuration: 10) }
}
