import AVFoundation
import Testing
import ProjectKit
import ExportKit
import EditingCore
@testable import CaptureKit

/// 导入视频与音乐走真实的复制、合成与导出：导入的视频成为独立的一份素材接在后面，拖边不串进隔壁素材；
/// 音乐按音量、淡入、循环进到成片里，且不延长成片。
@Test @MainActor func importedVideoAndMusicReachTheExport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func record(_ name: String, width: Int, height: Int, seconds: Double) async throws -> URL {
        let url = try ProjectStorage.create(in: root, name: name)
        let writer = SegmentedCaptureWriter(project: url, width: width, height: height, systemAudio: true, microphone: false, onStarted: {}, onFailure: { _ in })
        try await onQueue(writer) {
            let start = CMTime(seconds: 10, preferredTimescale: 600)
            writer.ingest(try makeFrame(at: start, width: width, height: height), role: .screen)
            writer.ingest(try makeAudio(at: start, duration: seconds, channels: 2), role: .systemAudio)
        }
        try await writer.finish(at: CMTime(seconds: 10 + seconds, preferredTimescale: 600))
        try ProjectStorage.complete(url)
        return url
    }
    // 工程本身 1 秒；另一份 2 秒的录制拿来当"外面的视频"和"外面的音乐"。
    let url = try await record("主工程", width: 320, height: 180, seconds: 1)
    let other = try await record("外部素材", width: 640, height: 360, seconds: 2)
    let outside = try ProjectStorage.load(other).segments[0]
    let video = try ProjectStorage.mediaURL(outside.files[.screen]!, in: other)
    let song = try ProjectStorage.mediaURL(outside.files[.systemAudio]!, in: other)

    let imported = try await MediaImport.appendVideo(video, to: url)
    let document = imported.document
    #expect(document.segments.count == 2 && document.assetRanges.count == 2 && document.segments[1].asset == 1)
    #expect(abs(imported.sourceRange.lowerBound - 1) < 0.05 && abs(imported.sourceRange.upperBound - 3) < 0.1)
    #expect(imported.pixelSize == CGSize(width: 640, height: 360) && document.pixelSize(atSource: 2) == imported.pixelSize)
    #expect(!document.isImported(source: 0.5) && document.isImported(source: 2))
    #expect(try ProjectStorage.load(url).segments.count == 2)

    var edit = try EditStorage.load(in: url, document: document)
    edit.prepareLayerEditing(camera: false, system: true, microphone: false)
    let first = try #require(edit.clips.first?.id)
    // 清单变长之前建的时间线只有录制那一块；导入的接在后面。
    edit.clips[0].duration = 1; edit.clips[0].mediaDuration = nil
    let added = edit.appendImportedClip(sourceStart: imported.sourceRange.lowerBound, duration: imported.sourceRange.upperBound - imported.sourceRange.lowerBound, hasAudio: false)
    #expect(abs(edit.duration - imported.sourceRange.upperBound) < 0.001 && edit.clips.last?.cursorHidden == true)
    try edit.validate(sourceDuration: document.duration)
    // 拖边只在本素材范围内：录制的右缘拖不进导入的视频，导入视频的左缘拖不回录制里。
    var dragged = edit
    let own = document.assetRange(containing: 0)
    dragged.dragMedia(.screen, id: first, edge: .trailing, delta: 1, sourceDuration: own.upperBound, sourceFloor: own.lowerBound)
    #expect(dragged.clips[0].playableDuration <= own.upperBound + 0.0001)
    let theirs = document.assetRange(containing: imported.sourceRange.lowerBound)
    dragged.dragMedia(.screen, id: added, edge: .leading, delta: -0.5, sourceDuration: theirs.upperBound, sourceFloor: theirs.lowerBound)
    #expect(dragged.clips.first { $0.id == added }?.sourceStart == theirs.lowerBound)

    // 音乐：2 秒的文件循环铺满 3 秒的成片，带 1 秒淡入；录制自己的声音关掉，成片里听到的只有音乐。
    var music = try await MediaImport.importMusic(song, into: url)
    #expect(abs(music.length - 2) < 0.1 && music.file.hasPrefix("Media/Music/"))
    music.loops = true; music.volume = 1; music.fadeIn = 1
    let addedMusic = edit.addMusic(music, at: 0)
    let musicID = try #require(addedMusic)
    edit.dragMedia(.music, id: musicID, edge: .trailing, delta: 10, sourceDuration: 0)
    edit.audio.system = 0
    try edit.validate(sourceDuration: document.duration)
    let (composition, _) = try await ProjectMedia.compose(url: url, document: document, levels: edit.audio, edit: edit)
    #expect(abs(composition.duration.seconds - edit.duration) < 0.02)
    #expect(composition.tracks(withMediaType: .video).count == 2, "尺寸不同的导入视频应另开一条解码轨")
    #expect(composition.track(withTrackID: 200_000) != nil, "音乐没有进合成")

    func windows(_ edit: VideoEdit, name: String) async throws -> [Double] {
        let destination = root.appendingPathComponent(name + ".mp4")
        try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: destination, edit: edit) { _ in }
        let asset = AVURLAsset(url: destination)
        #expect(abs(try await asset.load(.duration).seconds - edit.duration) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000])
        reader.add(output); #expect(reader.startReading())
        // 每 0.5 秒一格的均方根。
        var energy = [Double](repeating: 0, count: 8), count = [Int](repeating: 0, count: 8)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let base = sample.presentationTimeStamp.seconds
            for (index, value) in values.enumerated() {
                let slot = Int((base + Double(index) / 48_000) / 0.5)
                guard slot >= 0, slot < 8 else { continue }
                energy[slot] += Double(value * value); count[slot] += 1
            }
        }
        #expect(reader.status == .completed)
        return zip(energy, count).map { $1 > 0 ? sqrt($0 / Double($1)) : 0 }
    }
    let looped = try await windows(edit, name: "looped")
    // 淡入：第一格明显比满音量的一格轻；文件 2 秒处循环回头，2.5 秒那一格仍然有声。
    #expect(looped[3] > 0.05 && looped[0] < looped[3] * 0.5, "淡入没有生效：\(looped)")
    #expect(looped[5] > 0.05, "循环的第二遍没有声音：\(looped)")
    // 关掉循环：块收回到文件长度，2 秒之后没有音乐。
    var once = edit
    once.musicClips![0].music?.loops = false
    once.constrainMusic()
    #expect(abs(once.musicClips![0].duration - music.length) < 0.001)
    let single = try await windows(once, name: "once")
    #expect(single[3] > 0.05 && single[5] < 0.005, "不循环时文件结尾之后还有声音：\(single)")

    // 存盘往返：导入的片段、音乐块都在。
    try EditStorage.save(edit, in: url, document: document)
    #expect(try EditStorage.load(in: url, document: document).musicClips == edit.musicClips)
}

