//
//  main.swift
//  NetSpeed - 常驻状态栏的实时网速显示工具
//
//  用法：正常运行只显示在状态栏；`NetSpeed --once` 为终端调试模式，
//  采样 1 秒后打印一次速率用于自检。
//

import Cocoa
import ServiceManagement

// MARK: - 网卡流量采样

/// 读取所有物理网卡（en*，即 Wi-Fi / 有线 / iPhone 共享）的 32 位累计字节数。
/// 排除 lo0、utun*（VPN）、awdl、bridge 等虚拟接口。
/// 注意：macOS 的 if_data 计数器是 32 位的，会回绕，调用方用 wrapping 减法计算增量。
func getInterfaceBytes() -> [String: (rx: UInt32, tx: UInt32)] {
    var addrList: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrList) == 0, let first = addrList else {
        return [:]
    }
    defer { freeifaddrs(addrList) }

    var result: [String: (rx: UInt32, tx: UInt32)] = [:]
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        if let sockaddr = current.pointee.ifa_addr,
           Int32(sockaddr.pointee.sa_family) == AF_LINK,
           let data = current.pointee.ifa_data {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("en") {
                let ifdata = data.assumingMemoryBound(to: if_data.self)
                result[name] = (rx: ifdata.pointee.ifi_ibytes,
                                tx: ifdata.pointee.ifi_obytes)
            }
        }
        cursor = current.pointee.ifa_next
    }
    return result
}

// MARK: - 速率计算

final class SpeedMonitor {
    private var last: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastTime: Date?

    /// 返回 (下载 B/s, 上传 B/s)。首次调用建立基线，返回 0。
    func sample() -> (down: Double, up: Double) {
        let now = Date()
        let current = getInterfaceBytes()
        defer { last = current; lastTime = now }
        guard let prevTime = lastTime else { return (0, 0) }

        let dt = max(now.timeIntervalSince(prevTime), 0.001)
        var down: UInt64 = 0
        var up: UInt64 = 0
        for (name, counters) in current {
            // 新出现的网卡第一次采样不计数；消失的网卡自动被忽略
            guard let prev = last[name] else { continue }
            // 32 位计数器回绕也能算出正确差值（前提：每秒 < 4GB，物理网卡恒成立）
            down &+= UInt64(counters.rx &- prev.rx)
            up &+= UInt64(counters.tx &- prev.tx)
        }
        return (Double(down) / dt, Double(up) / dt)
    }
}

// MARK: - 格式化（固定宽度）

/// 拆成「数值 + 单位」两段：数值恒为 4 位有效格式（≤999，1 位小数），
/// 不足左补空格（忽略前导 0）；到 999 自动升档单位保证宽度恒定。
/// 返回的数值部分恒为 5 个字符宽。
func splitRate(_ bps: Double) -> (num: String, unit: String) {
    let v = max(bps, 0)
    if v < 999.5 {
        // 字节级无小数意义，整数右对齐
        return (String(format: "%5.0f", v), "B")
    }
    let k = v / 1024.0
    if k < 999.5 { return (String(format: "%5.1f", k), "K") }
    let m = k / 1024.0
    if m < 999.5 { return (String(format: "%5.1f", m), "M") }
    return (String(format: "%5.1f", m / 1024.0), "G")
}

/// 简洁速率文本，如 "12.3K/s"（去掉前导空格，用于菜单行）
func shortRate(_ bps: Double) -> String {
    let s = splitRate(bps)
    return "\(s.num.trimmingCharacters(in: .whitespaces))\(s.unit)/s"
}

// MARK: - 每进程流量采样（fork 系统 nettop 解析 CSV，无需 root）

/// 一个 App（同名进程合并后）的实时速率快照
struct ProcTraffic {
    let name: String
    let downRate: Double    // B/s
    let upRate: Double      // B/s
}

final class ProcessNetSampler {
    /// 代理进程的流量与其他 App 重复统计，排除之。
    /// 用前缀匹配：nettop 把进程名截断到 15 字符（如 "mihomo-standalone" → "mihomo-standalo"）
    private static let excludedNamePrefixes = ["mihomo"]

    private var lastByPid: [pid_t: (name: String, rx: UInt64, tx: UInt64)] = [:]
    private var lastTime: Date?
    private var running = false

