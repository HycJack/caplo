import AppKit
import Observation
import SwiftUI
import CaptureKit
import CaploDesignSystem

/// 提词器的状态：讲稿、字号、滚动速度与是否在滚。讲稿和参数记在偏好里，下次打开还在。
@MainActor @Observable
final class TeleprompterModel {
    static let shared = TeleprompterModel()
    static let fontRange = 14.0...48.0
    /// 滚动速度，点 / 秒。
    static let speedRange = 8.0...160.0

    var text: String { didSet { if text != oldValue { UserDefaults.standard.set(text, forKey: "teleprompter.text") } } }
    var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "teleprompter.fontSize") } }
    var speed: Double { didSet { UserDefaults.standard.set(speed, forKey: "teleprompter.speed") } }
    /// 开始录制时从头自动滚，暂停录制跟着停。
    var followsRecording: Bool { didSet { UserDefaults.standard.set(followsRecording, forKey: "teleprompter.followsRecording") } }
    var playing = false
    /// 浮窗是否开着：录制条上的按钮据此亮起（窗口本身的可见性不可观察）。
    var visible = false
    /// 递增一次就回到讲稿开头（文本视图观察它）。
    var rewind = 0

    private init() {
        let defaults = UserDefaults.standard
        text = defaults.string(forKey: "teleprompter.text") ?? ""
        fontSize = min(max(defaults.object(forKey: "teleprompter.fontSize") as? Double ?? 24, Self.fontRange.lowerBound), Self.fontRange.upperBound)
        speed = min(max(defaults.object(forKey: "teleprompter.speed") as? Double ?? 36, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        followsRecording = defaults.object(forKey: "teleprompter.followsRecording") as? Bool ?? true
    }

    /// 离屏预览用：给定讲稿，不读偏好。
    init(preview text: String) { self.text = text; fontSize = 24; speed = 36; followsRecording = true }

    func restart() { rewind &+= 1; playing = !text.isEmpty }
}

/// 提词器浮窗：置顶、可拖动可缩放、不进录制画面（`sharingType = .none`，与录制条等浮层同一做法）。
/// 窗口只隐藏不销毁：录制中不新建销毁窗口，录制过滤器不必更新。
@MainActor
enum TeleprompterWindow {
    private static var panel: NSPanel?
    private static var observing = false
    /// 这次滚动是不是跟着录制自动开始的：只有这种情况下暂停 / 结束录制才替用户停下来。
    private static var startedByRecording = false
    private static var lastPhase = ScreenRecorder.Phase.idle
    nonisolated static let defaultSize = CGSize(width: 460, height: 240)
    /// 宽度够工具条排开，高度够按默认字号露出两行讲稿。
    static let minimumSize = CGSize(width: 360, height: 160)

    static var isVisible: Bool { panel?.isVisible == true }

    static func toggle() { if isVisible { hide() } else { show() } }

    static func show() {
        if panel == nil {
            let screen = StudioWindows.currentRecordBarModel?.targetScreen ?? NSScreen.main ?? NSScreen.screens[0]
            // 默认停在屏幕顶部正中：离摄像头最近，念稿时视线不会明显偏开。
            let visible = screen.visibleFrame
            let frame = CGRect(x: visible.midX - defaultSize.width / 2, y: visible.maxY - defaultSize.height - 12, width: defaultSize.width, height: defaultSize.height)
            let panel = TeleprompterPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = StudioLevel.bar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.isMovableByWindowBackground = true
            panel.animationBehavior = .none
            panel.minSize = minimumSize
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            // 不可共享：讲稿只给自己看，不进片子，别人截屏也看不到。
            panel.sharingType = .none
            let host = NSHostingView(rootView: TeleprompterView(model: .shared, close: { TeleprompterWindow.hide() }))
            // 托管视图会按界面自身的最小尺寸改写窗口下限（高度能一直压到只剩工具条）：关掉，下限只认上面的 minSize。
            host.sizingOptions = []
            let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
            let resize = TeleprompterResizeView(frame: content.bounds)
            for view in [host, resize] {
                view.frame = content.bounds
                view.autoresizingMask = [.width, .height]
                content.addSubview(view)
            }
            panel.contentView = content
            // 记住用户拖到的位置与大小。
            panel.setFrameAutosaveName("caplo-teleprompter")
            // 以前存下的尺寸可能比现在的下限小：按下限撑开，左上角不动。
            let saved = panel.frame
            let size = CGSize(width: max(saved.width, minimumSize.width), height: max(saved.height, minimumSize.height))
            if size != saved.size { panel.setFrame(CGRect(x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height), display: false) }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        TeleprompterModel.shared.visible = true
        startObserving()
    }

    static func hide() {
        TeleprompterModel.shared.playing = false
        startedByRecording = false
        panel?.orderOut(nil)
        TeleprompterModel.shared.visible = false
    }

    /// 跟着录制走：进入录制从头开始滚，暂停时停、继续时接着滚，录完停下。只在窗口开着且打开了"随录制滚动"时动作。
    private static func startObserving() {
        guard !observing else { return }
        observing = true
        track()
    }
    private static func track() {
        withObservationTracking { sync(ScreenRecorder.shared.phase) } onChange: { Task { @MainActor in track() } }
    }
    private static func sync(_ phase: ScreenRecorder.Phase) {
        defer { lastPhase = phase }
        let model = TeleprompterModel.shared
        guard isVisible, model.followsRecording, phase != lastPhase else { return }
        switch phase {
        case .recording:
            if lastPhase == .resuming || lastPhase == .paused { if startedByRecording { model.playing = true } }
            else { model.restart(); startedByRecording = model.playing }
        case .pausing, .paused, .stopping, .idle:
            if startedByRecording { model.playing = false }
            if phase == .idle || phase == .stopping { startedByRecording = false }
        default: break
        }
    }
}

/// 无边框也要能成为键窗口：讲稿要能点进去改、粘贴。不激活应用，录制目标不会因为点了提词器就失去焦点。
private final class TeleprompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 盖在提词器界面上面的一圈缩放手柄：只有四边和四角接事件，其余位置让给下面的界面。
///
/// 无边框窗口自带的缩放区只有贴边的两三点宽，很难对准；这里在窗口内侧补一圈够宽的，系统那一圈照旧可用。
/// 界面在这一圈里不放可点的东西（工具条、正文都往里收了同样的宽度）。
final class TeleprompterResizeView: NSView {
    /// 左、右、下三边手柄的宽度。
    static let edge = 8.0
    /// 顶边窄一些：紧挨着它的是拖动条，要把位置让出来。
    static let topEdge = 5.0
    /// 四角手柄的边长：对角缩放最常用，给得最大。
    static let corner = 20.0

    /// 一个手柄管哪几条边：边是一条，角是相邻的两条。
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)

        var cursor: NSCursor {
            let position: NSCursor.FrameResizePosition = switch self {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case .left: .left
            case .right: .right
            case .top: .top
            default: .bottom
            }
            return .frameResize(position: position, directions: .all)
        }
    }
    private var drag: (position: Edges, frame: CGRect, mouse: CGPoint)?

    /// 八个手柄各占的范围（左下原点）。四角排在前面：和边重叠的地方算角。
    private var zones: [(rect: CGRect, position: Edges)] {
        let width = bounds.width, height = bounds.height, corner = Self.corner, edge = Self.edge, top = Self.topEdge
        return [
            (CGRect(x: 0, y: 0, width: corner, height: corner), [.bottom, .left]),
            (CGRect(x: width - corner, y: 0, width: corner, height: corner), [.bottom, .right]),
            (CGRect(x: 0, y: height - corner, width: corner, height: corner), [.top, .left]),
            (CGRect(x: width - corner, y: height - corner, width: corner, height: corner), [.top, .right]),
            (CGRect(x: 0, y: corner, width: edge, height: height - corner * 2), .left),
            (CGRect(x: width - edge, y: corner, width: edge, height: height - corner * 2), .right),
            (CGRect(x: corner, y: 0, width: width - corner * 2, height: edge), .bottom),
            (CGRect(x: corner, y: height - top, width: width - corner * 2, height: top), .top),
        ]
    }

    func position(at point: CGPoint) -> Edges {
        zones.first { $0.rect.contains(point) }?.position ?? []
    }

    /// 按住某个手柄拖了 `delta`（屏幕坐标，向上为正）之后的窗口位置：对边不动，不小于下限。
    static func resized(_ frame: CGRect, position: Edges, by delta: CGSize, minimum: CGSize) -> CGRect {
        var result = frame
        if position.contains(.right) { result.size.width = max(minimum.width, frame.width + delta.width) }
        if position.contains(.left) {
            result.size.width = max(minimum.width, frame.width - delta.width)
            result.origin.x = frame.maxX - result.width
        }
        if position.contains(.top) { result.size.height = max(minimum.height, frame.height + delta.height) }
        if position.contains(.bottom) {
            result.size.height = max(minimum.height, frame.height - delta.height)
            result.origin.y = frame.maxY - result.height
        }
        return result
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        position(at: convert(point, from: superview)).isEmpty ? nil : self
    }
    /// 窗口背景可以拖着走，手柄上按下去是缩放，不能被当成拖动。
    override var mouseDownCanMoveWindow: Bool { false }
    /// 提词器平时不是键窗口：第一下按下去就要能缩放。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        for zone in zones { addCursorRect(zone.rect, cursor: zone.position.cursor) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let position = position(at: convert(event.locationInWindow, from: nil))
        guard !position.isEmpty else { return }
        // 用屏幕上的鼠标位置算位移：拖左边、下边时窗口原点跟着动，窗口内坐标不能直接相减。
        drag = (position, window.frame, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window else { return }
        let mouse = NSEvent.mouseLocation
        let frame = Self.resized(drag.frame, position: drag.position, by: CGSize(width: mouse.x - drag.mouse.x, height: mouse.y - drag.mouse.y), minimum: window.minSize)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil, let window else { return }
        drag = nil
        window.saveFrame(usingName: window.frameAutosaveName)
    }
}

