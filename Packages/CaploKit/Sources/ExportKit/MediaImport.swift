@preconcurrency import AVFoundation
import ProjectKit
import EditingCore

/// 把外面的视频、音频文件收进工程。
///
/// 视频：复制进 `Media/`，登记成新的一段素材接在源时间末尾（工程里各段素材首尾相连，见 `ProjectDocument.assetRanges`）；
/// 自带的声音就用同一个文件，走"系统声音"那条轨。带旋转信息（竖拍）或 HDR 的视频先转成正向、普通色彩的一份——
/// 合成器直接读解码出来的像素，不认容器里的旋转标记，也只按 Rec. 709 处理颜色。
/// 音频：复制进 `Media/Music/`，量好总长，交给调用方放到音乐轨上。
public enum MediaImport {
    /// 导入视频的结果：更新后的清单，以及新素材在源时间里的范围与基本信息。
    public struct ImportedVideo: Sendable {
        public let document: ProjectDocument
        public let sourceRange: Range<Double>
        public let pixelSize: CGSize
        public let frameRate: Double
        public let hasAudio: Bool
    }

    /// 把视频加进已有工程，作为独立的一份素材。调用方须持有工程租约。
    public static func appendVideo(_ source: URL, to project: URL) async throws -> ImportedVideo {
        try await place(source, in: project, separate: true)
    }

    /// 用一个视频新建工程：它就是这个工程本来的素材，没有指针与按键数据。返回工程目录。
    public static func createProject(from source: URL, in root: URL = ProjectStorage.libraryURL) async throws -> URL {
        let name = source.deletingPathExtension().lastPathComponent
        let project = try ProjectStorage.create(in: root, name: name.isEmpty ? String(localized: "导入的视频") : name)
        do {
            let imported = try await place(source, in: project, separate: false)
            var document = imported.document
            var capture = CaptureMetadata(desktopBounds: CGRect(origin: .zero, size: imported.pixelSize), pixelSize: imported.pixelSize,
                                          pointPixelScale: 1, pointerEnabled: false)
            capture.frameRate = min(120, max(24, imported.frameRate.rounded()))
            capture.systemAudioEnabled = imported.hasAudio
            document.capture = capture
            document.state = .completed
            try ProjectStorage.save(document, to: project)
            return project
        } catch {
            // 半截工程不留在项目列表里。
            try? FileManager.default.removeItem(at: project)
            throw error
        }
    }

    /// 把音频文件加进工程，返回可以直接放到音乐轨上的来源描述。
    public static func importMusic(_ source: URL, into project: URL) async throws -> MusicSource {
        let probe = AVURLAsset(url: source)
        guard try await !probe.loadTracks(withMediaType: .audio).isEmpty else {
            throw ProjectError.invalid(String(localized: "这个文件里没有可用的声音。"))
        }
        let path = try ProjectStorage.importMusic(from: source, into: project)
        do {
            let asset = AVURLAsset(url: try ProjectStorage.mediaURL(path, in: project))
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ProjectError.invalid(String(localized: "这个文件里没有可用的声音。")) }
            let length = try await track.load(.timeRange).duration.seconds
            guard length.isFinite, length >= 0.1 else { throw ProjectError.invalid(String(localized: "这段声音太短，无法导入。")) }
            let name = source.deletingPathExtension().lastPathComponent
            return MusicSource(file: path, length: length, name: name.isEmpty ? nil : name)
        } catch {
            if let file = try? ProjectStorage.mediaURL(path, in: project) { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    private static func place(_ source: URL, in project: URL, separate: Bool) async throws -> ImportedVideo {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProjectError.invalid(String(localized: "这个文件里没有视频画面。"))
        }
        guard try await !asset.load(.hasProtectedContent) else { throw ProjectError.invalid(String(localized: "受版权保护的视频无法导入。")) }
        let (transform, characteristics) = try await track.load(.preferredTransform, .mediaCharacteristics)
        let needsConversion = !transform.isIdentity || characteristics.contains(.containsHDRVideo)
        let kept = ["mov", "mp4", "m4v"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "mov"
        let path = ProjectStorage.importedVideoPath(extension: needsConversion ? "mov" : kept)
        let destination = try ProjectStorage.mediaURL(path, in: project)
        do {
            if needsConversion { try await convert(asset, to: destination) }
            // 同一卷上是克隆（不占额外空间、瞬间完成），跨卷才真的复制。
            else { try FileManager.default.copyItem(at: source, to: destination) }
            let placed = AVURLAsset(url: destination)
            guard let video = try await placed.loadTracks(withMediaType: .video).first else {
                throw ProjectError.invalid(String(localized: "这个视频无法解码。"))
            }
            let (range, size, rate, playable) = try await video.load(.timeRange, .naturalSize, .nominalFrameRate, .isPlayable)
            // 片段时长按画面轨算：声音比画面长出来的那一点不要，否则片尾会多一截没有画面的声音。
            let duration = range.end.seconds
            guard playable, duration.isFinite, duration >= 0.1, size.width >= 16, size.height >= 16 else {
                throw ProjectError.invalid(String(localized: "这个视频无法解码。"))
            }
            let hasAudio = try await !placed.loadTracks(withMediaType: .audio).isEmpty
            let before = try ProjectStorage.load(project).duration
            let document = try ProjectStorage.appendImported(path: path, duration: duration, pixelSize: size, hasAudio: hasAudio, separate: separate, to: project)
            return ImportedVideo(document: document, sourceRange: before..<(before + duration), pixelSize: size,
                                 frameRate: rate > 0 ? Double(rate) : 30, hasAudio: hasAudio)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// 转成正向、Rec. 709 的一份：系统导出会按视频合成的设置把旋转烤进像素、把 HDR 映射到普通色彩。
    private static func convert(_ asset: AVURLAsset, to destination: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProjectError.invalid(String(localized: "这个视频无法转换。"))
        }
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        session.videoComposition = composition
        try await session.export(to: destination, as: .mov)
    }
}
