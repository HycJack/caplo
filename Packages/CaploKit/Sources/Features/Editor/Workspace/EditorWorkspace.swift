import AppKit
import SwiftUI
import Observation
import EditingCore
import CaploDesignSystem

/// 预览与时间线的工作区：一个原生 `NSSplitView`，上窗格是成片显示面，下窗格是时间线（顶部固定高度的
/// SwiftUI 工具栏 + 原生视口）。分界由 AppKit 拖动，两个窗格都是图层视图，尺寸在同一事务内改变，
/// 拖动期间没有任何 SwiftUI 重新布局；模型变化通过观察推送给视口，而不是靠 SwiftUI 刷新。
struct EditorWorkspace: NSViewRepresentable {
    @Environment(\.caploMaterialOpaquePreview) private var materialOpaquePreview
    @Environment(\.caploMaterialHighContrastPreview) private var materialHighContrastPreview
    @Environment(\.colorSchemeContrast) private var materialContrast
    let model: VideoEditorModel
    let viewport: TimelineViewport
    let addFocus: () -> Void

    func makeNSView(context: Context) -> EditorWorkspaceView {
        let view = EditorWorkspaceView(model: model, viewport: viewport, addFocus: addFocus)
        view.updateMaterialPreview(opaque: materialOpaquePreview, contrast: previewContrast)
        return view
    }

    func updateNSView(_ view: EditorWorkspaceView, context: Context) {
        view.updateMaterialPreview(opaque: materialOpaquePreview, contrast: previewContrast)
    }

    private var previewContrast: ColorSchemeContrast {
        materialHighContrastPreview.map { $0 ? .increased : .standard } ?? materialContrast
    }

    static func dismantleNSView(_ view: EditorWorkspaceView, coordinator: ()) { view.tearDown() }
}

@MainActor
final class EditorWorkspaceView: NSSplitView, NSSplitViewDelegate {
    static let dividerSize: CGFloat = CaploMetrics.Spacing.s
    static let minimumCanvasHeight: CGFloat = 220
    /// 用户能把时间线拖到的最矮高度；轨道很少时"刚好摆下"的高度可以比它更矮。
    static let minimumTimelineHeight: CGFloat = 180
    static let defaultTimelineHeight: CGFloat = 294
    /// 用户亲手拖出来的时间线高度；没有这一项就是"自动"——按轨道数刚好摆下。
    /// 旧的 `editor.timelineHeight` 记的是另一回事（自动收放之前的固定高度），不再读：沿用它会让只有一两条轨的工程又变回半屏空地。
    static let heightKey = "editor.timelineManualHeight"

    private let model: VideoEditorModel
    let viewport: TimelineViewport
    let canvasPane = NSView(frame: .zero)
    let canvas = CanvasSurfaceView(frame: .zero)
    private let overlay: NSHostingView<AnyView>
    /// 遮罩与文字的编辑层夹在成片显示面和空态提示之间；不在对应面板时它们的 hitTest 一律放行。
    private let maskEditor: MaskCanvasView
    private let textEditor: TextCanvasView
    private let overlayContent: AnyView
    private var materialOpaquePreview: Bool?
    private var materialContrast: ColorSchemeContrast = .standard
    let timelinePane: TimelinePaneView
    private var detached = false
    private var appliedStoredHeight = false
    /// 正在拖分界：这期间高度听鼠标的，不往"刚好摆下"上收。
    private var draggingDivider = false
    private var defaultsObserver: NSObjectProtocol?