/// 按住就能拖动窗口的空白区域，垫在拖动条和工具条下面：上面的按钮、滑条照常接自己的点击。
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // 窗口没有按背景拖动时（系统没接手）自己发起拖动。
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct TeleprompterView: View {
    @Bindable var model: TeleprompterModel
    let close: () -> Void

    /// 顶上拖动条的高度：和系统工具面板的标题栏差不多，整条都能按住拖。
    static let gripHeight = 16.0

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: Self.gripHeight)
                .overlay { Capsule().fill(Color.white.opacity(0.28)).frame(width: 36, height: 4).offset(y: 1).allowsHitTesting(false) }
            HStack(spacing: CaploMetrics.Spacing.s) {
                Button { if model.playing { model.playing = false } else { model.playing = !model.text.isEmpty } } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(StudioIconButtonStyle(size: .small, active: model.playing))
                .help(model.playing ? "暂停滚动" : "开始滚动").accessibilityLabel(model.playing ? "暂停滚动" : "开始滚动")
                .disabled(model.text.isEmpty)
                Button { model.playing = false; model.rewind &+= 1 } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(StudioIconButtonStyle(size: .small))
                    .help("回到开头").accessibilityLabel("回到开头")
                ThinSlider(String(localized: "滚动速度"), systemImage: "hare", value: $model.speed, in: TeleprompterModel.speedRange) { model.speed = 36 }
                    .frame(width: 96).help("滚动速度")
                ThinSlider(String(localized: "字号"), systemImage: "arrow.up.left.and.arrow.down.right", value: $model.fontSize, in: TeleprompterModel.fontRange) { model.fontSize = 24 }
                    .frame(width: 96).help("字号")
                Spacer(minLength: 0)
                Button { model.followsRecording.toggle() } label: { Image(systemName: "record.circle") }
                    .buttonStyle(StudioIconButtonStyle(size: .small, active: model.followsRecording))
                    .help("随录制滚动").accessibilityLabel("随录制滚动")
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(StudioIconButtonStyle(size: .small))
                    .help("关闭").accessibilityLabel("关闭提词器")
            }
            .padding(.horizontal, CaploMetrics.Spacing.s)
            .frame(height: 32)
            .background(WindowDragArea())
            ZStack(alignment: .topLeading) {
                TeleprompterTextView(model: model)
                if model.text.isEmpty {
                    Text("在这里粘贴或输入讲稿")
                        .font(.system(size: model.fontSize, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.horizontal, TeleprompterTextView.inset.width + 5).padding(.vertical, TeleprompterTextView.inset.height)
                        .allowsHitTesting(false)
                }
            }
            // 左右和底边让出缩放手柄的宽度：正文、滚动条都不压在手柄上，最后一行字也不贴着圆角。
            .padding(.horizontal, TeleprompterResizeView.edge)
            .padding(.bottom, TeleprompterResizeView.edge + 2)
        }
        // 深色半透明底：压在任何桌面上都读得清，又不至于整块挡死后面的内容。
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        // 右下角两道斜线：提示这里可以拖着改大小。
        .overlay(alignment: .bottomTrailing) {
            Path { path in
                path.move(to: CGPoint(x: 12, y: 3)); path.addLine(to: CGPoint(x: 3, y: 12))
                path.move(to: CGPoint(x: 12, y: 8)); path.addLine(to: CGPoint(x: 8, y: 12))
            }
            .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 12, height: 12).padding(5)
            .allowsHitTesting(false)
        }
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
    }
}

