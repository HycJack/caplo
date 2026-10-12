import Foundation
import ImageIO
import CoreGraphics
import Testing
import EditingCore
@testable import ProjectKit

@Test func unsupportedEditFileRemainsUntouched() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "未知编辑格式")
    var edit = VideoEdit(duration: 5); edit.schemaVersion = 100
    let data = try JSONEncoder().encode(edit), path = url.appendingPathComponent("edits.json")
    try data.write(to: path)
    #expect(throws: EditError.self) { try EditStorage.load(in: url, document: ProjectDocument(name: "测试")) }
    #expect(try Data(contentsOf: path) == data)
}

/// 升版本号之前要留一份旧文件：升上去之后旧版 Caplo 打不开，用户退回去只能靠这份备份。
/// 叠加层已经不再升版本了，现在唯一的一次升级是"第一次进图层编辑"把 5 变成 6。
@Test func bumpingTheSchemaKeepsABackupOfThePreviousFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "版本备份")
    var document = ProjectDocument(name: "版本备份")
    document.segments = [SegmentRecord(id: 0, duration: 8, files: [:])]

    var edit = VideoEdit(duration: 8)
    try EditStorage.save(edit, in: url, document: document)
    #expect(edit.schemaVersion == 5)

    // 加遮罩不再改版本号，所以也不该产生备份。
    edit.addMask(MaskSegment(start: 0, duration: 2, x: 0.5, y: 0.5, width: 0.2, height: 0.1))
    try EditStorage.save(edit, in: url, document: document)
    let backup = url.appendingPathComponent("Recovery/edits-v5.json")
    #expect(edit.schemaVersion == 5)
    #expect(!FileManager.default.fileExists(atPath: backup.path), "版本没变却留了备份")

    // 第一次进图层编辑：5 → 6，这时才留一份。
    edit.prepareLayerEditing(camera: false, system: false, microphone: false)
    #expect(edit.schemaVersion == VideoEdit.writtenSchemaVersion)
    try EditStorage.save(edit, in: url, document: document)
    #expect(FileManager.default.fileExists(atPath: backup.path), "升到 6 之前没有留备份")
    let saved = try JSONSerialization.jsonObject(with: try Data(contentsOf: backup)) as? [String: Any]
    #expect(saved?["schemaVersion"] as? Int == 5)

    // 再存一次不会覆盖已有的备份。
    edit.addText(TextSegment(start: 0, duration: 2, text: "标题"))
    try EditStorage.save(edit, in: url, document: document)
    let again = try JSONSerialization.jsonObject(with: try Data(contentsOf: backup)) as? [String: Any]
    #expect(again?["schemaVersion"] as? Int == 5, "旧备份被后来的保存覆盖了")

    // 读回来内容一致。
    let loaded = try EditStorage.load(in: url, document: document)
    #expect(loaded.maskList.count == 1 && loaded.textList.count == 1)
}


/// "新录制的默认效果"只决定新工程的起点：关掉自动聚焦时不生成镜头，关掉光标效果时用原样的光标，
/// 默认布局整套带上；已经有编辑数据的工程不受这些设置影响。
@Test func newProjectDefaultsOnlyShapeTheStartingPoint() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try ProjectStorage.create(in: root, name: "默认效果")
    let path = "Media/000000-screen.mov"
    try Data([1]).write(to: url.appendingPathComponent(path))
    var record = SegmentRecord(id: 0, duration: 8, files: [.screen: path])
    record.eventsPath = "Events/000000.json"
    var samples = (0..<160).map { PointerSample(time: Double($0) / 20, x: 0.2 + 0.003 * Double($0), y: 0.5, kind: .move) }
    samples += [PointerSample(time: 2, x: 0.3, y: 0.5, kind: .click), PointerSample(time: 5, x: 0.6, y: 0.5, kind: .click)]
    try JSONEncoder().encode(samples).write(to: url.appendingPathComponent(record.eventsPath!))
    try ProjectStorage.commit(record, to: url)
    var document = try ProjectStorage.load(url)
    document.capture = CaptureMetadata(desktopBounds: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelSize: CGSize(width: 1280, height: 800), pointPixelScale: 1, pointerEnabled: true)

    // 不传设置：与以前一样，自动聚焦开、推荐的光标效果、内置布局。
    let usual = try EditStorage.load(in: url, document: document)
    #expect(usual.automaticFocus && !usual.focuses.isEmpty && usual.pointer == .recommended && usual.layout == CanvasLayout().synced(to: document))

    var plain = NewProjectDefaults()
    plain.automaticFocus = false; plain.cursorEffects = false
    var layout = CanvasLayout(); layout.padding = 0; layout.cornerRadius = 0; layout.ratio = .widescreen
    plain.layout = layout
    let edit = try EditStorage.load(in: url, document: document, defaults: plain)
    #expect(!edit.automaticFocus && edit.focuses.isEmpty)
    #expect(SceneEvaluator.focus(edit: edit, time: 2.5).scale == 1 && SceneEvaluator.focus(edit: usual, time: 2.5).scale > 1.2)
    let pointer = try #require(edit.pointer)
    #expect(!pointer.clicksVisible && pointer.smoothing == 0 && pointer.bounce == 0 && pointer.motionBlur == 0 && pointer.cursorScale == 0.5)
    #expect(edit.layout.padding == 0 && edit.layout.cornerRadius == 0 && edit.layout.ratio == .widescreen)
    try edit.validate(sourceDuration: document.duration)

    // 存过之后再打开：设置再怎么变，这份工程还是它自己的样子。
    try EditStorage.save(edit, in: url, document: document)
    #expect(try EditStorage.load(in: url, document: document, defaults: NewProjectDefaults()) == edit)
}

private extension CanvasLayout {
    /// 新工程读出来的布局会按录制尺寸同步一次"原始"比例。
    func synced(to document: ProjectDocument) -> CanvasLayout { var copy = self; copy.syncOriginalAspect(capture: document.capture?.pixelSize); return copy }
}
