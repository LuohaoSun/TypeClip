import SwiftUI
import AppKit
import Carbon
import Carbon.HIToolbox
import ServiceManagement

// MARK: - 全局状态与设置

/// 输入法处理策略。原来的 autoIME / restoreIME 两个开关合并成三态:
/// restoreIME 只在 autoIME 打开时才有意义, 拆成两个独立开关会出现"不切英文却要求恢复"的无意义组合。
enum IMEMode: String, CaseIterable, Identifiable {
    case off, englishOnly, englishAndRestore

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "不动"
        case .englishOnly: return "切英文"
        case .englishAndRestore: return "切并恢复"
        }
    }

    var detail: String {
        switch self {
        case .off: return "保持当前输入法敲入"
        case .englishOnly: return "触发时切英文, 结束后保持英文"
        case .englishAndRestore: return "触发时切英文, 结束后切回原输入法"
        }
    }

    var autoIME: Bool { self != .off }
    var restoreIME: Bool { self == .englishAndRestore }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = TyperEngine()
    private let defaults = UserDefaults.standard

    @Published var status: String = "就绪 ⌃⌘V 敲入剪贴板"
    @Published var lastError: String?
    @Published var trusted: Bool = AXIsProcessTrusted()
    @Published var clipboardSummary: String = ""
    @Published var clipboardOK = false

    /// 唯一的速度轴(ms/字符)。字符间隔、按住时长、随机抖动、修饰键延迟都由它派生,
    /// 默认 100ms 时四个派生值与历史默认值逐位一致(100 / 60 / 30 / 100)。
    @Published var paceMs: Double { didSet { defaults.set(paceMs, forKey: "paceMs"); if manual { manual = false } } }
    @Published var imeMode: IMEMode { didSet { defaults.set(imeMode.rawValue, forKey: "imeMode") } }
    @Published var loginEnabled: Bool

    /// 高级覆盖: 直接指定四个原始参数, 仅在 paceMs 与实测不符时用来排障。
    /// 改速度轴会自动退出覆盖, 避免出现"滑块看着是 100 实际发的是 250"这种分裂状态。
    @Published var manual: Bool { didSet { defaults.set(manual, forKey: "manual"); if manual { seedRawFromPace() } } }
    @Published var intervalMs: Double { didSet { defaults.set(intervalMs, forKey: "intervalMs") } }
    @Published var holdMs: Double { didSet { defaults.set(holdMs, forKey: "holdMs") } }
    @Published var jitterMs: Double { didSet { defaults.set(jitterMs, forKey: "jitterMs") } }
    @Published var modifierDelayMs: Double { didSet { defaults.set(modifierDelayMs, forKey: "modifierDelayMs") } }

    /// 诊断日志: 打开后日志里才记录逐字符注入路径与事件时刻表。
    /// 默认关——那两段含被敲入的字符本身(即剪贴板明文), 平时没有记录的必要。
    @Published var debugLog: Bool { didSet { defaults.set(debugLog, forKey: "debugLog") } }

    /// 「诊断日志」折叠项的展开状态。纯 UI, 不落盘。
    /// 放在这里而不是 View 的 @State: 只装 Command Line Tools 时 SwiftUI 的 @State 宏
    /// 编译不过(缺 SwiftUIMacros 插件), @Published 是普通属性包装器, 没这个问题。
    @Published var debugPanelExpanded = false

    /// 速度轴 → 四个引擎参数。hold 必须短于 interval(否则按键会叠住), jitter 只是间隔上的噪声,
    /// modifierDelay 保底 100ms —— 实测 50ms 时堡垒机远程端会来不及登记 shift, # 退化成裸 3。
    static func derived(paceMs: Double) -> (interval: Double, hold: Double, jitter: Double, modifierDelay: Double) {
        (interval: paceMs,
         hold: min(max(0.6 * paceMs, 15), 150),
         jitter: 0.3 * paceMs,
         modifierDelay: max(paceMs, 100))
    }

    init() {
        // 迁移: 老版本只有 intervalMs 一个数, 它就是速度轴。落盘保存, 使迁移只发生一次
        // ——否则高级区改写 intervalMs 后重启, 速度轴会读到那个覆盖值而不是真实速度。
        let pace = defaults.object(forKey: "paceMs") as? Double
            ?? defaults.object(forKey: "intervalMs") as? Double ?? 100
        let mode: IMEMode
        if let raw = defaults.string(forKey: "imeMode"), let saved = IMEMode(rawValue: raw) {
            mode = saved
        } else {
            let auto = defaults.object(forKey: "autoIME") as? Bool ?? true
            let restore = defaults.object(forKey: "restoreIME") as? Bool ?? false
            mode = auto ? (restore ? .englishAndRestore : .englishOnly) : .off
        }

        paceMs = pace
        imeMode = mode
        loginEnabled = SMAppService.mainApp.status == .enabled

        manual = defaults.bool(forKey: "manual")
        debugLog = defaults.bool(forKey: "debugLog")
        let d = Self.derived(paceMs: pace)
        intervalMs = defaults.object(forKey: "intervalMs") as? Double ?? d.interval
        holdMs = defaults.object(forKey: "holdMs") as? Double ?? d.hold
        jitterMs = defaults.object(forKey: "jitterMs") as? Double ?? d.jitter
        modifierDelayMs = defaults.object(forKey: "modifierDelayMs") as? Double ?? d.modifierDelay

        // 属性观察器在 init 里不会触发, 所以这里显式落盘。
        defaults.set(pace, forKey: "paceMs")
        defaults.set(mode.rawValue, forKey: "imeMode")

        engine.onProgress = { typed, total in
            let app = AppState.shared
            app.status = "敲入中 \(typed)/\(total)"
            app.lastError = nil
        }
        engine.onFinish = {
            AppState.shared.status = "完成 ✓"
        }
    }

    /// 打开高级覆盖时, 用当前派生值填满四个原始参数作为起点。
    /// 注意: 必须在 manual 的 didSet 里调用, 且不能反向写 paceMs。
    private func seedRawFromPace() {
        let d = Self.derived(paceMs: paceMs)
        intervalMs = d.interval
        holdMs = d.hold
        jitterMs = d.jitter
        modifierDelayMs = d.modifierDelay
    }

    var engineConfig: TyperEngine.Config {
        let d = Self.derived(paceMs: paceMs)
        return .init(
            interval: (manual ? intervalMs : d.interval) / 1000,
            hold: (manual ? holdMs : d.hold) / 1000,
            jitter: (manual ? jitterMs : d.jitter) / 1000,
            lead: 0.5,
            autoIME: imeMode.autoIME,
            restoreIME: imeMode.restoreIME,
            modifierDelay: (manual ? modifierDelayMs : d.modifierDelay) / 1000,
            debugLog: debugLog
        )
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginEnabled = enabled
        } catch {
            lastError = "开机自启设置失败: \(error.localizedDescription)"
        }
    }

    /// 剪贴板状态摘要与可敲入性检查(边界情况: 图像/文件/空文本/超长)。
    func refreshPasteboard() {
        let pb = NSPasteboard.general
        let kinds = (pb.types ?? []).map(\.rawValue)
        if let raw = pb.string(forType: .string) {
            let cleaned = TyperEngine.clean(raw)
            if cleaned.isEmpty {
                clipboardSummary = "剪贴板是空白文本(仅换行/空白), 无法敲入"
                clipboardOK = false
            } else {
                let preview = cleaned.prefix(60).replacingOccurrences(of: "\n", with: "⏎")
                let suffix = cleaned.count > 60 ? "…(\(cleaned.count) 字符)" : "(\(cleaned.count) 字符)"
                clipboardSummary = "剪贴板: \(preview) \(suffix)"
                clipboardOK = true
            }
        } else if kinds.contains(where: { $0.contains("tiff") || $0.contains("png") || $0.contains("jpeg") || $0.contains("heic") }) {
            clipboardSummary = "剪贴板是图像, 无法敲入"
            clipboardOK = false
        } else if pb.data(forType: .fileURL) != nil || kinds.contains(where: { $0.contains("file") }) {
            clipboardSummary = "剪贴板是文件/其他非文本内容, 无法敲入"
            clipboardOK = false
        } else {
            clipboardSummary = "剪贴板没有可敲入的文本"
            clipboardOK = false
        }
    }
}

