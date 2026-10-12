import Foundation

/// 录制时记下的一次按键。时间在素材域（与指针事件同一口径），所以剪一刀、删一段，按键跟着内容走。
///
/// 只记"按下了哪个键"，不记输入法合成出来的文字；录制设置选"仅快捷键"时，不带 ⌘ ⌃ ⌥ 的普通按键根本不进这个文件。
public struct KeyPress: Codable, Equatable, Sendable {
    /// 修饰键位：存盘用自己的定义，不依赖系统常量的数值。
    public struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
        /// 有这三个之一才算"快捷键"；只按着 ⇧ 是在打大写或符号。
        public static let shortcut: Modifiers = [.command, .option, .control]
    }
    public var time: Double
    /// 系统虚拟键码：功能键（回车、方向键、F1…）靠它认，与键盘布局无关。
    public var keyCode: Int
    public var modifiers: Modifiers
    /// 这个键在当时键盘布局下不带修饰键打出的字符（⌘⇧4 记 "4" 而不是 "$"）；功能键为空。
    public var label: String?
    public init(time: Double, keyCode: Int, modifiers: Modifiers, label: String? = nil) {
        self.time = time; self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }

    public var isShortcut: Bool { !modifiers.isDisjoint(with: .shortcut) || Self.functionKeys[keyCode] != nil }
    public var isValid: Bool { time.isFinite && time >= 0 && (0...0xFFFF).contains(keyCode) && (label?.count ?? 0) <= 8 }

    /// Esc 与 F1–F12：单按也是"快捷键"，不是打字。
    static let functionKeys: [Int: String] = [
        53: "esc", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    /// 不产生可见字符的键：画成符号。
    static let namedKeys: [Int: String] = [
        36: "⏎", 76: "⌅", 48: "⇥", 49: "space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
    /// 键帽上的字：功能键与符号键按键码取，其余用录制时记下的字符（字母大写）。认不出来的键不显示。
    public var keyCap: String? {
        if let name = Self.functionKeys[keyCode] ?? Self.namedKeys[keyCode] { return name }
        guard let label, !label.isEmpty, label.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return label.uppercased()
    }
    /// 一组键帽：修饰键按系统菜单的顺序（⌃ ⌥ ⇧ ⌘）排在前面。
    public var keyCaps: [String]? {
        guard let cap = keyCap else { return nil }
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        return caps + [cap]
    }
}

/// 录制时记哪些按键。存在偏好设置与工程的采集信息里。
public enum KeyCaptureMode: String, Codable, CaseIterable, Sendable {
    case off, shortcuts, all
    public var title: String {
        switch self { case .off: String(localized: "关"); case .shortcuts: String(localized: "仅快捷键"); case .all: String(localized: "全部按键") }
    }
    /// 这一档下这次按键要不要存盘。
    public func records(_ press: KeyPress) -> Bool {
        switch self { case .off: false; case .shortcuts: press.isShortcut; case .all: true }
    }
}

/// 按键显示的样式。位置在输出画面上（不跟着镜头推近放大），尺寸按 1080 参考高度，与字幕同一口径。
public struct KeystrokeStyle: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case dark, light
        public var title: String { switch self { case .dark: String(localized: "深色"); case .light: String(localized: "浅色") } }
    }
    public enum Filter: String, Codable, CaseIterable, Sendable {
        case shortcuts, all
        public var title: String { switch self { case .shortcuts: String(localized: "仅快捷键"); case .all: String(localized: "全部按键") } }
    }
    public var enabled = true
    public var filter: Filter = .all
    public var theme: Theme = .dark
    /// 键帽组中心在输出画面上的位置，0…1，y 从上往下。
    public var x = 0.5
    public var y = 0.9
    /// 键帽大小的倍率；1 时键帽高 54（1080 参考高度）。
    public var size = 1.0
    /// 按下之后停留多久再淡出。
    public var hold = 1.2
    /// 播放头处没有按键时，画一组示例键帽：编辑器在"按键"面板开着时打开它，调位置、大小才看得见落点。
    /// 只是预览用的标记，不存盘（不在 `CodingKeys` 里），导出前清掉。
    public var sample = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, filter, theme, x, y, size, hold }
    /// 示例键帽的内容。
    public static let sampleGroups = [["⌘", "K"]]

    public static let sizeRange = 0.6...2.0
    public static let holdRange = 0.4...4.0
    /// 淡入、淡出的时长。
    public static let fadeIn = 0.08
    public static let fadeOut = 0.25
    /// 连续打字时并成一排显示：两次按键间隔不超过这个值就接在后面，最多显示最近这么多个。
    public static let typingGap = 0.7
    public static let typingLimit = 8

    public var isValid: Bool {
        x.isFinite && (0...1).contains(x) && y.isFinite && (0...1).contains(y)
            && size.isFinite && Self.sizeRange.contains(size) && hold.isFinite && Self.holdRange.contains(hold)
    }
}

