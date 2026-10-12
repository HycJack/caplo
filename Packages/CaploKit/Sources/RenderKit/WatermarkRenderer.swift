import AppKit
import CoreGraphics
import CoreImage
import CoreText
import EditingCore
import ImageIO

/// 把水印画到成片上。文字排成位图、图片解码缩好之后都缓存起来（整段成片每一帧都是同一张），逐帧只做摆放与不透明度。
public final class WatermarkRenderer: @unchecked Sendable {
    public static let shared = WatermarkRenderer()

    private struct Key: Hashable {
        let kind: Watermark.Kind
        let text: String
        let tone: Watermark.Tone
        let image: String?
        /// 目标高度（像素，取整）：输出尺寸与大小倍率都折在这里。
        let height: Int
    }
    private var cache: [Key: CIImage] = [:]
    private var order: [Key] = []
    /// 解不出来的图片记下来，不必每一帧都再去读一次盘。
    private var missing = Set<Key>()
    private let lock = NSLock()
    private static let capacity = 8
    static let textReference = 30.0
    static let imageReference = 72.0

    public init() {}

    public func clear() { lock.lock(); cache.removeAll(); order.removeAll(); missing.removeAll(); lock.unlock() }

    /// 这一帧的水印图层（画布坐标，左下原点）；不用画返回 nil。
    public func image(for watermark: Watermark, canvas: CGSize) -> CIImage? {
        guard watermark.isVisible, watermark.isValid, canvas.width > 1, canvas.height > 1 else { return nil }
        let reference = watermark.kind == .text ? Self.textReference : Self.imageReference
        let height = Int((reference * watermark.size * canvas.height / TextRenderer.referenceHeight).rounded())
        guard height >= 4 else { return nil }
        let key = Key(kind: watermark.kind, text: watermark.kind == .text ? watermark.text.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                      tone: watermark.tone, image: watermark.kind == .image ? watermark.image : nil, height: height)
        guard let bitmap = cached(key, watermark: watermark) else { return nil }
        let size = bitmap.extent.size
        // 中心按设定的位置摆，再往回收：整张水印不出画面，离边至少留一点。
        let edge = canvas.height * 0.02
        let halfWidth = min(size.width, canvas.width - edge * 2) / 2, halfHeight = min(size.height, canvas.height - edge * 2) / 2
        let x = min(max(canvas.width * watermark.x, halfWidth + edge), max(halfWidth + edge, canvas.width - halfWidth - edge))
        let y = min(max(canvas.height * (1 - watermark.y), halfHeight + edge), max(halfHeight + edge, canvas.height - halfHeight - edge))
        var image = bitmap.transformed(by: CGAffineTransform(translationX: (x - size.width / 2).rounded(), y: (y - size.height / 2).rounded()))
        if watermark.opacity < 0.998 {
            let alpha = watermark.opacity
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func cached(_ key: Key, watermark: Watermark) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let image = cache[key] { return image }
        if missing.contains(key) { return nil }
        let drawn = key.kind == .text ? Self.drawText(key) : watermark.imageURL.flatMap { Self.loadImage($0, height: key.height) }
        guard let drawn else { missing.insert(key); return nil }
        cache[key] = drawn; order.append(key)
        if order.count > Self.capacity { cache[order.removeFirst()] = nil }
        return drawn
    }

    /// 一行字：字高即目标高度；浅色字带一点深色投影（深色字带浅色投影），压在什么画面上都读得出。
    private static func drawText(_ key: Key) -> CIImage? {
        let fontSize = CGFloat(key.height), light = key.tone == .light
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let color = light ? NSColor.white : NSColor(white: 0.08, alpha: 1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: key.text, attributes: [.font: font, .foregroundColor: color]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let inset = ceil(fontSize * 0.35)
        let width = Int(ceil(bounds.width + inset * 2)), height = Int(ceil(bounds.height + inset * 2))
        guard width > 0, height > 0, width <= 8192,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.03), blur: fontSize * 0.14,
                          color: CGColor(gray: light ? 0 : 1, alpha: light ? 0.45 : 0.35))
        context.textPosition = CGPoint(x: inset - bounds.minX, y: inset - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    /// 图片按目标高度等比缩小后解码一次（标志原图可能有几千像素宽，没必要每帧拿原图去缩）。
    private static func loadImage(_ url: URL, height: Int) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Double, let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Double,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        // 缩略图接口按最长边限制：横幅标志的最长边是宽，按比例折算；再封顶，避免极宽的图占满内存。
        let scale = Double(height) / pixelHeight
        let longest = min(4096, max(1, Int((max(pixelWidth, pixelHeight) * scale).rounded(.up))))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longest, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return CIImage(cgImage: image)
    }
}
