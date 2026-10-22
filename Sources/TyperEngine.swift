import Carbon
import AppKit
import CoreGraphics

/// 敲入引擎: 把文本以"按下 → 按住 hold → 抬起"的真实按键形状逐字符敲进当前焦点窗口。
/// 当前键盘布局能敲出的字符走真实键码, 需要 shift/option 的字符会合成 flagsChanged 修饰键
/// 事件; 连续需要相同修饰键的字符, 修饰键只按一次并全程保持(与真人一致)。
/// 布局敲不出的字符(汉字/emoji)回退 Unicode 注入。
/// 与已验证的 Hammerspoon 版语义一致: 首字符前 lead 缓冲、字符间隔+jitter、
/// 热键再按一次立即中断(runId 作废未触发的事件)。
///
/// 执行模型: 先按配置把所有事件编排成带绝对偏移的时间表, 再由专用线程按绝对时刻
/// 逐个发送。不用 GCD 定时器逐事件调度——定时器截止时间会被合并/推迟, 使修饰键与字符
/// 的间隔被吞掉(远程端来不及登记 shift, shift+3 退化成裸 3); 手工按固定间隔逐个发送
/// 才是稳定可行的方式。
final class TyperEngine {

    struct Config {
        var interval: TimeInterval   // 相邻字符 keyDown 间隔
        var hold: TimeInterval       // 每次按键按住时长
        var jitter: TimeInterval     // 每字符附加随机抖动上限
        var lead: TimeInterval       // 首字符前缓冲(等热键修饰键松开)
        var autoIME: Bool            // 触发时自动切英文输入法
        var restoreIME: Bool         // 结束后是否恢复原输入法
        var modifierDelay: TimeInterval = 0.10 // 修饰键事件与其前后字符事件之间的间隔(给远程转发层登记修饰状态的时间)。50ms 时堡垒机远程端偶发来不及登记 shift, # 退化成裸 3; 100ms 为实测稳定的量级
        /// 是否把逐字符注入路径与事件时刻表写进日志。默认关。
        /// 那两段内容里带着被敲入的字符本身, 也就是剪贴板内容的明文;
        /// 只排查字符路径(比如 # 退化成 3)时才打开, 平时日志只留不含字符的配置头与统计。
        var debugLog: Bool = false
    }

    private(set) var activeUntil = Date.distantPast
    private var savedSource: TISInputSource?
    private var lastCfg: Config?

    // runId 保护: 主线程写, 发送线程读。
    private let runLock = NSLock()
    private var runId = 0

    /// (已敲入字符数, 总数)
    var onProgress: ((Int, Int) -> Void)?
    var onFinish: (() -> Void)?

    var isActive: Bool { Date() < activeUntil }
    var currentRun: Int {
        runLock.lock(); defer { runLock.unlock() }
        return runId
    }

    @discardableResult
    private func nextRunId() -> Int {
        runLock.lock(); defer { runLock.unlock() }
        runId += 1
        return runId
    }

    private func isCurrent(_ id: Int) -> Bool {
        runLock.lock(); defer { runLock.unlock() }
        return runId == id
    }

    /// 立即中断: 作废所有未触发的事件(发送线程检查 runId, 过期即停)。
    func cancel() {
        nextRunId()
        activeUntil = .distantPast
        releaseStickyModifiers()
        if let cfg = lastCfg, cfg.restoreIME, let source = savedSource {
            IME.restore(source)
        }
        savedSource = nil
    }

