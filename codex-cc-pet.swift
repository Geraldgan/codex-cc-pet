// codex-cc-pet — codex-plugin-cc 的桌面伴侣(原生 AppKit,无第三方依赖)。
//
// 职责:在屏幕角落显示一只随 codex-plugin-cc 后台 job 状态变化的宠物,任务跑完弹系统通知。
//   - 摸鱼(无 job 在跑):缓慢呼吸式上下浮动
//   - 干活(≥1 个 job running):加速浮动 + 气泡显示 Codex 实时话术
//   - 搞定(有 job 刚转 completed):庆祝 🎉(约 5s)+ ✅ 系统通知
//   - 崩了(有 job 刚转 failed):左右抖动 😵(约 6s)+ ⚠️ 系统通知
//
// 数据来源(只读)codex-plugin-cc 写的 job 状态:
//   ~/.claude/plugins/data/codex-inline/state/<项目>/state.json
//
// 运行环境:macOS,作为 accessory app(无 Dock 图标)。窗口可拖动,双击退出。
// 重建:./build.sh(产出通用二进制放进 codex-cc-pet.app)

import Cocoa

// MARK: - 宠物状态

/// 宠物当前要表现的情绪;由 job 聚合状态推导
enum PetMood {
    case idle          // 摸鱼
    case working(Int)  // 干活,带在跑数量
    case done          // 刚搞定(瞬时)
    case failed        // 刚崩了(瞬时)
}

// MARK: - job 状态轮询

/// 只读扫描所有项目的 state.json,聚合出"在跑数量"和"本轮新出现的终态 job"。
/// 不写、不改任何插件状态;通过对比上轮已知终态 id 识别"刚完成/刚失败"。
final class JobWatcher {
    private let stateRoot: URL
    private let terminal: Set<String> = ["completed", "failed", "cancelled", "canceled", "error"]
    /// 已记录为终态的 job id —— 首轮全部记为基线,不触发庆祝/失败动画
    private var seenTerminal = Set<String>()
    private var seededBaseline = false

    init() {
        stateRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/data/codex-inline/state")
    }

    /// 扫一遍,返回 (状态目录是否存在, 在跑数量, 本轮新结束的 job 信息, 最新话术)
    /// present:codex-plugin-cc 的状态目录是否存在(不存在=插件没装/没派过任务);
    /// finished:本轮新进入终态的 job(供通知用);activity:最近活跃 running job 的最新旁白。
    func poll() -> (present: Bool, running: Int, finished: (ok: Bool, project: String, summary: String)?, activity: String?) {
        let present = FileManager.default.fileExists(atPath: stateRoot.path)
        var running = 0
        var finished: (ok: Bool, project: String, summary: String)?
        var activeLog: (updatedAt: String, logFile: String)? // 选 updatedAt 最新的在跑 job

        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: stateRoot, includingPropertiesForKeys: nil)) ?? []

        for dir in dirs {
            let file = dir.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jobs = root["jobs"] as? [[String: Any]] else { continue }

            for job in jobs {
                let status = (job["status"] as? String ?? "").lowercased()
                let id = job["id"] as? String ?? ""
                if status == "running" || status == "queued" {
                    running += 1
                    // 记录最新活跃 job 的 logFile(ISO 时间串可按字典序比大小)
                    if let log = job["logFile"] as? String {
                        let upd = job["updatedAt"] as? String ?? ""
                        if activeLog == nil || upd > activeLog!.updatedAt {
                            activeLog = (upd, log)
                        }
                    }
                    continue
                }
                guard terminal.contains(status), !id.isEmpty else { continue }
                if seenTerminal.contains(id) { continue }
                seenTerminal.insert(id)
                // 基线建立后才把"新出现的终态"当成刚发生的事件(供通知 + 动画)
                if seededBaseline {
                    let project = (job["workspaceRoot"] as? String).map { ($0 as NSString).lastPathComponent } ?? dir.lastPathComponent
                    let summary = (job["summary"] as? String) ?? (job["title"] as? String) ?? id
                    finished = (status == "completed", project, summary)
                }
            }
        }
        seededBaseline = true
        let activity = activeLog.flatMap { Self.latestActivity(logFile: $0.logFile) }
        return (present, running, finished, activity)
    }

    /// 从 logFile 尾部抽最新一句"话术":优先 Assistant message 旁白,否则最近的命令/改动动作。
    /// 只读末尾约 8KB,避免大日志全量读。
    private static func latestActivity(logFile: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: logFile) else { return nil }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 8192
        try? fh.seek(toOffset: end > window ? end - window : 0)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lastNarration: String?
        var lastEvent: String?
        var narration = ""
        var capturing = false

        // 头部行形如 "[2026-...Z] <Header>";Assistant message 的正文在其后续行
        func flush() {
            let t = narration.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lastNarration = t }
            narration = ""
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("["), let r = line.range(of: "] ") {
                if capturing { flush() }
                capturing = false
                let header = String(line[r.upperBound...])
                if header.hasPrefix("Assistant message") {
                    capturing = true
                } else if header.hasPrefix("Running command:") {
                    lastEvent = "运行命令…"
                } else if header.hasPrefix("Applying") {
                    lastEvent = "改动文件中…"
                } else if header.hasPrefix("File changes completed") {
                    lastEvent = "文件已写入"
                }
            } else if capturing {
                narration += line + " "
            }
        }
        if capturing { flush() }

        let pick = lastNarration ?? lastEvent
        guard let s = pick?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.count > 90 ? String(s.prefix(90)) + "…" : s
    }
}

