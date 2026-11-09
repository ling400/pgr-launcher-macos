import Foundation
import Combine
import ApplicationServices
import CoreGraphics

/// Global keyboard remapping based on a real CGEventTap.
///
/// Only active while the game is running (AppState calls `start()` on launch and `stop()` on exit).
/// Events are rewritten in place while the event tap is installed, which both replaces the
/// physical key and prevents the original key from reaching the system (no re-injection loops).
final class KeyMapper: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var accessibilityGranted: Bool = false
    @Published var mappings: [KeyMapping] = []

    private let logger: Logger
    private let lock = NSLock()
    /// source key code → target key code, rebuilt by `setMappings`.
    private var keyMap: [Int64: Int64] = [:]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Capture state is main-thread only.
    private var captureTap: CFMachPort?
    private var captureSource: CFRunLoopSource?
    private var captureContinuation: CheckedContinuation<(code: Int, label: String)?, Never>?
    private var captureTimeoutWorkItem: DispatchWorkItem?
    private var captureAbortPending = false

    init(logger: Logger) {
        self.logger = logger
        refreshAccessibilityStatus()
    }

    // MARK: Accessibility

    func refreshAccessibilityStatus() {
        let granted = AXIsProcessTrusted()
        publish {
            if self.accessibilityGranted != granted {
                self.accessibilityGranted = granted
            }
        }
    }

    /// Ask macOS to show the Accessibility permission prompt
    /// (System Settings → Privacy & Security → Accessibility).
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        publish {
            self.accessibilityGranted = granted
        }
        if granted {
            ServiceSupport.logInfo(logger, "已获得辅助功能（Accessibility）权限")
        } else {
            ServiceSupport.logWarn(
                logger,
                "尚未获得辅助功能权限：请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 PGRLauncher，然后重新启用键位映射"
            )
        }
    }

    // MARK: Mappings

    func setMappings(_ mappings: [KeyMapping]) {
        let snapshot = mappings
        var map: [Int64: Int64] = [:]
        for mapping in snapshot where mapping.enabled {
            map[Int64(mapping.sourceKeyCode)] = Int64(mapping.targetKeyCode)
        }
        lock.lock()
        keyMap = map
        lock.unlock()
        publish {
            self.mappings = snapshot
        }
    }

    // MARK: Start / stop

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        if isRunning { return }
        refreshAccessibilityStatus()
        guard accessibilityGranted else {
            ServiceSupport.logError(
                logger,
                "键位映射未启用：缺少辅助功能（Accessibility）权限。请到 系统设置 → 隐私与安全性 → 辅助功能 勾选 PGRLauncher，然后重试。"
            )
            requestAccessibilityPermission()
            return
        }
        guard installEventTap() else { return }
        publish { self.isRunning = true }
        lock.lock()
        let count = keyMap.count
        lock.unlock()
        ServiceSupport.logInfo(logger, "键位映射已启用（\(count) 条规则）")
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stop() }
            return
        }
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if isRunning {
            publish { self.isRunning = false }
            ServiceSupport.logInfo(logger, "键位映射已停止")
        } else {
            publish { self.isRunning = false }
        }
    }

    private func installEventTap() -> Bool {
        lock.lock()
        let alreadyInstalled = eventTap != nil
        lock.unlock()
        if alreadyInstalled { return true }

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ServiceSupport.logError(
                logger,
                "创建 CGEventTap 失败：请确认已在 系统设置 → 隐私与安全性 → 辅助功能 中授权 PGRLauncher（授权后可能需要重启应用）。"
            )
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            ServiceSupport.logError(logger, "无法为事件监听创建 RunLoop source")
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        eventTap = tap
        runLoopSource = source
        lock.unlock()
        return true
    }

    // MARK: Event handling

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let mapper = Unmanaged<KeyMapper>.fromOpaque(userInfo).takeUnretainedValue()
        return mapper.handleTapEvent(type: type, event: event)
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                ServiceSupport.logWarn(logger, "系统临时禁用了键盘事件监听，已重新启用")
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        lock.lock()
        let target = keyMap[keyCode]
        lock.unlock()
        guard let target, target != keyCode else {
            return Unmanaged.passUnretained(event)
        }
        // Rewriting the event in place: downstream consumers (Wine / the game) see the
        // target key, and because the mutated event replaces the original nothing else
        // sees the physical key. This avoids re-injecting events into the same tap.
        event.setIntegerValueField(.keyboardEventKeycode, value: target)
        return Unmanaged.passUnretained(event)
    }

    // MARK: Key capture (settings UI)

    /// Block until the user presses a key, then return its key code and a label.
    func captureNextKey(timeout: TimeInterval = 30) async -> (code: Int, label: String)? {
        let granted = await MainActor.run { () -> Bool in
            self.refreshAccessibilityStatus()
            return self.accessibilityGranted
        }
        guard granted else {
            await MainActor.run {
                self.requestAccessibilityPermission()
            }
            ServiceSupport.logError(
                logger, "无法录入按键：缺少辅助功能权限，请先在系统设置中授权 PGRLauncher")
            return nil
        }

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<(code: Int, label: String)?, Never>) in
                Task { @MainActor in
                    self.beginCapture(continuation: continuation, timeout: timeout)
                }
            }
        }, onCancel: {
            Task { @MainActor in
                if self.captureContinuation != nil || self.captureTap != nil {
                    self.finishCapture(nil)
                } else {
                    self.captureAbortPending = true
                }
            }
        })
    }

    private func beginCapture(
        continuation: CheckedContinuation<(code: Int, label: String)?, Never>,
        timeout: TimeInterval
    ) {
        if captureAbortPending {
            captureAbortPending = false
            continuation.resume(returning: nil)
            return
        }
        if captureContinuation != nil || captureTap != nil {
            finishCapture(nil)
        }
        guard installCaptureTap() else {
            continuation.resume(returning: nil)
            return
        }
        captureContinuation = continuation
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishCapture(nil)
        }
        captureTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1.0, timeout), execute: workItem)
        ServiceSupport.logInfo(logger, "等待按键录入…（按 Esc 取消）")
    }

    private func installCaptureTap() -> Bool {
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.captureCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ServiceSupport.logError(logger, "无法创建按键录入事件监听（缺少辅助功能权限）")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        captureTap = tap
        captureSource = source
        return true
    }

    private static let captureCallback: CGEventTapCallBack = { _, _, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let mapper = Unmanaged<KeyMapper>.fromOpaque(userInfo).takeUnretainedValue()
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if code == 53 {
            // Esc cancels capture (return false result without surfacing it as a mapping).
            mapper.finishCapture(nil)
            return nil
        }
        mapper.finishCapture((code: code, label: KeyMapper.label(for: code)))
        return nil
    }

    private func finishCapture(_ result: (code: Int, label: String)?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.finishCapture(result) }
            return
        }
        captureTimeoutWorkItem?.cancel()
        captureTimeoutWorkItem = nil
        let tap = captureTap
        let source = captureSource
        captureTap = nil
        captureSource = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let continuation = captureContinuation {
            captureContinuation = nil
            continuation.resume(returning: result)
        }
    }

    // MARK: Labels

    /// Human readable label for a macOS virtual key code.
    static func label(for keyCode: Int) -> String {
        KeyCodeNames.name(for: keyCode)
    }

    /// Run a UI state change on the main thread.
    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

enum KeyCodeNames {
    static func name(for code: Int) -> String {
        if let name = map[code] { return name }
        return "KeyCode \(code)"
    }

    static let map: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab",
        49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        55: "Cmd", 56: "Shift", 57: "CapsLock", 58: "Option", 59: "Ctrl", 60: "RightShift",
        61: "RightOption", 62: "RightCtrl", 63: "Fn",
        64: "F17", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter",
        78: "-", 79: "F18", 80: "F19", 81: "=", 82: "0", 83: "1", 84: "2",
        85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "PageUp", 117: "ForwardDelete", 118: "F4",
        119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "Left",
        124: "Right", 125: "Down", 126: "Up"
    ]
}