    /// 后台异步采样，主线程回调按当前速率排序的 Top N。
    /// 首次调用仅建立基线，返回空数组。
    func sampleAsync(limit: Int = 5, onResult: @escaping ([ProcTraffic]) -> Void) {
        guard !running else { return }   // 上次还没跑完就跳过（running 只在主线程读写）
        running = true
        DispatchQueue.global(qos: .utility).async {
            let result = self.sampleSync(limit: limit)
            DispatchQueue.main.async {
                self.running = false
                onResult(result)
            }
        }
    }

    /// 同步采样：fork `nettop` 取一帧每进程累计字节数，与上一帧对比算出速率。
    func sampleSync(limit: Int) -> [ProcTraffic] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let now = Date()
        defer { lastTime = now }
        var current: [pid_t: (name: String, rx: UInt64, tx: UInt64)] = [:]
        current.reserveCapacity(64)
        for rawLine in text.split(separator: "\n") {
            // 行形如 "name.pid,bytes_in,bytes_out,"（末尾带逗号）
            let fields = rawLine.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let rx = UInt64(fields[fields.count - 3]),
                  let tx = UInt64(fields[fields.count - 2]) else { continue }
            let ident = fields[0]
            guard let dot = ident.lastIndex(of: "."),
                  let pid = Int32(ident[ident.index(after: dot)...]) else { continue }
            current[pid] = (String(ident[..<dot]), rx, tx)
        }

        guard let prevTime = lastTime else {
            lastByPid = current
            return []
        }
        let dt = max(now.timeIntervalSince(prevTime), 0.1)

        // 同名进程（如多开的 Helper）合并为一行
        var byName: [String: (down: Double, up: Double)] = [:]
        for (pid, cur) in current {
            let lower = cur.name.lowercased()
            if Self.excludedNamePrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            var down = 0.0, up = 0.0
            if let prev = lastByPid[pid] {
                // PID 复用导致计数变小时按 0 处理
                if cur.rx >= prev.rx { down = Double(cur.rx - prev.rx) / dt }
                if cur.tx >= prev.tx { up = Double(cur.tx - prev.tx) / dt }
            }
            let e = byName[cur.name] ?? (0, 0)
            byName[cur.name] = (e.down + down, e.up + up)
        }
        lastByPid = current

        return byName
            .filter { $0.value.down + $0.value.up >= 1024 }  // 忽略 1K/s 以下的静默进程
            .sorted { $0.value.down + $0.value.up > $1.value.down + $1.value.up }
            .prefix(limit)
            .map { ProcTraffic(name: $0.key, downRate: $0.value.down, upRate: $0.value.up) }
    }
}

// MARK: - 状态栏图标渲染（两行：上=上传，下=下载，只占一个状态栏位）

private let chipFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
private let chipSize = NSSize(width: 36, height: 20)