// MARK: - 宠物视图

/// 状态药丸的语义配色(取自设计稿)
enum PillKind {
    case neutral, info, success, danger
    var bg: NSColor {
        switch self {
        case .neutral: return NSColor(srgbRed: 0.227, green: 0.247, blue: 0.290, alpha: 1)
        case .info:    return NSColor(srgbRed: 0.184, green: 0.290, blue: 0.420, alpha: 1)
        case .success: return NSColor(srgbRed: 0.122, green: 0.302, blue: 0.200, alpha: 1)
        case .danger:  return NSColor(srgbRed: 0.353, green: 0.153, blue: 0.188, alpha: 1)
        }
    }
    var fg: NSColor {
        switch self {
        case .neutral: return NSColor(srgbRed: 0.682, green: 0.706, blue: 0.745, alpha: 1)
        case .info:    return NSColor(srgbRed: 0.620, green: 0.773, blue: 1.000, alpha: 1)
        case .success: return NSColor(srgbRed: 0.494, green: 0.886, blue: 0.659, alpha: 1)
        case .danger:  return NSColor(srgbRed: 1.000, green: 0.604, blue: 0.651, alpha: 1)
        }
    }
}

/// 渲染宠物:渐变圆角卡片 + emoji + 话术文字 + 底部状态药丸;动画走 Core Animation。
final class PetView: NSView {
    private let face = NSTextField(labelWithString: "🐤")
    private let label = NSTextField(labelWithString: "摸鱼中")
    private let pill = NSTextField(labelWithString: "")
    private let gradient = CAGradientLayer()
    private var celebrateTimer: Timer?
    /// 是否正在播放瞬时态(搞定/崩了)动画;期间不被常规轮询打断
    private(set) var isTransient = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        // 背景:高斯模糊(透出并模糊桌面)+ 半透明渐变着色 = 磨砂玻璃卡片
        let blur = NSVisualEffectView(frame: bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        addSubview(blur)

        let tint = NSView(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        gradient.frame = bounds
        gradient.colors = [ // alpha 越低越透、桌面越明显
            NSColor(srgbRed: 0.212, green: 0.231, blue: 0.275, alpha: 0.45).cgColor,
            NSColor(srgbRed: 0.149, green: 0.165, blue: 0.200, alpha: 0.45).cgColor,
        ]
        tint.layer?.addSublayer(gradient)
        addSubview(tint)

        face.font = .systemFont(ofSize: 42)
        face.alignment = .center
        face.backgroundColor = .clear
        face.isBezeled = false
        face.isEditable = false
        addSubview(face)

        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.truncatesLastVisibleLine = true // 折到上限后末行省略号
        addSubview(label)

        // 底部状态药丸
        pill.alignment = .center
        pill.backgroundColor = .clear
        pill.isBezeled = false
        pill.isEditable = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.masksToBounds = true
        pill.font = .systemFont(ofSize: 10.5, weight: .semibold)
        addSubview(pill)

        apply(.idle) // 设默认表情/文案/药丸/动画
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 设置话术文案(统一样式:柔白、行距、居中、尾部截断);不重置动画
    func setCaption(_ text: String) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineSpacing = 3
        p.lineBreakMode = .byCharWrapping // 中文无空格,按字符折行才会换行
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: p,
        ])
        layoutContent() // 文字行数变化时整体重新居中
    }

    /// 设置状态药丸:文案 + 语义配色
    func setPill(_ text: String, kind: PillKind) {
        pill.isHidden = false
        pill.stringValue = text
        pill.textColor = kind.fg
        pill.layer?.backgroundColor = kind.bg.cgColor
        positionPill()
    }

    func hidePill() { pill.isHidden = true }

    /// 按文字宽度定药丸尺寸,底部居中
    private func positionPill() {
        let w = ceil(pill.attributedStringValue.size().width) + 22
        pill.frame = NSRect(x: (bounds.width - w) / 2, y: 12, width: w, height: 20)
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        positionPill()
        layoutContent()
    }

    /// [emoji + 话术] 作为整体,垂直居中于药丸上方区域;多行话术也保持整体居中。
    private func layoutContent() {
        let sidePad: CGFloat = 16
        let capWidth = bounds.width - 2 * sidePad
        let measured = label.attributedStringValue.boundingRect(
            with: NSSize(width: capWidth, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let capH = min(ceil(measured), 56) // 话术最多约 3 行

        let emojiH: CGFloat = 44, gap: CGFloat = 4
        let zoneLow: CGFloat = 42         // 药丸区上沿(药丸 y12+高20+间隙10)
        let zoneHigh = bounds.height - 6  // 顶部留白
        let blockH = emojiH + gap + capH
        let blockBottom = (zoneLow + zoneHigh) / 2 - blockH / 2

        label.frame = NSRect(x: sidePad, y: blockBottom, width: capWidth, height: capH)
        face.frame = NSRect(x: 0, y: blockBottom + capH + gap, width: bounds.width, height: emojiH)
    }

    /// 应用情绪:切换表情/文案/动画。done 和 failed 是瞬时态,播完回到 idle。
    func apply(_ mood: PetMood) {
        celebrateTimer?.invalidate()
        switch mood {
        case .idle:
            isTransient = false
            face.stringValue = "🐤"; setCaption("摸鱼中"); setPill("无任务", kind: .neutral)
            startBob(duration: 2.4)
        case .working(let n):
            isTransient = false
            face.stringValue = "🐤"; setCaption(n > 1 ? "干活 ×\(n)" : "干活中"); setPill("运行中", kind: .info)
            startBob(duration: 0.9)
        case .done:
            isTransient = true
            face.stringValue = "🎉"; setCaption("搞定!"); setPill("completed", kind: .success)
            popOnce()
            // 5s 后自动回摸鱼(若期间没有新事件)
            celebrateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.apply(.idle)
            }
        case .failed:
            isTransient = true
            face.stringValue = "😵"; setCaption("崩了"); setPill("failed", kind: .danger)
            shakeOnce()
            celebrateTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                self?.apply(.idle)
            }
        }
    }

    /// 上下浮动(呼吸),duration 越小越急
    private func startBob(duration: CFTimeInterval) {
        face.wantsLayer = true
        face.layer?.removeAnimation(forKey: "bob")
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -4; bob.toValue = 4
        bob.duration = duration
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        face.layer?.add(bob, forKey: "bob")
    }

    /// 庆祝:放大回弹一次
    private func popOnce() {
        face.wantsLayer = true
        face.layer?.removeAnimation(forKey: "bob")
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.7; pop.toValue = 1.0
        pop.duration = 0.45
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        face.layer?.add(pop, forKey: "pop")
    }

    /// 失败:左右抖动一次
    private func shakeOnce() {
        face.wantsLayer = true
        face.layer?.removeAnimation(forKey: "bob")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -6, 6, -3, 3, 0]
        shake.duration = 0.5
        face.layer?.add(shake, forKey: "shake")
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let pet = PetView(frame: NSRect(x: 0, y: 0, width: 230, height: 172))
    private let watcher = JobWatcher()
    private var timer: Timer?
    /// 上一轮应用的情绪键,避免同情绪重复 apply 而重置动画
    private var lastMoodKey = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory) // 不占 Dock

        panel = NSPanel(
            contentRect: pet.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = true // 拖背景即可移动
        panel.contentView = pet

        positionBottomRight()
        panel.orderFrontRegardless()

        // 双击退出
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(quit))
        dbl.numberOfClicksRequired = 2
        pet.addGestureRecognizer(dbl)

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    /// 放到主屏右下角
    private func positionBottomRight() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: vf.maxX - pet.frame.width - 24,
                                     y: vf.minY + 24))
    }

    /// 每轮:聚合 job 状态 → 推导情绪。失败优先于完成,完成优先于在跑。
    private func tick() {
        let r = watcher.poll()
        if let f = r.finished {
            pet.apply(f.ok ? .done : .failed)
            lastMoodKey = f.ok ? "done" : "failed"
            notify(ok: f.ok, project: f.project, summary: f.summary)
        } else if pet.isTransient { return } // 搞定/崩了动画播放中,不被轮询打断
        else if r.running > 0 {
            if lastMoodKey != "working" { pet.apply(.working(r.running)); lastMoodKey = "working" }
            // 每轮刷新话术:优先实时旁白,否则显示在跑数量
            pet.setCaption(r.activity ?? (r.running > 1 ? "干活 ×\(r.running)" : "干活中"))
        } else {
            if lastMoodKey != "idle" { pet.apply(.idle); lastMoodKey = "idle" }
            // 区分:有插件数据=摸鱼+药丸;没检测到状态目录=提示用户并隐藏药丸(而非以为 app 坏了)
            if r.present {
                pet.setCaption("摸鱼中"); pet.setPill("无任务", kind: .neutral)
            } else {
                pet.setCaption("未检测到 codex-plugin-cc 任务"); pet.hidePill()
            }
        }
    }

    /// job 结束时弹 macOS 通知。走 osascript,免去签名/授权流程,本地工具最省事。
    private func notify(ok: Bool, project: String, summary: String) {
        func esc(_ s: String) -> String {
            String(s.prefix(220))
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let title = "Codex \(ok ? "✅ 搞定" : "⚠️ 失败")"
        let script = "display notification \"\(esc(summary))\" with title \"\(esc(title))\" subtitle \"\(esc(project))\" sound name \"Glass\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