/// 讲稿正文：系统文本视图（中文输入法、粘贴、撤销都由系统负责），滚动由一个 60 Hz 定时器推着走。
/// 每一步从滚动视图当前位置接着走，所以滚动中用手拨一下位置，它就从新位置继续。
struct TeleprompterTextView: NSViewRepresentable {
    let model: TeleprompterModel
    static let inset = CGSize(width: 6, height: 8)

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        if let text = scroll.documentView as? NSTextView {
            text.delegate = context.coordinator
            text.drawsBackground = false
            text.isRichText = false
            text.allowsUndo = true
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.textContainerInset = Self.inset
            text.insertionPointColor = .white
            text.string = model.text
            context.coordinator.text = text
        }
        context.coordinator.scroll = scroll
        context.coordinator.applyStyle()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if let text = coordinator.text, text.string != model.text { text.string = model.text; coordinator.applyStyle() }
        if coordinator.fontSize != model.fontSize { coordinator.applyStyle() }
        if coordinator.rewind != model.rewind { coordinator.rewind = model.rewind; coordinator.scrollToTop() }
        coordinator.setPlaying(model.playing)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.setPlaying(false) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: TeleprompterModel
        weak var text: NSTextView?
        weak var scroll: NSScrollView?
        var fontSize = 0.0
        var rewind = 0
        private var timer: Timer?
        private var last = 0.0
        /// 不足一个像素的零头攒着，慢速滚动才不会一顿一顿或干脆不动。
        private var remainder = 0.0

