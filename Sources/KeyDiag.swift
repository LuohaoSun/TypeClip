import Carbon
import AppKit
import CoreGraphics
import Foundation

/// 诊断模式 v5: 隔离"本地输入法状态"这一变量。
/// 已知: 中文输入法下手工注入 # 8/8 成功; 真实使用(引擎会把输入法切到英文 ABC)约四成失败。
/// 本轮在中文 / 英文 ABC 两种输入法下交替做相同注入, 并用真实热键路径做对照。
/// 触发: TypeClip --notify-keydiag(由常驻 GUI 实例执行; 终端直接跑会因 TCC 权限失败)。
enum KeyDiag {

    private static var running = false

    private static let k3 = CGKeyCode(kVK_ANSI_3)
    private static let kShift = CGKeyCode(kVK_Shift)
    private static let deviceLShift = CGEventFlags(rawValue: 0x0002) // NX_DEVICELSHIFTKEYMASK
    private static let shiftWithDevice: CGEventFlags = [.maskShift, deviceLShift]

    private static func ms(_ v: Double) {
        if v > 0 { usleep(useconds_t(v * 1000)) }
    }

    private static func send(_ src: CGEventSource?, _ keyCode: CGKeyCode, _ flags: CGEventFlags,
                            _ down: Bool, type: CGEventType = .keyDown, unicode: String? = nil) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { return }
        e.type = type
        e.flags = flags
        if let unicode {
            let units = Array(unicode.utf16)
            units.withUnsafeBufferPointer { buffer in
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            }
        }
        e.post(tap: .cgSessionEventTap)
    }

    /// 切到英文(ASCII)或恢复给定输入源; 返回当前源名用于日志。
    private static func selectASCII(_ ascii: Bool, restoreTo: TISInputSource?) {
        if ascii {
            _ = IME.selectEnglish()
        } else if let restoreTo {
            _ = IME.restore(restoreTo)
        }
        ms(250) // 等输入源切换生效
    }

    private static func typeMarker(_ n: Int) {
        let digitKey: [Int] = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        guard n >= 1, n <= digitKey.count else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        for (keyCode, text) in [(CGKeyCode(kVK_ANSI_V), "v"), (CGKeyCode(digitKey[n - 1]), "\(n)")] {
            send(src, keyCode, [], true, unicode: text)
            ms(45)
            send(src, keyCode, [], false, unicode: text)
            ms(75)
        }
    }

    /// 手工注入, 逐字精确复刻引擎的时序: shift↓ (50) 3↓ (60) 3↑ (50) shift↑ ── 下一个 shift↓
    /// 在上一字符 shift↑ 之后 postGapMS 毫秒。引擎实际是 50ms(字符周期 210ms)。
    private static func manualHash(_ count: Int, postGapMS: Double) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            send(src, kShift, shiftWithDevice, true, type: .flagsChanged)
            ms(50)
            send(src, k3, shiftWithDevice, true, unicode: "#")
            ms(60)
            send(src, k3, shiftWithDevice, false, unicode: "#")
            ms(50)
            send(src, kShift, [], false, type: .flagsChanged)
            ms(postGapMS)
        }
    }

    /// 真实热键路径: 剪贴板放 8 个 #, 发 drive 通知, 用用户实际配置(含 autoIME)走完整链路。
    private static func realHotkeyPath() {
        let pb = NSPasteboard.general
        let backup = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(String(repeating: "#", count: 8), forType: .string)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.slh.typeclip.drive"), object: nil,
            userInfo: nil, deliverImmediately: true
        )
        ms(6000)
        pb.clearContents()
        if let backup { pb.setString(backup, forType: .string) }
    }

    private static func log(_ line: String) {
        print(line)
        fflush(stdout)
        TypeLog.appendDiag(line)
        NSLog("TypeClip keydiag: \(line)")
    }

    static func run() {
        guard !running else { log("已有诊断在运行, 忽略本次触发"); return }
        running = true
        defer { running = false }

        try? FileManager.default.removeItem(atPath: TypeLog.diagPath)
        let savedIME = IME.saveCurrent()
        let userName = {
            guard let s = savedIME, let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "?" }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }()

        log("== 键盘注入诊断 v5: 刻画差异来源 ==")
        log("你当前的输入法: \(userName)")
        log("A/B 中文输入法, C/D 英文 ABC, E/F 真实热键路径; A/C 用引擎时序(字符周期 210ms), B/D 宽松(shift 松开后 200ms)")
        log("准备中: 10 次 beep 后开始, 请立刻聚焦目标输入框")
        for _ in 0..<10 { NSSound.beep(); ms(1000) }
        log("开始注入")

        // 6 组, 每组 8 个 #
        let groups: [(String, Bool?, Double, Bool)] = [   // (名字, ascii?, postGap, 真实路径?)
            ("A 中文 + 手工(引擎时序 50ms)", false, 50, false),
            ("B 中文 + 手工(宽松 200ms)", false, 200, false),
            ("C ABC + 手工(引擎时序 50ms)", true, 50, false),
            ("D ABC + 手工(宽松 200ms)", true, 200, false),
            ("E 真实热键路径(autoIME 生效)", nil, 0, true),
            ("F 真实热键路径(重复)", nil, 0, true),
        ]

        for (i, (name, ascii, postGap, real)) in groups.enumerated() {
            log(">>> 组 \(i + 1): \(name)")
            NSSound.beep()
            ms(350)
            typeMarker(i + 1)
            ms(250)
            if real {
                realHotkeyPath()
            } else {
                selectASCII(ascii ?? false, restoreTo: savedIME)
                log("    当前输入源: \(Keymap.activeLayoutName())")
                manualHash(8, postGapMS: postGap)
            }
            ms(1200)
        }
        if let savedIME { IME.restore(savedIME) }
        log("== 完成: 期望 v1~v6 各 8 个字符; 注入时刻表见 \(TypeLog.path)(需打开「诊断日志」) ==")
    }
}