    init(model: VideoEditorModel, viewport: TimelineViewport, addFocus: @escaping () -> Void) {
        self.model = model; self.viewport = viewport
        overlayContent = AnyView(CanvasOverlay(model: model))
        let overlayHost = TransparentEditorHostingView(rootView: overlayContent)
        // 空态与载入提示是纯装饰，必须放行点击，否则它下面的遮罩 / 文字编辑层收不到任何鼠标。
        overlayHost.passesThroughClicks = true
        overlay = overlayHost
        maskEditor = MaskCanvasView(model: model, canvas: canvas)
        textEditor = TextCanvasView(model: model, canvas: canvas)
        timelinePane = TimelinePaneView(model: model, viewport: viewport, addFocus: addFocus)
        super.init(frame: .zero)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        wantsLayer = true
        // 分界留白透出编辑器根材质，不能再用不透明实色把窗口层遮住。
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false

        canvasPane.wantsLayer = true
        canvasPane.layer?.cornerRadius = CaploMetrics.Radius.panel
        canvasPane.layer?.masksToBounds = true
        canvasPane.layer?.borderWidth = CaploMetrics.hairline
        canvasPane.layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
        canvas.presenter = model.canvas
        canvas.snapshotMode = model.canvas.snapshotMode
        model.canvas.view = canvas
        canvas.autoresizingMask = [.width, .height]
        overlay.sizingOptions = []
        overlay.autoresizingMask = [.width, .height]
        canvasPane.addSubview(canvas)
        maskEditor.autoresizingMask = [.width, .height]
        canvasPane.addSubview(maskEditor)
        textEditor.autoresizingMask = [.width, .height]
        canvasPane.addSubview(textEditor)
        canvasPane.addSubview(overlay)
        addArrangedSubview(canvasPane)
        addArrangedSubview(timelinePane)
        // 窗口变高变矮时只让预览伸缩，时间线保持用户设定的高度。
        setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 250), forSubviewAt: 0)
        setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 750), forSubviewAt: 1)

        timelinePane.timeline.onFittingHeightChange = { [weak self] in self?.fitTimeline() }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storedHeightChanged() }
        }
        observeModel()
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    /// 审核意图穿过 NSViewRepresentable 与独立 HostingView；生产 nil 保持系统偏好。
    func updateMaterialPreview(opaque: Bool?, contrast: ColorSchemeContrast) {
        guard opaque != materialOpaquePreview || contrast != materialContrast else { return }
        materialOpaquePreview = opaque; materialContrast = contrast
        canvas.materialOpaqueOverride = opaque
        timelinePane.updateMaterialPreview(opaque: opaque, contrast: contrast)
        let content = overlayContent
        if let opaque {
            overlay.rootView = AnyView(content.caploMaterialAccessibilityPreview(reduceTransparency: opaque, highContrast: contrast == .increased))
        } else { overlay.rootView = content }
    }

    func tearDown() {
        detached = true
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        timelinePane.timeline.detach()
        if model.canvas.view === canvas { model.canvas.view = nil }
    }

    // MARK: 模型 → 视口

    /// 模型或视口参数变化时把最新状态推给时间线视口与显示面；视口自己只在输入真的变化时重绘。
    private func observeModel() {
        guard !detached else { return }
        withObservationTracking {
            timelinePane.timeline.update(edit: model.edit, analysis: model.analysis, musicWaves: model.musicPeaks.count, selection: model.selectedClipIDs,
                                         primary: model.selectedClip, focus: model.selectedFocus, mask: model.selectedMask, text: model.selectedText, caption: model.selectedCaption,
                                         keys: model.keyTimeline, keyRun: model.selectedKeys,
                                         zoom: viewport.zoom, fit: viewport.fitRequest, heights: viewport.trackHeights,
                                         reveal: model.revealRequest)
            canvas.aspectRatio = model.edit.layout.aspect
            canvas.isHiddenContent = (model.edit.duration <= 0)
            // 遮罩框跟着编辑内容、播放头与选中项走；播放中整层不画，所以顺带读一下 playing。
            maskEditor.refreshFor(edit: model.edit, time: model.skimPosition ?? model.position,
                                  selection: model.selectedMask, editing: model.maskEditing, playing: model.playing)
            textEditor.refreshFor(edit: model.edit, time: model.skimPosition ?? model.position,
                                  selection: model.editingTextID, editing: model.textEditing, playing: model.playing)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    // MARK: 分界

    override var dividerThickness: CGFloat { Self.dividerSize }

    override var isOpaque: Bool { false }

    override func drawDivider(in rect: NSRect) {
        let handle = CGRect(x: rect.midX - 18, y: rect.midY - 1.5, width: 36, height: 3)
        CaploNSColor.textTertiary.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// 分界拖动在 AppKit 的跟踪循环里完成：时间线按当前尺寸刷新可见行，松手后才记住高度。
    /// 双击分界：忘掉拖出来的高度，回到按轨道数自动收放。
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            UserDefaults.standard.removeObject(forKey: Self.heightKey)
            fitTimeline(); return
        }
        let before = timelineHeight
        timelinePane.timeline.liveResizing = true
        viewport.liveResizing = true
        draggingDivider = true
        super.mouseDown(with: event)
        draggingDivider = false
        viewport.liveResizing = false
        timelinePane.timeline.liveResizing = false
        // 只是按了一下没拖动，不算数。
        if abs(timelineHeight - before) > 0.5 { UserDefaults.standard.set(Double(timelineHeight), forKey: Self.heightKey) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        canvasPane.layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard bounds.height > 0 else { return }
        appliedStoredHeight = true
        // 窗口变矮时时间线会被挤扁，再变高它不会自己长回来：每次布局都对一下。
        fitTimeline()
    }

    var timelineHeight: CGFloat { timelinePane.frame.height }

    /// 用户拖出来的高度；nil 表示没拖过（或双击分界重置了），高度跟着轨道数走。
    private var manualHeight: CGFloat? {
        guard let stored = UserDefaults.standard.object(forKey: Self.heightKey) as? Double, stored.isFinite, stored > 0 else { return nil }
        return CGFloat(stored)
    }
    /// 现有的轨道全部摆下所需的窗格高度。
    private var contentHeight: CGFloat { timelinePane.fittingHeight }
    /// 时间线最矮能到哪：一般是 `minimumTimelineHeight`，轨道少到连它都用不满时就是"刚好摆下"。
    private var minimumHeight: CGFloat { min(Self.minimumTimelineHeight, contentHeight) }
    /// 窗口里最多能给时间线多高（画布至少留 `minimumCanvasHeight`）。
    private var availableHeight: CGFloat { max(minimumHeight, bounds.height - dividerThickness - Self.minimumCanvasHeight) }
    /// 时间线该有的高度。拖过分界就按拖的来（比轨道高、比轨道矮都行，2026-10-13 用户要求能拖高）；
    /// 没拖过则刚好摆下现有的轨道——只有一两条轨时不占着半个窗口，轨道多了自己长高，
    /// 但自动长高不超过窗口的四成多一点，再多就在里面滚动，不把画布挤扁。
    private var fittedHeight: CGFloat {
        if let manualHeight { return min(availableHeight, max(minimumHeight, manualHeight)) }
        let automaticLimit = max(Self.defaultTimelineHeight, (bounds.height - dividerThickness) * 0.42)
        return min(availableHeight, min(contentHeight, automaticLimit))
    }

    /// 把分界摆到该在的位置。拖分界、拖时间线上的块期间不动，等松手再量。
    private func fitTimeline() {
        guard !detached, appliedStoredHeight, bounds.height > 0, !draggingDivider, !timelinePane.timeline.isDraggingBlocks,
              abs(fittedHeight - timelineHeight) > 0.5 else { return }
        setPosition(bounds.height - dividerThickness - fittedHeight, ofDividerAt: 0)
    }

    /// 偏好被外部改写（设置页或测试）时同步分界。
    private func storedHeightChanged() { fitTimeline() }

    // MARK: NSSplitViewDelegate

    /// 分界最高能拖到哪：画布至少留最小高度。
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.minimumCanvasHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, bounds.height - dividerThickness - minimumHeight)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// 时间线窗格：顶部固定 44 点的 SwiftUI 工具栏、1 点分隔线、其余是原生视口。子视图在尺寸变化时同步摆放。
@MainActor
final class TimelinePaneView: NSView {
    let timeline: TimelineViewportView
    private let toolbar: NSHostingView<AnyView>
    private let toolbarContent: AnyView
    private let separator = NSBox()

    init(model: VideoEditorModel, viewport: TimelineViewport, addFocus: @escaping () -> Void) {
        timeline = TimelineViewportView(model: model, viewport: viewport)
        toolbarContent = AnyView(TimelineToolbar(model: model, viewport: viewport, addFocus: addFocus)
            .background(CaploMaterialBackground(.canvas)).tint(CaploColor.accent))
        toolbar = TransparentEditorHostingView(rootView: toolbarContent)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CaploMetrics.Radius.panel
        layer?.masksToBounds = true
        layer?.borderWidth = CaploMetrics.hairline
        layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        toolbar.sizingOptions = []
        separator.boxType = .separator
        addSubview(timeline)
        addSubview(separator)
        addSubview(toolbar)
        place()
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }

    /// 工具栏、分隔线加上把现有轨道全部摆下的视口高度。
    var fittingHeight: CGFloat { CaploMetrics.toolbarHeight + 1 + timeline.fittingHeight }

    func updateMaterialPreview(opaque: Bool?, contrast: ColorSchemeContrast) {
        timeline.materialOpaqueOverride = opaque
        let content = toolbarContent
        if let opaque {
            toolbar.rootView = AnyView(content.caploMaterialAccessibilityPreview(reduceTransparency: opaque, highContrast: contrast == .increased))
        } else { toolbar.rootView = content }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    private func place() {
        let toolbarHeight = CaploMetrics.toolbarHeight
        toolbar.frame = CGRect(x: 0, y: bounds.height - toolbarHeight, width: bounds.width, height: toolbarHeight)
        separator.frame = CGRect(x: 0, y: bounds.height - toolbarHeight - 1, width: bounds.width, height: 1)
        timeline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - toolbarHeight - 1))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = EditorMaterialDrawing.color(CaploNSColor.glassEdge, appearance: effectiveAppearance)
    }
}

/// 独立工具栏与空态宿主不提供额外窗口底色；玻璃由主窗口和显式表面共同合成。
private final class TransparentEditorHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    /// 纯装饰的浮层设成 true：`NSHostingView` 即使根视图整棵 `allowsHitTesting(false)`，
    /// 命中测试仍会把自己交出去，压在它下面的画布编辑层就一次点击都收不到。
    var passesThroughClicks = false
    override func hitTest(_ point: NSPoint) -> NSView? { passesThroughClicks ? nil : super.hitTest(point) }
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("不支持归档初始化") }
}

/// 预览窗格上的空态与载入提示；帧数据不经 SwiftUI，这里只有两种覆盖状态。
struct CanvasOverlay: View {
    let model: VideoEditorModel
    var body: some View {
        ZStack {
            if (model.edit.duration <= 0) {
                ContentUnavailableView("时间线为空", systemImage: "film", description: Text("撤销删除以恢复片段。"))
            }
            if model.loading {
                ProgressView("载入画面…").padding(CaploMetrics.Spacing.l)
                    .caploMaterial(.raised, cornerRadius: CaploMetrics.Radius.card)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