/// 这一帧要画的按键：若干组键帽（快捷键是一组；连续打字每个键一组）和整体不透明度。
public struct KeystrokeFrame: Equatable, Sendable {
    public var groups: [[String]]
    public var alpha: Double
    public var style: KeystrokeStyle
    public init(groups: [[String]], alpha: Double, style: KeystrokeStyle) { self.groups = groups; self.alpha = alpha; self.style = style }
}

/// 录制下来的全部按键，按素材时间排好；逐帧二分查询。
public struct KeyTimeline: Sendable {
    public let presses: [KeyPress]
    public init(presses: [KeyPress] = []) {
        self.presses = presses.filter { $0.isValid && $0.keyCap != nil }.sorted { $0.time < $1.time }
    }
    public var isEmpty: Bool { presses.isEmpty }
    /// 录下来的按键里有没有不带修饰键的普通键：没有就不必给"仅快捷键 / 全部按键"的选择。
    public var hasPlainKeys: Bool { presses.contains { !$0.isShortcut } }

    /// 成片时刻 `time` 该显示的按键；不显示返回 nil。
    /// 只看当前片段里、播放头之前的按键：剪掉的那段里按的键不会漏到下一个片段上。
    public func frame(at time: Double, timeline: TimelineIndex, style: KeystrokeStyle?) -> KeystrokeFrame? {
        let style = style ?? KeystrokeStyle()
        guard style.enabled, style.isValid, time.isFinite else { return nil }
        // 真按键优先；这一刻没有、又开着示例，就画示例。
        return recorded(at: time, timeline: timeline, style: style)
            ?? (style.sample ? KeystrokeFrame(groups: KeystrokeStyle.sampleGroups, alpha: 1, style: style) : nil)
    }

    private func recorded(at time: Double, timeline: TimelineIndex, style: KeystrokeStyle) -> KeystrokeFrame? {
        guard !presses.isEmpty, let source = timeline.sourceTime(at: time),
              let clipIndex = timeline.clipIndex(at: min(time, max(0, timeline.duration - 0.00001))) else { return nil }
        let clipStart = timeline.clips[clipIndex].sourceStart
        var lower = 0, upper = presses.count
        while lower < upper { let middle = (lower + upper) / 2; if presses[middle].time <= source { lower = middle + 1 } else { upper = middle } }
        // 往回找最近一次要显示的按键；过了停留加淡出的时间就不必再找。
        let visible = style.hold + KeystrokeStyle.fadeOut
        func shown(_ press: KeyPress) -> Bool { style.filter == .all || press.isShortcut }
        var index = lower - 1
        while index >= 0, !shown(presses[index]) {
            guard source - presses[index].time < visible else { return nil }
            index -= 1
        }
        guard index >= 0, presses[index].time >= clipStart else { return nil }
        let latest = presses[index], elapsed = source - latest.time
        guard elapsed < visible, let caps = latest.keyCaps else { return nil }
        var groups = [caps], first = latest
        // 连续打字并成一排：从最近一次往回接，遇到快捷键、间隔太长或出了片段就停。
        if !latest.isShortcut {
            groups = [[caps.last!]]
            var cursor = index - 1
            while cursor >= 0, groups.count < KeystrokeStyle.typingLimit {
                let press = presses[cursor]
                guard !press.isShortcut, press.time >= clipStart, first.time - press.time <= KeystrokeStyle.typingGap, let cap = press.keyCap else { break }
                groups.insert([cap], at: 0); first = press; cursor -= 1
            }
        }
        let fadeIn = min(1, max(0, (source - first.time) / KeystrokeStyle.fadeIn))
        let fadeOut = elapsed <= style.hold ? 1 : max(0, 1 - (elapsed - style.hold) / KeystrokeStyle.fadeOut)
        let alpha = fadeIn * fadeOut
        return alpha > 0.002 ? KeystrokeFrame(groups: groups, alpha: alpha, style: style) : nil
    }
}
