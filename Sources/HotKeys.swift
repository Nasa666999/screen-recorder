import Carbon
import Foundation

/// 业务作用: 将系统热键事件转交应用主线程，不监听用户的其他键盘输入。
/// 参数说明:
/// - next: 系统事件处理链。
/// - event: 当前热键事件。
/// - context: 热键控制器的非持有引用。
/// 返回: 已识别事件返回成功，其他事件交还系统。
private func recorderHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else {
        return OSStatus(eventNotHandledErr)
    }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == 0x5352_4352 else {
        return OSStatus(eventNotHandledErr)
    }
    let controller = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
    let key = identifier.id
    DispatchQueue.main.async {
        if key == 1 {
            controller.onInvoke?()
        } else if key == 2 {
            controller.onStop?()
        }
    }
    return noErr
}

@MainActor
final class HotKeys {
    var onInvoke: (() -> Void)?
    var onStop: (() -> Void)?
    private var invoke: EventHotKeyRef?
    private var stop: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// 业务作用: 注册公开热键事件处理器，不申请输入监视权限。
    /// 参数说明: 无。
    /// 返回: 处理器在控制器生命周期内有效。
    init() {
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            recorderHotKeyHandler,
            1,
            &specification,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    /// 业务作用: 控制器销毁时归还本应用取得的热键和事件处理器。
    /// 参数说明: 无。
    /// 返回: 不影响系统和其他应用的绑定。
    deinit {
        if let invoke {
            UnregisterEventHotKey(invoke)
        }
        if let stop {
            UnregisterEventHotKey(stop)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    /// 业务作用: 尝试取得调用快捷键，系统原绑定保留时允许菜单栏继续使用。
    /// 参数说明: 无。
    /// 返回: 注册成功返回真；冲突时不覆盖其他绑定。
    func registerInvocation() -> Bool {
        if invoke != nil {
            return true
        }
        guard !systemShortcutEnabled(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)) else {
            return false
        }
        return RegisterEventHotKey(
            UInt32(kVK_ANSI_5),
            UInt32(cmdKey | shiftKey),
            EventHotKeyID(
                signature: 0x5352_4352,
                id: 1
            ),
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &invoke
        ) == noErr
    }

    /// 业务作用: 仅在录制相关阶段持有停止快捷键，空闲时归还系统。
    /// 参数说明:
    /// - enabled: 是否需要停止本应用的会话。
    /// 返回: 启用失败时返回假，菜单栏停止入口保持可用。
    func setStopEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            if let stop {
                UnregisterEventHotKey(stop)
                self.stop = nil
            }
            return true
        }
        if stop != nil {
            return true
        }
        guard !systemShortcutEnabled(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | controlKey))
        else {
            return false
        }
        return RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(cmdKey | controlKey),
            EventHotKeyID(
                signature: 0x5352_4352,
                id: 2
            ),
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &stop
        ) == noErr
    }

    /// 业务作用: 注册前复验系统公开的快捷键占用，避免收到成功回执却无法触发。
    /// 参数说明:
    /// - keyCode: 计划使用的虚拟按键编号。
    /// - modifiers: 计划使用的 Carbon 修饰键组合。
    /// 返回: 系统已启用同一组合或无法核实时返回真，不抢占既有绑定。
    private func systemShortcutEnabled(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr,
            let entries = values?.takeRetainedValue() as? [[String: Any]]
        else {
            return true
        }
        return entries.contains {
            ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && ($0[kHISymbolicHotKeyCode as String] as? UInt32) == keyCode
                && ($0[kHISymbolicHotKeyModifiers as String] as? UInt32) == modifiers
        }
    }
}