/// 把速率渲染成固定尺寸的两行小图（template 模板图，深浅菜单栏自动适配）
func renderChipImage(down: Double, up: Double) -> NSImage {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: chipFont,
        .foregroundColor: NSColor.black,   // template 模式下系统会重新着色
    ]
    let u = splitRate(up), d = splitRate(down)
    let lineUp = NSAttributedString(string: "↑\(u.num)\(u.unit)", attributes: attrs)
    let lineDown = NSAttributedString(string: "↓\(d.num)\(d.unit)", attributes: attrs)
    let h = lineUp.size().height

    let image = NSImage(size: chipSize, flipped: false) { _ in
        lineUp.draw(at: NSPoint(x: 1, y: chipSize.height - h))   // 上一行：上传
        lineDown.draw(at: NSPoint(x: 1, y: 0))                   // 下一行：下载
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - 开机自启动

enum LoginItem {
    static let defaultsKey = "launchAtLoginConfigured"

    /// 首次启动默认开启自启动
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsKey) else { return }
        defaults.set(true, forKey: defaultsKey)
        try? SMAppService.mainApp.register()
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = SpeedMonitor()
    private let procSampler = ProcessNetSampler()
    private weak var detailItem: NSMenuItem?
    private weak var loginItem: NSMenuItem?
    private var topItems: [NSMenuItem] = []
    private var tickCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnFirstLaunch()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = ""
        statusItem.button?.image = renderChipImage(down: 0, up: 0)

        buildMenu()
        _ = monitor.sample()  // 建立基线，避免首帧显示历史均值造成的虚高
        procSampler.sampleAsync { _ in }  // 提前建立进程流量基线，首个 tick 即有排行数据

        // 加入 .common 而非默认的 .default 模式：菜单打开期间 run loop 处于
        // eventTracking 模式，默认模式的 Timer 会被挂起，导致下拉栏内容停止刷新
        let timer = Timer(timeInterval: 1.0, target: self,
                          selector: #selector(tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        // 允许系统合并唤醒 0.2s，降低耗电，显示的误差肉眼不可见
        timer.tolerance = 0.2
    }

    private var lastShownText = ""

    /// 拼出固定宽度的文字，仅用于变化检测（变化时才重绘图标）
    private func composeText(_ down: Double, _ up: Double) -> String {
        let d = splitRate(down)
        let u = splitRate(up)
        return "↓\(d.num)\(d.unit) ↑\(u.num)\(u.unit)"
    }

    @objc private func tick() {
        let (down, up) = monitor.sample()
        let text = composeText(down, up)
        // 内容没变就不重绘，避免每秒触发菜单栏重绘（这是主要 CPU 开销）
        if text != lastShownText {
            lastShownText = text
            statusItem.button?.image = renderChipImage(down: down, up: up)
        }
        // 与状态栏一致的自动换挡单位（固定宽度避免菜单宽度抖动）；
        // 原来用 MB/s 两位小数，小流量下常年显示 0.00/0.01，看起来像没刷新
        let d = splitRate(down), u = splitRate(up)
        detailItem?.title = "下载 \(d.num)\(d.unit)/s    上传 \(u.num)\(u.unit)/s"
        loginItem?.state = LoginItem.isEnabled ? .on : .off

        // 每 2 秒在后台采样一次进程流量（nettop 单次约 50ms，开销可忽略）
        tickCount += 1
        if tickCount % 2 == 0 {
            procSampler.sampleAsync { [weak self] tops in
                self?.updateTopMenu(tops)
            }
        }
    }

    private func updateTopMenu(_ tops: [ProcTraffic]) {
        for (i, item) in topItems.enumerated() {
            guard i < tops.count else {
                item.isHidden = true
                continue
            }
            let t = tops[i]
            item.title = String(format: "%d. %@  ↓%@  ↑%@",
                                i + 1, t.name,
                                shortRate(t.downRate), shortRate(t.upRate))
            item.isHidden = false
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        detailItem = detail

        menu.addItem(.separator())

        // Top 进程网速排行：先占位隐藏，有数据后逐行显示（相邻分隔符系统会自动合并）
        for _ in 0..<5 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
            topItems.append(item)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "开机自启动",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        loginItem = login

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "退出 NetSpeed",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    /// 打开菜单时立即刷新一次，否则第一眼看到的是上几秒前的旧值
    /// （tick 始终在主线程被触发，此处直接调用安全）
    func menuWillOpen(_ menu: NSMenu) {
        tick()
        procSampler.sampleAsync { [weak self] tops in
            self?.updateTopMenu(tops)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置开机自启动失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        loginItem?.state = LoginItem.isEnabled ? .on : .off
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--preview") {
    // 预览模式：渲染几组典型速率的小图存到 /tmp 供人眼核对
    let samples: [(String, Double, Double)] = [
        ("idle", 0, 0),
        ("browse", 36_864, 2_048),
        ("download", 11_534_336, 1_004_032),
        ("fast", 1_020_000_128, 12_582_912),
    ]
    for (name, down, up) in samples {
        let img = renderChipImage(down: down, up: up)
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let path = "/tmp/netspeed-\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("已保存 \(path)  尺寸 \(img.size.width)×\(img.size.height)")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--apps") {
    // 调试模式：采样两次（间隔 2 秒），打印 Top 5 进程的网速与累计用量
    let sampler = ProcessNetSampler()
    _ = sampler.sampleSync(limit: 5)
    Thread.sleep(forTimeInterval: 2.0)
    let tops = sampler.sampleSync(limit: 5)
    if tops.isEmpty {
        print("暂无活跃联网进程（< 1K/s 被过滤）")
    }
    for (i, t) in tops.enumerated() {
        print("\(i + 1). \(t.name)  ↓\(shortRate(t.downRate))  ↑\(shortRate(t.upRate))")
    }
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    // 调试模式：采样 1 秒打印结果后退出，方便在终端验证
    let monitor = SpeedMonitor()
    _ = monitor.sample()
    Thread.sleep(forTimeInterval: 1.0)
    let (down, up) = monitor.sample()
    let d = splitRate(down), u = splitRate(up)
    print("↓\(d.num)\(d.unit)/s  ↑\(u.num)\(u.unit)/s  自启动状态: \(SMAppService.mainApp.status.rawValue)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 只驻留状态栏，不出现 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
