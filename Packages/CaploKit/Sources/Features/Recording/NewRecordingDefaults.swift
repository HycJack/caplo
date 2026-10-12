import Foundation
import EditingCore

/// "设置 → 录制 → 新录制的默认效果"存的三项偏好，以及把它们换算成新工程起点的地方。
@MainActor
enum NewRecordingDefaults {
    static let autoFocusKey = "newRecording.autoFocus"
    static let cursorEffectsKey = "newRecording.cursorEffects"
    /// 存的是布局预设的名字：同名预设重新保存后 ID 会变，名字不变。
    static let layoutPresetKey = "newRecording.layoutPreset"

    /// 当前选中的默认布局预设；没选或已被删掉为 nil。
    static func layoutPreset(in defaults: UserDefaults = .standard, store: CanvasPresetStore = .shared) -> CanvasPreset? {
        guard let name = defaults.string(forKey: layoutPresetKey), !name.isEmpty else { return nil }
        return store.presets.first { $0.name == name }
    }

    static func current(in defaults: UserDefaults = .standard, store: CanvasPresetStore = .shared) -> NewProjectDefaults {
        var value = NewProjectDefaults()
        value.automaticFocus = defaults.object(forKey: autoFocusKey) as? Bool ?? true
        value.cursorEffects = defaults.object(forKey: cursorEffectsKey) as? Bool ?? true
        value.layout = layoutPreset(in: defaults, store: store)?.layout
        return value
    }
}
