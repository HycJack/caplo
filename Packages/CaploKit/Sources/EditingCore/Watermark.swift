import Foundation

/// 水印：固定在成片一角的一行字或一张图（品牌名、标志）。位置在输出画面上，不跟着镜头推近放大；
/// 尺寸按 1080 参考高度，预览与导出一致。整段成片都显示，卡片上也在。
public struct Watermark: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, image
        public var title: String { switch self { case .text: String(localized: "文字"); case .image: String(localized: "图片") } }
    }
    public enum Tone: String, Codable, CaseIterable, Sendable {
        case light, dark
        public var title: String { switch self { case .light: String(localized: "浅色"); case .dark: String(localized: "深色") } }
    }
    public var enabled = true
    public var kind = Kind.text
    public var text = ""
    /// 文字水印的颜色：浅色配深色画面，深色配浅色画面。
    public var tone = Tone.light
    /// 图片水印的文件名，放在 `Watermark.imageDirectory` 里。图片存在用户目录而不是工程包里：
    /// 标志是"我的"而不是某个工程的，换一个工程接着用同一张；文件不在时就只是不画。
    public var image: String?
    /// 水印中心在输出画面上的位置，0…1，y 从上往下。默认右下角。
    public var x = 0.9
    public var y = 0.92
    /// 大小倍率：文字 1 倍是 30 号字，图片 1 倍高 72（都按 1080 参考高度）。
    public var size = 1.0
    public var opacity = 0.7
    public init() {}

    public static let sizeRange = 0.4...4.0
    public static let textLimit = 80
    /// 有东西可画：开着，且文字不空或选了图片。
    public var isVisible: Bool {
        enabled && opacity > 0.002 && (kind == .text ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : image != nil)
    }
    public var isValid: Bool {
        x.isFinite && (0...1).contains(x) && y.isFinite && (0...1).contains(y) && size.isFinite && Self.sizeRange.contains(size)
            && opacity.isFinite && (0...1).contains(opacity) && text.count <= Self.textLimit
            // 文件名只能是目录里的一个普通文件名，不能借它读到别处去。
            && (image.map { !$0.isEmpty && !$0.contains("/") && !$0.contains("..") && $0.count <= 120 } ?? true)
    }

    /// 水印图片的存放目录。调试版（包标识以 .dev 结尾）用单独的目录，与工程库同一规则。
    public static var imageDirectory: URL {
        let folder = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Caplo Dev" : "Caplo"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(folder)/Watermarks", isDirectory: true)
    }
    public var imageURL: URL? { image.map { Self.imageDirectory.appendingPathComponent($0) } }

    /// 把用户选的图片复制进水印目录，返回文件名。
    public static func importImage(from source: URL) throws -> String {
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased())"
        try FileManager.default.copyItem(at: source, to: imageDirectory.appendingPathComponent(name))
        return name
    }

    // MARK: 新工程的默认水印

    private static let defaultKey = "watermark.default"
    /// 记下来给以后的新录制用的水印；没设过为 nil。
    public static func defaultForNewProjects(in defaults: UserDefaults = .standard) -> Watermark? {
        guard let data = defaults.data(forKey: defaultKey), let value = try? JSONDecoder().decode(Watermark.self, from: data), value.isValid else { return nil }
        return value
    }
    public static func setDefaultForNewProjects(_ watermark: Watermark?, in defaults: UserDefaults = .standard) {
        if let watermark, let data = try? JSONEncoder().encode(watermark) { defaults.set(data, forKey: defaultKey) } else { defaults.removeObject(forKey: defaultKey) }
    }
}
