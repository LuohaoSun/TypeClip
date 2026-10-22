import Carbon
import AppKit
import CoreGraphics

// 字符 → (虚拟键码, 修饰键) 映射: 用当前键盘布局经 UCKeyTranslate 反查生成,
// 比 Hammerspoon keycodes.map 更正确(适配任意布局, 含 shift/option 层)。
// 布局敲不出的字符(汉字/emoji)不在表中, 由引擎回退 Unicode 注入。
enum Keymap {

    /// 取当前输入源的 Unicode 键盘布局; 失败返回 nil。
    /// 当前源是 IMKit 输入法(中文等)时没有布局数据, 退回 ASCII 源,
    /// 至少让 ASCII 字符仍可反查, 而不是整张表为空。
    static func currentUnicodeLayout() -> UnsafePointer<UCKeyboardLayout>? {
        if let p = unicodeLayout(of: TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()) { return p }
        return unicodeLayout(of: TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue())
    }

    private static func unicodeLayout(of source: TISInputSource?) -> UnsafePointer<UCKeyboardLayout>? {
        guard let source else { return nil }
        guard let cfPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(cfPtr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
    }

    /// 当前输入源 ID(日志用)。
    static func activeLayoutName() -> String {
        let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        guard let source, let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    /// 扫描 0..127 键码 × (无/shift/option/shift+option) 修饰, 反查每个键产出的字符。
    /// 无修饰层最先插入(先到先得), 保证字母等默认不带 shift。
    static func build() -> [Character: (keyCode: CGKeyCode, flags: CGEventFlags)] {
        var map: [Character: (CGKeyCode, CGEventFlags)] = [:]
        guard let layout = currentUnicodeLayout() else { return map }
        // 陷阱: UCKeyTranslate 的 modifiers 参数不是 Carbon 事件修饰常量, 而是
        // "键修饰态字节"= 常量右移 8 位(shiftKey 0x0200 → 0x02, optionKey 0x0800 → 0x08)。
        // 直接传 UInt32(shiftKey) 会一直查到无修饰层——shift 层字符(含大写字母、# 等)
        // 全部反查不到, 只能回退 Unicode 注入, 在堡垒机里就会退化成裸数字/小写。
        // 第二个元素仍是事件用的 CGEventFlags(原值), 两者编码不同。
        let combos: [(UInt32, CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        let keyboardType = UInt32(LMGetKbdType())
        for keyCode in 0..<128 {
            for (mods, flags) in combos {
                var deadKey = UInt32(0)
                var length = 0 // Swift 导入的 UniCharCount 按 Int 处理
                var output = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    mods,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKey,
                    4,
                    &length,
                    &output
                )
                guard status == noErr, length == 1 else { continue }
                let s = String(utf16CodeUnits: output, count: length)
                guard let ch = s.first, s.count == 1 else { continue }
                let scalars = ch.unicodeScalars
                guard scalars.count == 1, let scalar = scalars.first else { continue }
                // 跳过换行/制表等控制字符(引擎单独处理 \n \t), 以及不可见字符
                let v = scalar.value
                if v < 32 || v == 0x7F || (0xF700...0xF8FF).contains(v) || (0x200B...0x200F).contains(v) || v == 0xFEFF { continue }
                if map[ch] == nil { map[ch] = (CGKeyCode(keyCode), flags) }
            }
        }
        return map
    }
}

// 输入法切换: 触发时切到英文(ASCII 布局), 是否切回由设置决定(默认不切回)。
enum IME {

    static func saveCurrent() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    @discardableResult
    static func selectEnglish() -> Bool {
        guard let source = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() else { return false }
        return TISSelectInputSource(source) == noErr
    }

    @discardableResult
    static func restore(_ source: TISInputSource) -> Bool {
        TISSelectInputSource(source) == noErr
    }
}
