import AppKit
import CoreMedia
import EditingCore

/// 只在录制期间、且用户打开了"记录按键"时监听键盘：记下按了哪个键，供编辑器把快捷键显示在画面上。
///
/// 用只读的事件监听（listen-only tap），对应系统的"输入监控"权限——比辅助功能权限窄，读得到按键、改不了也拦不住。
/// "仅快捷键"一档下，不带 ⌘ ⌃ ⌥ 的普通按键在这里就丢掉，不进内存也不落盘。
/// 密码框等安全输入期间系统本来就不把按键交给监听方。本应用在前台时的按键不记（那是在操作 Caplo 自己）。
@MainActor
final class KeyRecorder {
    private let mode: KeyCaptureMode
    private let clock: CMClock
    private let writer: SegmentedCaptureWriter
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(mode: KeyCaptureMode, clock: CMClock?, writer: SegmentedCaptureWriter) {
        self.mode = mode; self.clock = clock ?? CMClockGetHostTimeClock(); self.writer = writer
    }

    /// 没有输入监控权限时建不起监听，返回 false：录制照常进行，只是这次没有按键。
    @discardableResult func start() -> Bool {
        guard mode != .off, tap == nil, CGPreflightListenEventAccess() else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                          callback: keyTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap; self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        // 回调太慢或用户输入被系统判定受阻时监听会被停用：重新打开，否则后半段录制就没有按键了。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !NSApp.isActive else { return }
        let flags = event.flags
        var modifiers: KeyPress.Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        let now = CMClockGetTime(clock).seconds
        let age = max(0, ProcessInfo.processInfo.systemUptime - Double(event.timestamp) / 1_000_000_000)
        var press = KeyPress(time: now - min(age, 0.5), keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: modifiers)
        // 先按键码和修饰键判断要不要记：不记的按键连它是哪个字符都不去取。
        guard mode.records(press) else { return }
        press.label = NSEvent(cgEvent: event)?.characters(byApplyingModifiers: []).map { String($0.prefix(8)) }
        writer.appendKey(press)
    }
}

/// 系统要的是 C 函数指针，不能捕获上下文：录制器经 `userInfo` 传进来。监听源挂在主运行循环上，回调就在主线程。
private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let info {
        let recorder = Unmanaged<KeyRecorder>.fromOpaque(info).takeUnretainedValue()
        // 事件只在这一次回调里同步读取，不会带出主线程。
        nonisolated(unsafe) let current = event
        MainActor.assumeIsolated { recorder.handle(type: type, event: current) }
    }
    return Unmanaged.passUnretained(event)
}
