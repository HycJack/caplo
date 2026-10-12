import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CaploDesignSystem
import EditingCore

/// 布局面板里的"水印"分组：一行字或一张图，固定在成片一角。默认收起。
struct WatermarkSection: View {
    let model: VideoEditorModel
    @State private var expanded: Bool
    /// "新录制也用这个水印"是否开着：开着时每次改动都同步成新工程的默认水印。
    @State private var usedForNewProjects: Bool
    private static let expandedKey = "editor.watermark.expanded"

    init(model: VideoEditorModel) {
        self.model = model
        _expanded = State(initialValue: UserDefaults.standard.object(forKey: Self.expandedKey) as? Bool ?? false)
        _usedForNewProjects = State(initialValue: Watermark.defaultForNewProjects() != nil)
    }

    private var watermark: Watermark { model.edit.watermark ?? Watermark() }
    private var shown: Bool { model.edit.watermark?.enabled == true }

    var body: some View {
        PanelSection(String(localized: "水印"), expanded: $expanded) {
            Toggle(isOn: Binding(get: { shown }, set: { value in commit { $0.enabled = value } })) {
                SettingLabel(String(localized: "显示水印"), systemImage: "seal")
            }
            .toggleStyle(StudioToggleStyle())
            if shown {
                ChipGroup(Watermark.Kind.allCases, selection: Binding(get: { watermark.kind }, set: { value in commit { $0.kind = value } })) { $0.title }
                if watermark.kind == .text {
                    TextField("例如：@你的名字", text: Binding(get: { watermark.text }, set: { value in
                        // 逐字提交会把撤销栈灌满：打字期间只改预览，停手后合成一步。
                        model.typeText { edit in
                            var next = edit.watermark ?? Watermark()
                            next.text = String(value.prefix(Watermark.textLimit))
                            edit.watermark = next
                        }
                        syncDefault()
                    }))
                    .textFieldStyle(.roundedBorder)
                    ChipGroup(Watermark.Tone.allCases, selection: Binding(get: { watermark.tone }, set: { value in commit { $0.tone = value } })) { $0.title }
                } else {
                    Button(watermark.image == nil ? "选择图片" : "更换图片") { chooseImage() }
                        .buttonStyle(StudioButtonStyle(.secondary, size: .small))
                    if watermark.image != nil, watermark.imageURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
                        PanelNote(String(localized: "水印图片找不到了，请重新选择。"))
                    }
                }
                EditorSlider(model: model, title: String(localized: "大小"), value: live(\.size), range: Watermark.sizeRange, suffix: "×", defaultValue: 1, detents: [1, 2])
                EditorFill(model: model, title: String(localized: "不透明度"), value: live(\.opacity), range: 0...1, suffix: "%", percentage: true, defaultValue: 0.7)
                // 位置在画布比例的底板上拖；水印再大也会收在画面里。
                EditorRegion(model: model, title: String(localized: "位置"), shape: .point, aspect: model.edit.layout.aspect,
                             region: Binding(get: { CGRect(x: watermark.x, y: watermark.y, width: 0, height: 0) }, set: { rect in
                                 var next = watermark
                                 next.x = min(1, max(0, rect.minX)); next.y = min(1, max(0, rect.minY))
                                 model.edit.watermark = next
                             }), defaultRegion: CGRect(x: 0.9, y: 0.92, width: 0, height: 0)) { EditorRegion.positionReadout($0.origin) }
                Toggle("新录制也用这个水印", isOn: Binding(get: { usedForNewProjects }, set: { value in
                    usedForNewProjects = value
                    Watermark.setDefaultForNewProjects(value ? watermark : nil)
                })).toggleStyle(StudioToggleStyle())
            }
        }
        .onChange(of: expanded) { _, value in UserDefaults.standard.set(value, forKey: Self.expandedKey) }
        // 拖动结束、撤销重做之后水印都可能变：开着"新录制也用"就跟着更新默认值。
        .onChange(of: model.edit.watermark) { syncDefault() }
    }

    private func syncDefault() {
        guard usedForNewProjects, let current = model.edit.watermark else { return }
        Watermark.setDefaultForNewProjects(current)
    }
    /// 开关、选项：点一下就是一步撤销。
    private func commit(_ change: @escaping (inout Watermark) -> Void) {
        model.commit { edit in
            var next = edit.watermark ?? Watermark()
            change(&next)
            edit.watermark = next
        }
    }
    /// 拖动中的数值：只改预览，控件在松手时由交互事务记一步撤销。
    private func live(_ key: WritableKeyPath<Watermark, Double>) -> Binding<Double> {
        Binding(get: { watermark[keyPath: key] }, set: { value in
            var next = watermark
            next[keyPath: key] = value
            model.edit.watermark = next
        })
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = try Watermark.importImage(from: url)
            commit { $0.image = name }
        } catch { model.error = error.localizedDescription }
    }
}