// MARK: - 热键入口与边界处理

@MainActor
enum TypeClipController {
    static func handleHotkey(enter: Bool = false) {
        let app = AppState.shared
        if app.engine.isActive {
            app.engine.cancel()
            app.status = "已中断 ⏹"
            return
        }
        guard AXIsProcessTrusted() else {
            app.lastError = "缺少辅助功能权限, 无法模拟键盘"
            openPrivacySettings()
            return
        }
        let pb = NSPasteboard.general
        guard let raw = pb.string(forType: .string) else {
            let kinds = (pb.types ?? []).map(\.rawValue)
            let isImage = kinds.contains { $0.contains("tiff") || $0.contains("png") }
            let message = isImage ? "剪贴板是图像, 无法敲入" : "剪贴板没有文本(可能是文件/图像)"
            NSSound.beep()
            app.status = "未敲入"
            app.lastError = message
            return
        }
        let text = TyperEngine.clean(raw)
        guard !text.isEmpty else {
            NSSound.beep()
            app.status = "未敲入"
            app.lastError = "剪贴板文本为空(或只有换行/空白)"
            return
        }
        let cfg = app.engineConfig
        let duration = app.engine.start(text: text, pressEnter: enter, cfg: cfg)
        app.status = "开始敲入 \(text.count) 字符, 约 \(Int(duration))s"
        app.lastError = nil
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - App 生命周期

final class AppDelegate: NSObject, NSApplicationDelegate {

    #if TYPECLIP_DEV_HOOKS
    /// 处理开发/诊断钩子。返回 true = 已处理, 不要继续走正常 GUI 启动。
    ///
    /// 这些入口只在带 -D TYPECLIP_DEV_HOOKS 的构建里存在(见 build.sh)。
    /// 原因: `--notify-*` 走的是分布式通知, 而它没有来源校验 —— 本机任何进程
    /// (哪怕自己没有被授予辅助功能权限)都能发一条通知让常驻实例替它敲键盘,
    /// 等于借用了 TypeClip 的 TCC 授权。发布给别人的构建必须整块编掉。
    private func handleDevHook(_ args: [String]) -> Bool {
        if args.contains("--selfcheck") {
            print("trusted:\(AXIsProcessTrusted())")
            fflush(stdout)
            exit(0)
        }

        if args.contains("--notify-keydiag") {
            // 终端直接跑二进制时 TCC 按终端进程判权限, 必然 not-trusted;
            // 改由常驻 GUI 实例(已授权)执行诊断。
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.slh.typeclip.keydiag"), object: nil,
                userInfo: nil, deliverImmediately: true
            )
            exit(0)
        }

        if args.contains("--notify-drive") || args.contains("--notify-drive-enter") {
            // 通知常驻 GUI 实例执行敲入(测试用, 走完整热键路径, 不新建引擎进程)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.slh.typeclip.drive"), object: nil,
                userInfo: ["enter": args.contains("--notify-drive-enter") ? "1" : "0"],
                deliverImmediately: true
            )
            exit(0)
        }

        if args.contains("--keydiag") {
            // 诊断: 多种注入方式依次输入 #, 用于判定目标端认哪种事件合成方式
            guard AXIsProcessTrusted() else {
                print("keydiag: not-trusted")
                print("提示: 终端直接运行时 TCC 按终端进程判权限; 请改用 --notify-keydiag 由常驻 GUI 实例执行")
                exit(3)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                KeyDiag.run()
                exit(0)
            }
            return true
        }

        if args.contains("--drive-once") || args.contains("--drive-once-enter") {
            driveOnce(enter: args.contains("--drive-once-enter"))
            return true
        }

        return false
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if TYPECLIP_DEV_HOOKS
        if handleDevHook(ProcessInfo.processInfo.arguments) { return }
        #endif

        // GUI 模式: 已在运行则不再起第二份
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        HotkeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | controlKey), id: 1) {
            TypeClipController.handleHotkey(enter: false)
        }

        #if TYPECLIP_DEV_HOOKS
        // 分布式通知驱动入口(自动化测试用, 等价于按热键)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.slh.typeclip.drive"), object: nil, queue: .main
        ) { note in
            let enter = (note.userInfo?["enter"] as? String) == "1"
            TypeClipController.handleHotkey(enter: enter)
        }

        // 键盘注入诊断(由 --notify-keydiag 触发); 放到后台队列避免阻塞菜单栏 UI
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.slh.typeclip.keydiag"), object: nil, queue: .main
        ) { _ in
            DispatchQueue.global(qos: .userInitiated).async { KeyDiag.run() }
        }
        #endif

        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    #if TYPECLIP_DEV_HOOKS
    /// 自动化测试入口: 直接驱动一次引擎后退出(不抢焦点, 不注册热键)。
    private func driveOnce(enter: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard AXIsProcessTrusted() else {
                print("drive-once: not-trusted")
                exit(3)
            }
            guard let raw = NSPasteboard.general.string(forType: .string) else {
                print("drive-once: clipboard-not-text")
                exit(2)
            }
            let text = TyperEngine.clean(raw)
            guard !text.isEmpty else {
                print("drive-once: clipboard-empty")
                exit(2)
            }
            let duration = AppState.shared.engine.start(text: text, pressEnter: enter, cfg: AppState.shared.engineConfig)
            print("drive-once: started \(text.count) chars, ~\(Int(duration))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1.0) {
                exit(0)
            }
        }
    }
    #endif
}

