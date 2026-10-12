import AppKit
import CoreGraphics
import CoreImage
import CoreText
import EditingCore

/// 把按键画成一排键帽，叠在成片最上面。
///
/// 键帽组先画成位图并缓存（同一组键在它显示的一两秒里每帧都一样），逐帧只做摆放与不透明度。
/// 尺寸按 1080 参考高度书写、按输出高度等比缩放，预览与导出一致。
public final class KeystrokeRenderer: @unchecked Sendable {
    public static let shared = KeystrokeRenderer()

    private struct Key: Hashable {
        let groups: [[String]]
        let theme: KeystrokeStyle.Theme
        /// 键帽高度（像素，取整到 0.5）：输出尺寸与大小倍率都折在这里。
        let capHeight: Double
    }
    private var cache: [Key: CIImage] = [:]
    private var order: [Key] = []
    private let lock = NSLock()
    private static let capacity = 32
    /// 键帽高度的基准（1080 参考高度下、倍率 1）。
    static let referenceCapHeight = 54.0
    /// 位图四周为阴影留的边，按键帽高度的比例。
    private static let margin = 0.5

    public init() {}

    /// 这一帧的按键图层（画布坐标，左下原点）；不用画返回 nil。
    public func image(for frame: KeystrokeFrame, canvas: CGSize) -> CIImage? {
        guard canvas.width > 1, canvas.height > 1, frame.alpha > 0.002, !frame.groups.isEmpty else { return nil }
        let capHeight = (Self.referenceCapHeight * frame.style.size * canvas.height / TextRenderer.referenceHeight * 2).rounded() / 2
        guard capHeight >= 4 else { return nil }
        let key = Key(groups: frame.groups, theme: frame.style.theme, capHeight: capHeight)
        guard let bitmap = cached(key) else { return nil }
        let size = bitmap.extent.size, inset = capHeight * Self.margin
        // 中心按样式里的位置摆，再往回收：整排键帽（不含阴影边）不出画面。
        let half = CGSize(width: size.width / 2 - inset, height: size.height / 2 - inset)
        let edge = capHeight * 0.4
        let x = min(max(canvas.width * frame.style.x, half.width + edge), max(half.width + edge, canvas.width - half.width - edge))
        let y = min(max(canvas.height * (1 - frame.style.y), half.height + edge), max(half.height + edge, canvas.height - half.height - edge))
        var image = bitmap.transformed(by: CGAffineTransform(translationX: (x - size.width / 2).rounded(), y: (y - size.height / 2).rounded()))
        if frame.alpha < 0.998 {
            let alpha = frame.alpha
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func cached(_ key: Key) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let image = cache[key] { return image }
        guard let image = Self.draw(key) else { return nil }
        cache[key] = image; order.append(key)
        if order.count > Self.capacity { cache[order.removeFirst()] = nil }
        return image
    }

    /// 一排键帽，等距排开：一组快捷键（⌘ ⇧ 4），或连续打字的每个键。
    private static func draw(_ key: Key) -> CIImage? {
        let height = key.capHeight, inset = height * margin
        let gap = height * 0.14
        let dark = key.theme == .dark
        let text = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.1, alpha: 1)
        let fill = dark ? CGColor(gray: 0.08, alpha: 0.92) : CGColor(gray: 1, alpha: 0.94)
        let stroke = dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.1)
        // 单个符号（⌘、A）字大一些；"esc"、"F12" 这类多个字符的缩小，免得键帽太宽。
        func line(_ cap: String) -> CTLine {
            let size = height * (cap.count > 1 ? 0.36 : 0.46)
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            return CTLineCreateWithAttributedString(NSAttributedString(string: cap, attributes: [.font: font, .foregroundColor: NSColor(cgColor: text) ?? .white]))
        }
        struct Cap { let line: CTLine; let bounds: CGRect; let width: CGFloat }
        let groups: [[Cap]] = key.groups.map { group in
            group.map { cap in
                let line = line(cap)
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                // 至少是正方形；字宽的再加两侧留白。
                return Cap(line: line, bounds: bounds, width: max(height, ceil(bounds.width + height * 0.56)))
            }
        }
        let capCount = groups.reduce(0) { $0 + $1.count }
        guard capCount > 0 else { return nil }
        let content = groups.reduce(0) { $0 + $1.reduce(0) { $0 + $1.width } } + gap * CGFloat(capCount - 1)
        let width = Int(ceil(content + inset * 2)), pixelHeight = Int(ceil(height + inset * 2))
        guard width > 0, pixelHeight > 0, width <= 8192,
              let context = CGContext(data: nil, width: width, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var x = inset
        let radius = height * 0.26
        for group in groups {
            for cap in group {
                let rect = CGRect(x: x, y: inset, width: cap.width, height: height)
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                // 很轻的投影：浅色画面上深色键帽本来就清楚，这层只是让浅色键帽在白底上不糊成一片。
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -height * 0.04), blur: height * 0.22, color: CGColor(gray: 0, alpha: dark ? 0.28 : 0.2))
                context.addPath(path); context.setFillColor(fill); context.fillPath()
                context.restoreGState()
                context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setStrokeColor(stroke); context.setLineWidth(1); context.strokePath()
                // 按字形的实际外框居中：⌘ ⇧ 这些符号的基线和字母不一样，按排版外框居中会上下不齐。
                context.textPosition = CGPoint(x: rect.midX - cap.bounds.midX, y: rect.midY - cap.bounds.midY)
                CTLineDraw(cap.line, context)
                x += cap.width + gap
            }
        }
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}
