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
    nonisolated static let defaultSize = CGSize(width: 460, height: 220)
    static let minimumSize = CGSize(width: 320, height: 140)

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
            panel.contentView = NSHostingView(rootView: TeleprompterView(model: .shared, close: { TeleprompterWindow.hide() }))
            // 记住用户拖到的位置与大小。
            panel.setFrameAutosaveName("caplo-teleprompter")
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

struct TeleprompterView: View {
    @Bindable var model: TeleprompterModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(height: 36)
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
            // 底边留一点：最后一行字不贴着圆角。
            .padding(.bottom, 6)
        }
        // 深色半透明底：压在任何桌面上都读得清，又不至于整块挡死后面的内容。
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .foregroundStyle(CaploColor.textPrimary)
        .tint(CaploColor.accent)
        .preferredColorScheme(.dark)
    }
}

/// 讲稿正文：系统文本视图（中文输入法、粘贴、撤销都由系统负责），滚动由一个 60 Hz 定时器推着走。
/// 每一步从滚动视图当前位置接着走，所以滚动中用手拨一下位置，它就从新位置继续。
struct TeleprompterTextView: NSViewRepresentable {
    let model: TeleprompterModel
    static let inset = CGSize(width: 14, height: 8)

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