/// 用一个视频新建工程：它是工程本来的素材，没有指针数据，能直接打开编辑。
@Test @MainActor func aProjectCanBeCreatedFromAVideo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try ProjectStorage.create(in: root, name: "来源")
    let writer = SegmentedCaptureWriter(project: source, width: 640, height: 360, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: CMTime(seconds: 5, preferredTimescale: 600), width: 640, height: 360), role: .screen) }
    try await writer.finish(at: CMTime(seconds: 7, preferredTimescale: 600))
    let video = try ProjectStorage.mediaURL(try ProjectStorage.load(source).segments[0].files[.screen]!, in: source)
    let library = root.appendingPathComponent("库")
    let project = try await MediaImport.createProject(from: video, in: library)
    let document = try ProjectStorage.load(project)
    #expect(document.state == .completed && document.segments.count == 1 && document.segments[0].asset == nil)
    #expect(document.capture?.pixelSize == CGSize(width: 640, height: 360) && document.capture?.pointerEnabled == false)
    let edit = try EditStorage.load(in: project, document: document)
    #expect(edit.pointer == nil && edit.focuses.isEmpty && abs(edit.duration - document.duration) < 0.001)
    let (composition, _) = try await ProjectMedia.compose(url: project, document: document, levels: edit.audio, edit: edit)
    #expect(abs(composition.duration.seconds - 2) < 0.1)
    // 不是视频的文件拒绝导入，也不留下半截工程。
    let junk = root.appendingPathComponent("junk.mov"); try Data("不是视频".utf8).write(to: junk)
    await #expect(throws: (any Error).self) { _ = try await MediaImport.createProject(from: junk, in: library) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).count == 1)
}
