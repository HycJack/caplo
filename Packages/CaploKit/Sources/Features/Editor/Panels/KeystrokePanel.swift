import SwiftUI
import CaploDesignSystem
import EditingCore

/// 按键显示：把录制时记下的快捷键画在成片上。按键本身来自录制（录制设置里的"记录按键"），这里只管怎么显示。
struct KeystrokePanel: View {
    let model: VideoEditorModel
    private var style: KeystrokeStyle { model.edit.keystrokes ?? KeystrokeStyle() }
    /// 这段录制有没有记下按键：没有的话整个面板只剩一句说明。
    private var recorded: Bool { model.entry.document.segments.contains { $0.keysPath != nil } }
    /// 录制时选的是"全部按键"才有普通键可筛；"仅快捷键"录下来的没得选。
    private var recordedAll: Bool { model.entry.document.capture?.keyCapture == KeyCaptureMode.all.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !recorded {
                PanelNote(String(localized: "此录制没有按键。下次录制前在录制设置里打开\u{201C}记录按键\u{201D}。"))
            } else {
                Toggle(isOn: commitBinding(\.enabled)) { SettingLabel(String(localized: "显示按键"), systemImage: "keyboard") }
                    .toggleStyle(StudioToggleStyle())
                if style.enabled { PanelNote(String(localized: "画面上没有按键时显示 ⌘ K 作示例，仅在此面板可见。")) }
                Group {
                    if recordedAll {
                        PanelSection(String(localized: "显示哪些")) {
                            ChipGroup(KeystrokeStyle.Filter.allCases, selection: commitBinding(\.filter)) { $0.title }
                        }
                    }
                    PanelSection(String(localized: "样式")) {
                        ChipGroup(KeystrokeStyle.Theme.allCases, selection: commitBinding(\.theme)) { $0.title }
                        EditorSlider(model: model, title: String(localized: "大小"), value: liveBinding(\.size), range: KeystrokeStyle.sizeRange, suffix: "×", defaultValue: 1, detents: [1])
                        // 位置在画布比例的底板上拖；键帽排得再长也会收在画面里。
                        EditorRegion(model: model, title: String(localized: "位置"), shape: .point, aspect: model.edit.layout.aspect,
                                     region: positionBinding, defaultRegion: CGRect(x: 0.5, y: 0.9, width: 0, height: 0)) { EditorRegion.positionReadout($0.origin) }
                        EditorStepper(model: model, title: String(localized: "停留"), value: liveBinding(\.hold), range: KeystrokeStyle.holdRange, step: 0.1, defaultValue: 1.2)
                    }
                }
                .disabled(!style.enabled)
            }
        }
        // 面板开着时画面上有示例键帽，调位置、大小看得见落点；离开面板就撤掉。
        .onAppear { model.keystrokePanelVisible = recorded }
        .onDisappear { model.keystrokePanelVisible = false }
    }

    /// 开关、选项：点一下就是一步撤销。
    private func commitBinding<T>(_ key: WritableKeyPath<KeystrokeStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: key] }, set: { value in
            model.commit { edit in
                var next = edit.keystrokes ?? KeystrokeStyle()
                next[keyPath: key] = value
                edit.keystrokes = next
            }
        })
    }
    /// 拖动中的数值：只改预览，控件在松手时由交互事务记一步撤销。
    private func liveBinding(_ key: WritableKeyPath<KeystrokeStyle, Double>) -> Binding<Double> {
        Binding(get: { style[keyPath: key] }, set: { value in
            var next = style
            next[keyPath: key] = value
            model.edit.keystrokes = next
        })
    }
    private var positionBinding: Binding<CGRect> {
        Binding(get: { CGRect(x: style.x, y: style.y, width: 0, height: 0) }, set: { rect in
            var next = style
            next.x = min(1, max(0, rect.minX)); next.y = min(1, max(0, rect.minY))
            model.edit.keystrokes = next
        })
    }
}
