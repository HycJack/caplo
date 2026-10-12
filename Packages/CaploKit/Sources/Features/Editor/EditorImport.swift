import AppKit
import UniformTypeIdentifiers
import CaploDesignSystem

/// 编辑器里"导入"的两个入口：选文件，交给模型收进工程。
@MainActor
enum EditorImport {
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]

    static func pickVideo(for model: VideoEditorModel) {
        guard let url = pick(videoTypes) else { return }
        model.importVideo(from: url)
    }

    static func pickMusic(for model: VideoEditorModel) {
        guard let url = pick([.audio]) else { return }
        model.importMusic(from: url)
    }

    /// 时间线工具栏"导入"按钮的菜单，在鼠标按下的位置弹出。
    static func showMenu(for model: VideoEditorModel) {
        let menu = MenuAnchor.makeMenu([
            .item(String(localized: "视频")) { pickVideo(for: model) },
            .item(String(localized: "音乐")) { pickMusic(for: model) },
        ])
        menu.appearance = NSAppearance(named: .darkAqua)
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    static func pick(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