    /// 中断兜底: 修饰键按下后、抬起前被打断时, 抬起事件不会再发,
    /// 补发 shift/option 的 flagsChanged(flags 为空 = 全部松开)避免卡在按下状态
    /// (多余的抬起无副作用)。
    private func releaseStickyModifiers() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for key in [CGKeyCode(kVK_Shift), CGKeyCode(kVK_Option)] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { continue }
            event.type = .flagsChanged
            event.flags = []
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// 清洗剪贴板文本: 去 \r 和控制字符(保留 \n \t)、去零宽字符、去结尾换行。
    static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v == 13 { continue }
            if v == 10 || v == 9 { scalars.append(scalar); continue }
            if v < 32 || v == 0x7F || (0xF700...0xF8FF).contains(v) || (0x200B...0x200F).contains(v) || v == 0xFEFF { continue }
            scalars.append(scalar)
        }
        var text = String(scalars)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    // MARK: - 时间表

    /// 单个待发事件。
    private struct Step {
        enum Action {
            case modifier(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags)
            case key(keyCode: CGKeyCode, flags: CGEventFlags, down: Bool, unicode: Character?)
        }
        let offset: TimeInterval
        let action: Action
        let label: String        // 时间轴日志用
        let progress: Int?       // 非 nil 时上报 "已敲入 n/total"
    }

    // MARK: - 发送

    /// 一次敲入的执行结果, 用于落盘日志(不含被敲入的字符)。
    struct RunResult {
        var aborted: Bool
        var eventsSent: Int
        var eventsTotal: Int
        var selfHeals: Int        // 修饰位丢失后补发 flagsChanged 的次数
        var elapsed: TimeInterval
        var timeline: [String]    // 仅 debugLog 时有内容
    }

    /// 按时间表逐个发送: 睡到该事件的绝对时刻再 post, 保证间隔精确(不受队列/定时器合并影响)。
    private func runSchedule(_ steps: [Step], myRun: Int, source: CGEventSource?,
                             total: Int, modifierDelay: TimeInterval, debugLog: Bool,
                             restoreSource: TISInputSource?, restore: Bool,
                             started: Date, finished: @escaping (RunResult) -> Void) {
        var log: [String] = []
        var sent = 0
        var selfHeals = 0

        func alive() -> Bool { isCurrent(myRun) }

        /// 睡到绝对时刻; 期间每 20ms 检查一次取消。
        func sleep(until target: Date) -> Bool {
            while true {
                if !alive() { return false }
                let remain = target.timeIntervalSinceNow
                if remain <= 0 { return true }
                Thread.sleep(forTimeInterval: min(remain, 0.02))
            }
        }

        var aborted = false
        for step in steps {
            guard sleep(until: started.addingTimeInterval(step.offset)) else { aborted = true; break }

            // 自愈: 发带修饰位的字符前核对会话修饰状态; 合成 flagsChanged 偶发被合并/漏发,
            // 丢失时补发一次再等一个 modifierDelay, 避免 shift+3 在远程端退化成裸 3。
            if case let .key(_, flags, down, _) = step.action, down {
                let state = CGEventSource.flagsState(.combinedSessionState)
                var want = CGEventFlags([])
                var repaired = ""
                for (key, mask) in [(CGKeyCode(kVK_Shift), CGEventFlags.maskShift),
                                    (CGKeyCode(kVK_Option), CGEventFlags.maskAlternate)] {
                    guard flags.contains(mask), !state.contains(mask) else { continue }
                    want.formUnion(Self.modifierBits(key))
                    post(.modifier(keyCode: key, down: true, flags: want), source: source)
                    repaired += Self.modTag(key) + "↓✚"
                }
                if !repaired.isEmpty {
                    selfHeals += 1
                    if debugLog, log.count < 500 {
                        log.append(String(format: "%.3f %@(自愈补发)", Date().timeIntervalSince(started), repaired))
                    }
                    guard sleep(until: Date().addingTimeInterval(modifierDelay)) else { aborted = true; break }
                }
            }

            post(step.action, source: source)
            sent += 1
            if debugLog, log.count < 500 {
                log.append(String(format: "%.3f %@", Date().timeIntervalSince(started), step.label))
            }
            if let n = step.progress {
                DispatchQueue.main.async { [weak self] in
                    self?.onProgress?(n, total)
                }
            }
        }

        if !aborted, alive() {
            // 所有事件发完, 等 duration 到点后收尾(时长含尾部余量)。
            if let last = steps.last {
                _ = sleep(until: started.addingTimeInterval(last.offset + 0.15))
            }
        }

        let result = RunResult(aborted: aborted, eventsSent: sent, eventsTotal: steps.count,
                               selfHeals: selfHeals, elapsed: Date().timeIntervalSince(started),
                               timeline: log)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if restore, let src = restoreSource { IME.restore(src) }
            self.savedSource = nil
            finished(result)
            if !aborted { self.onFinish?() }
        }
    }

    private func post(_ action: Step.Action, source: CGEventSource?) {
        switch action {
        case let .modifier(keyCode, down, flags):
            // 修饰键必须是 flagsChanged 类型事件: 真实键盘的修饰键从不产生 keyDown/keyUp,
            // 远程客户端靠 flagsChanged 跟踪修饰状态——实测给 shift 发 keyDown/keyUp 时
            // 堡垒机不认(shift+3 退化成裸 3), 发 flagsChanged 才正确上屏 #。
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
            event.type = .flagsChanged
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        case let .key(keyCode, flags, down, unicode):
            // 字符事件: flags 带修饰位(含设备位), 并像真实事件一样写入该字符的 unicode 串
            // (真实键盘事件由系统填好, 合成事件不填, 读 unicode 串的接收方会拿不到字符)。
            // 注意: 不要加 .maskNonCoalesced——带它的合成事件会被部分远程客户端当两个事件处理。
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
            event.flags = flags
            if let unicode {
                let units = Array(String(unicode).utf16)
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
                }
            }
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - 修饰键工具

    /// 修饰键的修饰位 + 设备位(区分左右): NX_DEVICELSHIFTKEYMASK / NX_DEVICELALTKEYMASK。
    private static func modifierBits(_ keyCode: CGKeyCode) -> CGEventFlags {
        if Int(keyCode) == Int(kVK_Shift) { return [.maskShift, CGEventFlags(rawValue: 0x0002)] }
        if Int(keyCode) == Int(kVK_Option) { return [.maskAlternate, CGEventFlags(rawValue: 0x0020)] }
        return []
    }

    private static func modTag(_ key: CGKeyCode) -> String { Int(key) == Int(kVK_Shift) ? "S" : "A" }

    // MARK: - 入口

    /// 开始敲入: 布局能敲出的字符走真实键码(带修饰键时显式合成修饰键事件),
    /// 布局敲不出的字符(汉字/emoji)回退 Unicode 注入。返回预计总时长。
    @discardableResult
    func start(text: String, pressEnter: Bool, cfg: Config) -> TimeInterval {
        cancel()
        lastCfg = cfg
        let myRun = nextRunId()

        if cfg.autoIME {
            savedSource = IME.saveCurrent()
            IME.selectEnglish()
        }

        let source: CGEventSource? = CGEventSource(stateID: .combinedSessionState)
        let keymap = Keymap.build()
        let returnKey = CGKeyCode(kVK_Return)
        let tabKey = CGKeyCode(kVK_Tab)

        let chars = Array(text)
        let total = chars.count + (pressEnter ? 1 : 0)

        // 决策追踪: 记录每个字符实际走的注入路径, 便于排查"字符被翻译错"时确认本地到底发出了什么。
        // 只在 debugLog 打开时收集 —— 每条都含被敲入的字符本身, 也就是剪贴板内容的明文。
        var trace: [String] = []
        func traceToken(_ ch: Character, _ path: String) {
            guard cfg.debugLog, trace.count < 100 else { return }
            let display: String
            switch ch {
            case " ": display = "␣"
            case "\n": display = "\\n"
            case "\t": display = "\\t"
            default: display = String(ch)
            }
            trace.append("\(display):\(path)")
        }

        func modifierKeys(of flags: CGEventFlags) -> [CGKeyCode] {
            var keys: [CGKeyCode] = []
            if flags.contains(.maskShift) { keys.append(CGKeyCode(kVK_Shift)) }
            if flags.contains(.maskAlternate) { keys.append(CGKeyCode(kVK_Option)) }
            return keys
        }

        // MARK: 编排时间表
        var steps: [Step] = []
        var t = cfg.lead          // 下一个字符事件的候选起点
        var endTime = cfg.lead    // 已完成事件的最后时刻
        // 当前已按住的修饰键: 连续需要相同修饰键的字符只按一次(真人打 ### 时 shift 全程按住,
        // 远程端也只会看到一次 shift 按下/抬起)。
        // 实测: 修饰键抬起后仅隔 50ms 又按下时, 远程客户端会偶发把这对 flagsChanged
        // 合并/漏掉一个, 该字符退化成裸 3; 隔 100ms 则稳定 —— 所以切换修饰键时留足间隔。
        var curKeys: [CGKeyCode] = []
        var curFlags: CGEventFlags = []

        /// 按需切换修饰键(保持/按下/抬起), 返回"字符事件最早可用的时刻"。
        func applyModifiers(_ needKeys: [CGKeyCode], at earliest: TimeInterval) -> TimeInterval {
            guard needKeys != curKeys else { return earliest }   // 已按住的继续用, 无间隔
            let releaseAt = max(earliest, endTime + cfg.modifierDelay)
            let hadKeys = !curKeys.isEmpty
            if hadKeys {
                for key in curKeys.reversed() {
                    curFlags.subtract(Self.modifierBits(key))
                    steps.append(Step(offset: releaseAt, action: .modifier(keyCode: key, down: false, flags: curFlags),
                                      label: "\(Self.modTag(key))↑", progress: nil))
                }
                endTime = max(endTime, releaseAt)
                curKeys = []
            }
            var charAt = releaseAt
            if hadKeys, !needKeys.isEmpty {
                // 修饰键抬起→再次按下之间必须留足间隔(实测 50ms 偶发丢失, 100ms 稳定)
                charAt = releaseAt + max(cfg.interval, 2 * cfg.modifierDelay)
            }
            if !needKeys.isEmpty {
                for key in needKeys {
                    curKeys.append(key)
                    curFlags.formUnion(Self.modifierBits(key))
                    steps.append(Step(offset: charAt, action: .modifier(keyCode: key, down: true, flags: curFlags),
                                      label: "\(Self.modTag(key))↓", progress: nil))
                }
                endTime = max(endTime, charAt)
                charAt += cfg.modifierDelay   // 修饰键按下后再等一会才发字符
            } else if hadKeys {
                charAt += cfg.modifierDelay   // 刚抬起修饰键, 也留一点间隔
            }
            return charAt
        }

        for (index, ch) in chars.enumerated() {
            let isSpecial = ch == "\n" || ch == "\t"
            let mapped = keymap[ch]
            let progressIndex = index + 1
            var needKeys: [CGKeyCode] = []
            if !isSpecial, let m = mapped { needKeys = modifierKeys(of: m.flags) }

            let charDown = applyModifiers(needKeys, at: max(t, endTime + 0.01))
            var charEnd = charDown

            if !isSpecial, let mapped {
                // 字符事件带修饰位(含设备位)与该字符的 unicode 串。
                let charUp = charDown + cfg.hold
                let charFlags = mapped.flags.union(curFlags)
                steps.append(Step(offset: charDown, action: .key(keyCode: mapped.keyCode, flags: charFlags, down: true, unicode: ch),
                                  label: "\(ch)↓", progress: progressIndex))
                steps.append(Step(offset: charUp, action: .key(keyCode: mapped.keyCode, flags: charFlags, down: false, unicode: ch),
                                  label: "\(ch)↑", progress: nil))
                charEnd = charUp
                let modNames = (mapped.flags.contains(.maskShift) ? "S" : "") + (mapped.flags.contains(.maskAlternate) ? "A" : "")
                traceToken(ch, "k\(mapped.keyCode)" + (modNames.isEmpty ? "" : "+\(modNames)"))
            } else if isSpecial {
                // \n \t 用真实键码对(down → hold → up), flags 恒空。
                let keyCode: CGKeyCode = ch == "\n" ? returnKey : tabKey
                let label = ch == "\n" ? "Return" : "Tab"
                steps.append(Step(offset: charDown, action: .key(keyCode: keyCode, flags: [], down: true, unicode: nil),
                                  label: "\(label)↓", progress: progressIndex))
                steps.append(Step(offset: charDown + cfg.hold, action: .key(keyCode: keyCode, flags: [], down: false, unicode: nil),
                                  label: "\(label)↑", progress: nil))
                charEnd = charDown + cfg.hold
                traceToken(ch, "key")
            } else {
                // 布局敲不出的字符(汉字/emoji)回退 Unicode 注入。
                steps.append(Step(offset: charDown, action: .key(keyCode: CGKeyCode(kVK_ANSI_A), flags: [], down: true, unicode: ch),
                                  label: "\(ch)↓U", progress: progressIndex))
                steps.append(Step(offset: charDown + cfg.hold, action: .key(keyCode: CGKeyCode(kVK_ANSI_A), flags: [], down: false, unicode: ch),
                                  label: "\(ch)↑U", progress: nil))
                charEnd = charDown + cfg.hold
                traceToken(ch, "U")
            }

            endTime = max(endTime, charEnd)
            t = charEnd + cfg.interval + Double.random(in: 0...max(cfg.jitter, 0.001))
        }

        if pressEnter {
            let downAt = applyModifiers([], at: max(t, endTime + cfg.modifierDelay))
            steps.append(Step(offset: downAt, action: .key(keyCode: returnKey, flags: [], down: true, unicode: nil),
                              label: "Return↓", progress: total))
            steps.append(Step(offset: downAt + cfg.hold, action: .key(keyCode: returnKey, flags: [], down: false, unicode: nil),
                              label: "Return↑", progress: nil))
            endTime = max(endTime, downAt + cfg.hold)
        }

        // 收尾: 释放仍按住的修饰键, 避免残留按下状态。
        if !curKeys.isEmpty {
            let releaseAt = max(t, endTime + cfg.modifierDelay)
            for key in curKeys.reversed() {
                curFlags.subtract(Self.modifierBits(key))
                steps.append(Step(offset: releaseAt, action: .modifier(keyCode: key, down: false, flags: curFlags),
                                  label: "\(Self.modTag(key))↑", progress: nil))
            }
            endTime = max(endTime, releaseAt)
        }

        // 时长按实际排布的最后事件计算(修饰键延迟会推后尾部), 多留 0.15s 余量。
        let duration = endTime + 0.15
        activeUntil = Date().addingTimeInterval(duration + 0.05)

        let header = "engine=v3 keymap=\(keymap.count) layout=\(Keymap.activeLayoutName()) chars=\(total) interval=\(cfg.interval) hold=\(cfg.hold) jitter=\(cfg.jitter) modifierDelay=\(cfg.modifierDelay) debug=\(cfg.debugLog ? 1 : 0)"

        /// 日志分两段: 配置头+统计永远写(不含被敲入的字符), 逐字符追踪只在 debugLog 打开时写。
        /// 自愈补发次数是"# 退化成 3"的关键信号, 所以它留在永远写的统计里——
        /// 这样平时日志里没有任何剪贴板内容, 但仍然能回答"本地有没有丢修饰位"。
        func writeLog(_ result: RunResult?) {
            var body = header + "\n"
            if let result {
                body += String(
                    format: "结果: %@ 已发事件=%d/%d 自愈补发=%d 用时=%.2fs\n",
                    result.aborted ? "中断" : "完成", result.eventsSent, result.eventsTotal,
                    result.selfHeals, result.elapsed
                )
                if cfg.debugLog {
                    body += trace.joined(separator: " ") + "\n-- 事件时刻(秒) --\n"
                        + result.timeline.joined(separator: "\n")
                } else {
                    body += "(逐字符追踪未开启; 要确认每个字符走了键码还是 Unicode 注入, 在菜单栏「高级参数」里打开「诊断日志」后复现)\n"
                }
            } else {
                body += "结果: 运行中…\n"
            }
            TypeLog.write(body)
        }
        writeLog(nil)

        // 发送线程: 睡到每个事件的绝对时刻再发, 保证间隔精确。线程生命周期只有本次敲入。
        let restoreSource = savedSource
        let startedAt = Date()
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runSchedule(steps, myRun: myRun, source: source, total: total,
                             modifierDelay: cfg.modifierDelay, debugLog: cfg.debugLog,
                             restoreSource: restoreSource, restore: cfg.restoreIME,
                             started: startedAt) { result in writeLog(result) }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "TypeClip.TyperEngine"
        thread.start()

        return duration
    }
}
