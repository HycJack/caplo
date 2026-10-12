import Foundation

/// 新录制第一次打开时带上哪些效果（设置 → 录制 → 新录制的默认效果）。
/// 只决定起点：进了编辑器每一项都还能开、能调；已经有编辑数据的工程不受它影响。
public struct NewProjectDefaults: Sendable, Equatable {
    /// 自动聚焦开不开。关着时不生成镜头；之后在聚焦面板打开开关，再按当时的参数生成。
    public var automaticFocus = true
    /// 光标效果（样式、平滑、回弹、运动模糊、点击高亮）。关着时用录下来的原始光标。
    public var cursorEffects = true
    /// 画面布局（比例、背景、边距、圆角、阴影、裁切）；nil 用内置默认。背景图片属于工程，不随它带过来。
    public var layout: CanvasLayout?
    public init() {}
}
