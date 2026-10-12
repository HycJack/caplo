import CoreImage
import CoreVideo
import Vision

/// 人像分割：给一帧摄像头画面，返回“人在哪”的蒙版（红色通道，1 = 人、0 = 背景），尺寸与位置已对齐到这一帧。
///
/// 用系统自带的模型（Vision），不联网，也不带第三方模型。只在后期合成时算，录下来的摄像头画面不动。
/// 一个实例只在一条串行队列上用（合成器的渲染队列）。
public final class PersonSegmenter: @unchecked Sendable {
    /// 预览要在一帧的时间里算完，用均衡档（实测约 10 ms，蒙版 512×384）；
    /// 导出不赶时间，用精确档（约 30 ms，蒙版 2016×1512），头发和肩膀的边缘更干净。
    public enum Quality: Sendable { case balanced, accurate }

    public let quality: Quality
    private let request: VNGeneratePersonSegmentationRequest
    private let handler = VNSequenceRequestHandler()
    private var last: (buffer: CVPixelBuffer, mask: CIImage?)?
    /// 真正跑了几次模型（重复的帧不算）。测试用它确认同一帧没有重复计算。
    public private(set) var performed = 0

    public init(quality: Quality) {
        self.quality = quality
        request = Self.request(quality)
    }

    private static func request(_ quality: Quality) -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality == .accurate ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    /// 视频里的一帧。模型失败时返回 nil，调用方照原样画人像。
    public func mask(for buffer: CVPixelBuffer) -> CIImage? {
        // 合成帧率高于摄像头帧率时，同一帧摄像头画面会连着来两三次：只算一次。
        // 缓存一直握着那块缓冲，它就不会被解码器的缓冲池收回去重用，所以按对象比较是安全的。
        if let last, last.buffer === buffer { return last.mask }
        performed += 1
        let mask: CIImage?
        if (try? handler.perform([request], on: buffer)) != nil, let result = request.results?.first?.pixelBuffer {
            mask = Self.aligned(result, to: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        } else { mask = nil }
        last = (buffer, mask)
        return mask
    }

    /// 单张静帧（缩略图、自定义布局对话框）：每次用新的请求，不带视频帧之间的状态。
    public static func mask(for image: CIImage, quality: Quality = .balanced) -> CIImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return nil }
        let request = request(quality)
        guard (try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])) != nil,
              let result = request.results?.first?.pixelBuffer else { return nil }
        return aligned(result, to: extent.size).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// 模型给的蒙版分辨率是固定的，和画面比例无关：拉回到画面大小。
    /// 不做色彩管理：蒙版里的数值就是覆盖率，不能被当成灰度图再套一遍伽马。
    private static func aligned(_ mask: CVPixelBuffer, to size: CGSize) -> CIImage {
        let width = CGFloat(CVPixelBufferGetWidth(mask)), height = CGFloat(CVPixelBufferGetHeight(mask))
        return CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: size.width / max(1, width), y: size.height / max(1, height)))
    }
}