// MARK: - 菜单栏 UI

@main
struct TypeClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
        } label: {
            Image(systemName: AppState.shared.engine.isActive ? "keyboard.badge.ellipsis" : "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuPanel: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !app.trusted {
                permissionCard
            }

            // 状态 + 剪贴板摘要
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: app.engine.isActive ? "keyboard.badge.ellipsis" : "keyboard")
                        .foregroundStyle(app.engine.isActive ? .orange : .secondary)
                    Text(app.status).font(.callout)
                    Spacer()
                }
                if let error = app.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text(app.clipboardSummary)
                    .font(.caption)
                    .foregroundStyle(app.clipboardOK ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }

            Divider()

            // 轴一: 敲入速度。字符间隔/按住时长/随机抖动/修饰键延迟全部由它派生。
            VStack(alignment: .leading, spacing: 4) {
                sliderRow(title: "敲入速度", value: $app.paceMs, range: 50...500, unit: "ms")
                Text("每字符间隔, 越慢越稳; 按住时长、抖动、修饰键延迟按比例跟随")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // 轴二: 输入法处理(三态)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("输入法").frame(width: 64, alignment: .leading)
                    Picker("", selection: $app.imeMode) {
                        ForEach(IMEMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Text(app.imeMode.detail).font(.caption2).foregroundStyle(.secondary)
            }

            Toggle("开机自启", isOn: Binding(
                get: { app.loginEnabled },
                set: { app.setLogin($0) }
            ))

            // 逃生舱: 展开即接管, 直接指定四个原始参数(排障用, 平时不用碰)。
            DisclosureGroup(isExpanded: $app.manual) {
                VStack(alignment: .leading, spacing: 8) {
                    sliderRow(title: "字符间隔", value: $app.intervalMs, range: 50...500, unit: "ms")
                    sliderRow(title: "按住时长", value: $app.holdMs, range: 20...150, unit: "ms")
                    sliderRow(title: "随机抖动", value: $app.jitterMs, range: 0...80, unit: "ms")
                    sliderRow(title: "修饰键延迟", value: $app.modifierDelayMs, range: 0...200, unit: "ms")
                }
                .padding(.top, 6)
            } label: {
                Text("高级参数(手动覆盖速度轴)")
                    .font(.caption)
                    .foregroundStyle(app.manual ? Color.orange : Color.secondary)
            }

            // 诊断日志单独一个折叠项, 与"覆盖速度轴"解耦: 打开它只影响日志详细程度, 不改敲入行为。
            DisclosureGroup(isExpanded: $app.debugPanelExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("记录逐字符注入路径", isOn: $app.debugLog)
                    Text("日志: ~/Library/Logs/TypeClip.log")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(app.debugLog
                         ? "打开后日志会含被敲入的字符明文(等于剪贴板内容), 排查完请关掉"
                         : "关闭时日志只记配置与统计, 不含剪贴板内容; 排查 # 退化成 3 这类问题时再打开")
                        .font(.caption2)
                        .foregroundStyle(app.debugLog ? Color.orange : Color.secondary)
                }
                .padding(.top, 6)
            } label: {
                Text("诊断日志")
                    .font(.caption)
                    .foregroundStyle(app.debugLog ? Color.orange : Color.secondary)
            }

            Divider()

            HStack {
                Button("立即敲入") { TypeClipController.handleHotkey(enter: false) }
                    .disabled(!app.clipboardOK || !app.trusted)
                Button("中断") {
                    app.engine.cancel()
                    app.status = "已中断 ⏹"
                }
                .disabled(!app.engine.isActive)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)

            Text("热键: ⌃⌘V 敲入 · 敲入中再按 ⌃⌘V = 中断")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            app.trusted = AXIsProcessTrusted()
            app.refreshPasteboard()
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("需要「辅助功能」权限才能模拟键盘", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
            Button("打开系统设置授权") { TypeClipController.openPrivacySettings() }
                .buttonStyle(.link)
            Text("系统设置 → 隐私与安全性 → 辅助功能 → 开启 TypeClip")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range, step: 10)
            Text("\(Int(value.wrappedValue))\(unit)")
                .monospacedDigit().frame(width: 52, alignment: .trailing)
                .font(.callout)
        }
    }
}
