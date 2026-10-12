import AVFoundation
import AppKit
import CoreImage
import Testing
import EditingCore
import ProjectKit
import ExportKit
import RenderKit
@testable import CaptureKit

/// 对效果覆盖的像素单独比较，避免整幅画面平均值掩盖小光标或点击圆环完全丢失。
@Test(arguments: [0, 1, 2]) @MainActor func pointerExportMatchesPreviewAtAffectedPixelsAfterTrimAndZoom(mode: Int) async throws {
    let enhanced = mode > 0
    let native = mode == 2 ? NativeCursorCapture.capture(NSCursor.crosshair) : nil
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "光标导出")
    var initial = try ProjectStorage.load(url)
    initial.capture = CaptureMetadata(desktopBounds: CGRect(x: 0, y: 0, width: 320, height: 180), pixelSize: CGSize(width: 320, height: 180), pointPixelScale: 1, pointerEnabled: true)
    initial.capture?.cursorEmbedded = false
    try ProjectStorage.save(initial, to: url)
    let writer = SegmentedCaptureWriter(project: url, width: 320, height: 180, systemAudio: false, microphone: false, onStarted: {}, onFailure: { _ in })
    try await onQueue(writer) { writer.ingest(try makeFrame(at: CMTime(seconds: 10, preferredTimescale: 600)), role: .screen) }
    for index in 0..<60 {
        let time = Double(index) / 30
        var sample = PointerSample(time: 10 + time, x: 0.6 + (enhanced ? sin(time * 3) * 0.12 : 0), y: 0.5, kind: .move)
        sample.cursorAssetID = native?.id
        writer.appendPointer(sample, cursor: native)
    }
    writer.appendPointer(PointerSample(time: 10.25, x: 0.6, y: 0.5, kind: .click))
    if mode == 0 {
        // 按键与指针事件走同一条归档路径：一个在片段开头之前（剪掉的那段里），一个在播放头前 0.1 秒。
        writer.appendKey(KeyPress(time: 10.05, keyCode: 0, modifiers: [], label: "a"))
        writer.appendKey(KeyPress(time: 10.3, keyCode: 8, modifiers: [.command], label: "c"))
    }
    try await writer.finish(at: CMTime(seconds: 12, preferredTimescale: 600))
    let document = try ProjectStorage.load(url)
    var edit = try EditStorage.load(in: url, document: document)
    #expect(edit.pointer != nil)
    edit.pointer?.cursorScale = 2; edit.pointer?.clickScale = 1.5; edit.pointer?.tint = .yellow
    if enhanced {
        edit.pointer?.style = .tahoe; edit.pointer?.smoothing = 0.5; edit.pointer?.bounce = 0.2
        edit.pointer?.motionBlur = 0.4; edit.pointer?.sway = 0.3; edit.pointer?.clickEffect = .echo
    }
    if mode == 2 { edit.pointer?.style = .captured; #expect(native != nil) }
    edit.clips = [VideoClip(sourceStart: 0.1, duration: 1.5)]
    edit.focuses = [FocusSegment(start: 0, duration: 2, x: 0.6, y: 0.5, scale: 1.8)]
    let target = root.appendingPathComponent("pointer.mp4")
    try await ProjectMedia.export(url: url, document: document, levels: edit.audio, destination: target, edit: edit) { _ in }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let exported = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
    let renderer = EditorPreviewRenderer()
    let preview = try await renderer.render(url: url, document: document, edit: edit, time: 0.3)
    var plain = edit; plain.pointer = nil
    let baseline = try await renderer.render(url: url, document: document, edit: plain, time: 0.3)
    let size = CGSize(width: 1280, height: 720), context = CIContext()
    func pixels(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        let input = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: size.width / Double(image.width), y: size.height / Double(image.height)))
        context.render(input, toBitmap: &result, rowBytes: 1280 * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return result
    }
    let expected = pixels(preview), base = pixels(baseline), actual = pixels(exported)
    var affected = 0, matched = 0
    for index in stride(from: 0, to: expected.count, by: 4) {
        let change = (0..<3).map { abs(Int(expected[index + $0]) - Int(base[index + $0])) }.max()!
        if change > 45 {
            affected += 1
            if (0..<3).allSatisfy({ abs(Int(expected[index + $0]) - Int(actual[index + $0])) < 30 }) { matched += 1 }
        }
    }
    #expect(affected > 500)
    #expect(Double(matched) / Double(max(1, affected)) > 0.85)
    if mode == 0 {
        // 自定义点击颜色：存盘读回不丢，且画面真的换成了自定义色（绿），不是仍按预设黄色画。
        var custom = edit; custom.pointer?.customTint = "#00FF00"
        try EditStorage.save(custom, in: url, document: document)
        #expect(try EditStorage.load(in: url, document: document).pointer?.customTint == "#00FF00")
        let green = pixels(try await renderer.render(url: url, document: document, edit: custom, time: 0.3))
        var greener = 0
        for index in stride(from: 0, to: expected.count, by: 4)
            where (0..<3).map({ abs(Int(expected[index + $0]) - Int(base[index + $0])) }).max()! > 45 {
            // 黄色点击环红分量高；换成绿色后同一位置红分量应明显下降、绿分量占优。
            if Int(green[index]) + 40 < Int(expected[index]), green[index + 1] > green[index] { greener += 1 }
        }
        #expect(greener > 100, "自定义点击颜色没有生效")
    }
    let item = try await ProjectMedia.playerItem(url: url, document: document, levels: edit.audio, edit: edit)
    let first = try #require(item.videoComposition?.instructions.first as? SceneInstruction)
    #expect(first.pointerFrame(at: 0.3).position != nil && first.pointerFrame(at: 0.3).clicks.count == 1)
    if mode == 0 {
        // 按键显示：录下的快捷键按素材时间落在成片上；剪掉的那段里按的键不漏出来；关掉就不画。
        #expect(document.segments.first?.keysPath != nil)
        #expect(first.keyFrame(at: 0.3)?.groups == [["⌘", "C"]])
        #expect(first.keyFrame(at: 0.05) == nil)
        // 示例键帽：只在这一刻没有真按键时出现，而且这个标记不存盘。
        var sampled = KeystrokeStyle(); sampled.sample = true
        #expect(first.pointers.keys.frame(at: 0.05, timeline: first.timeline, style: sampled)?.groups == KeystrokeStyle.sampleGroups)
        #expect(first.pointers.keys.frame(at: 0.3, timeline: first.timeline, style: sampled)?.groups == [["⌘", "C"]])
        #expect(try JSONDecoder().decode(KeystrokeStyle.self, from: JSONEncoder().encode(sampled)).sample == false)
        var silent = edit; silent.keystrokes = KeystrokeStyle(); silent.keystrokes?.enabled = false
        let without = pixels(try await renderer.render(url: url, document: document, edit: silent, time: 0.3))
        var keyPixels = 0, keyMatched = 0
        for index in stride(from: 0, to: expected.count, by: 4)
            where (0..<3).map({ abs(Int(expected[index + $0]) - Int(without[index + $0])) }).max()! > 45 {
            keyPixels += 1
            if (0..<3).allSatisfy({ abs(Int(expected[index + $0]) - Int(actual[index + $0])) < 30 }) { keyMatched += 1 }
        }
        #expect(keyPixels > 500, "键帽没有画到预览上")
        #expect(Double(keyMatched) / Double(max(1, keyPixels)) > 0.85, "导出的键帽与预览不一致")
        // 水印：和按键走同一个合成入口，画在右下角；存盘读回不丢，文件名带路径的图片水印被校验拒绝。
        var marked = silent; marked.watermark = Watermark(); marked.watermark?.text = "Caplo"; marked.watermark?.tone = .dark; marked.watermark?.opacity = 1
        try EditStorage.save(marked, in: url, document: document)
        #expect(try EditStorage.load(in: url, document: document).watermark?.text == "Caplo")
        let stamped = pixels(try await renderer.render(url: url, document: document, edit: marked, time: 0.3))
        var corner = 0, elsewhere = 0
        for index in stride(from: 0, to: stamped.count, by: 4) where (0..<3).map({ abs(Int(stamped[index + $0]) - Int(without[index + $0])) }).max()! > 30 {
            let pixel = index / 4, x = pixel % 1280, y = pixel / 1280
            if x > 1280 * 3 / 4, y > 720 * 3 / 4 { corner += 1 } else { elsewhere += 1 }
        }
        #expect(corner > 150 && elsewhere == 0, "水印像素：右下角 \(corner)，别处 \(elsewhere)")
        var escaping = Watermark(); escaping.kind = .image; escaping.image = "../secret.png"
        #expect(!escaping.isValid)
    }
    var hidden = edit; hidden.pointer?.cursorVisible = false; hidden.pointer?.clicksVisible = false
    try ProjectMedia.updatePresentation(item: item, previous: edit, edit: hidden)
    let changed = try #require(item.videoComposition?.instructions.first as? SceneInstruction)
    #expect(changed.pointerFrame(at: 0.3).position == nil && changed.pointerFrame(at: 0.3).clicks.isEmpty)
    await renderer.close()
}