        init(model: TeleprompterModel) { self.model = model; rewind = model.rewind }

        func applyStyle() {
            guard let text else { return }
            fontSize = model.fontSize
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.3
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: style,
            ]
            text.typingAttributes = attributes
            text.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: text.textStorage?.length ?? 0))
        }

        func textDidChange(_ notification: Notification) {
            guard let text else { return }
            model.text = text.string
        }

        func scrollToTop() {
            guard let scroll else { return }
            remainder = 0
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func setPlaying(_ playing: Bool) {
            guard playing != (timer != nil) else { return }
            timer?.invalidate(); timer = nil
            guard playing else { return }
            last = ProcessInfo.processInfo.systemUptime; remainder = 0
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func step() {
            guard let scroll, let document = scroll.documentView else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // 窗口被拖着走、系统卡一下时不要一步跳出去一大截。
            let elapsed = min(0.1, now - last); last = now
            let scale = scroll.window?.backingScaleFactor ?? 2
            remainder += model.speed * elapsed
            let advance = (remainder * scale).rounded(.down) / scale
            guard advance > 0 else { return }
            remainder -= advance
            let clip = scroll.contentView
            let limit = max(0, document.frame.height - clip.bounds.height)
            let next = min(limit, clip.bounds.origin.y + advance)
            clip.scroll(to: CGPoint(x: 0, y: next))
            scroll.reflectScrolledClipView(clip)
            // 到底就停：按钮回到"开始滚动"。
            if next >= limit - 0.5 { model.playing = false }
        }
    }
}

/// 离屏预览：带一段示例讲稿的提词器。
public struct TeleprompterPreview: View {
    public static let size = TeleprompterWindow.defaultSize
    @State private var model = TeleprompterModel(preview: "大家好，今天带大家看一下 Caplo 的新功能。\n先从录制开始：按下 REC 之后，讲稿会自己往上滚，暂停录制它也跟着停。\n录完直接进编辑器，镜头、光标和字幕都已经准备好了。")
    public init() {}
    public var body: some View { TeleprompterView(model: model, close: {}) }
}
