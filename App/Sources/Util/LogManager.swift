import Foundation
import os.log
import os.lock

// MARK: - 全局 daemon 日志句柄（用 C FILE* 同步写入，可靠）

// 🔴 Swift 6 迁移：以下全局可变状态由 gDaemonLogLock 串行化（os_unfair_lock），
// 编译器无法验证锁协议 → nonisolated(unsafe) 显式豁免并发检查（运行时行为不变）。
nonisolated(unsafe) private var gDaemonLogFile: UnsafeMutablePointer<FILE>? = nil
nonisolated(unsafe) private var gDaemonLogPath: String? = nil
/// 🔴 v1.1.162 修复：daemon 日志 FILE* 会被多个线程访问 ——
/// LogManager.append 由任意线程调用（Vendor 的 diagnostic 通知在 RPVBridge
/// workQueue 后台线程同步执行 observer），而 DaemonLogStop/DaemonLogStart/
/// 轮转逻辑跑在主线程。旧版无锁：后台线程 fputs 期间主线程 fclose →
/// use-after-fclose 崩溃（且崩在签名热路径上）。用 os_unfair_lock 串行化
/// 所有句柄操作（文件 IO 持锁没问题，阻塞时其他线程排队等待）。
nonisolated(unsafe) private var gDaemonLogLock = os_unfair_lock()

/// 开启 daemon 日志转发（后续所有 LogManager 日志同步写入该文件）
nonisolated func DaemonLogStart(_ path: String) {
    os_unfair_lock_lock(&gDaemonLogLock)
    defer { os_unfair_lock_unlock(&gDaemonLogLock) }
    gDaemonLogPath = path
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    gDaemonLogFile = fopen(path, "a")
    if gDaemonLogFile != nil { chmod(path, 0666) }
}

/// 关闭 daemon 日志转发
nonisolated func DaemonLogStop() {
    os_unfair_lock_lock(&gDaemonLogLock)
    defer { os_unfair_lock_unlock(&gDaemonLogLock) }
    if let f = gDaemonLogFile { fclose(f) }
    gDaemonLogFile = nil
    gDaemonLogPath = nil
}

/// 清空 daemon 日志（fopen("w")截断，不依赖权限）
nonisolated func DaemonLogClear(_ path: String) {
    os_unfair_lock_lock(&gDaemonLogLock)
    defer { os_unfair_lock_unlock(&gDaemonLogLock) }
    if let f = gDaemonLogFile { fclose(f); gDaemonLogFile = nil }
    if let f = fopen(path, "w") { fclose(f); chmod(path, 0666) }
}

/// 获取 daemon 日志文件大小
nonisolated func DaemonLogSize(_ path: String) -> String {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int64 else { return "—" }
    if size < 1024 { return "\(size) B" }
    if size < 1024*1024 { return String(format: "%.1f KB", Double(size)/1024.0) }
    return String(format: "%.1f MB", Double(size)/(1024.0*1024.0))
}

/// daemon 日志路径。
/// 🔴 v1.1.186：统一到豁免目录 /var/mobile/Library/Resign/reprorefresh_at.log——
/// RootHide 下 /var/jb/var/log 与 <jbroot>/var/log 都是 overlay 假目录（AppGroup 私有，
/// 用户 SSH/爱思看不到），而 /var/mobile/Library/Resign 是豁免 overlay 的共享 IPC 目录，
/// App(mobile) 与 signingd 都能写、用户也能在真实 rootfs 看到。signingd 的 s_open_log
/// v1.1.186 首选同一路径，App 与 daemon 日志合流到一个文件（各自带时间戳前缀）。
nonisolated func DaemonLogDefaultPath() -> String {
    return "/var/mobile/Library/Resign/reprorefresh_at.log"
}

/// daemon 日志文件大小上限（2 MB），超出后截断重建（见 daemonLogWrite 轮转逻辑）
nonisolated private let maxDaemonLogSize: Int64 = 2 * 1024 * 1024
/// 轮转检查计数器（daemonLogWrite 每 ~100 行 stat 一次文件大小；Swift 函数内不允许 static 局部变量，用文件级全局）
/// 🔴 Swift 6 迁移：仅由 gDaemonLogLock 保护下访问 → nonisolated(unsafe) 豁免。
nonisolated(unsafe) private var daemonLogWriteCount: Int = 0

/// 同步写入一行到 daemon 日志（在 LogManager.append 中调用）
/// 内置 2 MB 轮转：超出后截断保留后半段，避免长期运行撑满磁盘
private nonisolated func daemonLogWrite(ts: String, source: String, message: String) {
    os_unfair_lock_lock(&gDaemonLogLock)
    defer { os_unfair_lock_unlock(&gDaemonLogLock) }
    guard let f = gDaemonLogFile else { return }

    // 每写入 ~100 行检查一次文件大小（避免每次都 stat 的开销）
    daemonLogWriteCount += 1
    if daemonLogWriteCount % 100 == 1, let path = gDaemonLogPath {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64,
           size > maxDaemonLogSize {
            // 截断：关闭当前文件 → 重开（fopen "w" 清空）→ 写入轮转标记
            // （锁内执行：其他线程的 fputs 要么等解锁要么已持有旧句柄——不会发生
            //  持旧 FILE* 时被 fclose 的 use-after-free）
            fclose(f)
            gDaemonLogFile = nil
            if let nf = fopen(path, "w") {
                gDaemonLogFile = nf
                chmod(path, 0666)
                fputs("=== 日志文件已自动轮转（超出 2 MB 上限，旧日志已清除）===\n", nf)
                fflush(nf)
            }
        }
    }

    let line = "[\(ts)] [\(source)] \(message)\n"
    fputs(line, f)
    fflush(f)
}

// MARK: - 统一日志管理器

class LogManager: ObservableObject {
    // 🔴 Swift 6 迁移：shared 与 info/warning/error/debug 改为 nonisolated——
    // 日志是全 App 各线程都会调用的基础设施（ObjC 回调、后台线程、Dispatch 块），
    // 内部通过「文件写入自带 os_unfair_lock + logs 数组更新统一 Task @MainActor 跳线」
    // 保证线程安全，调用方无需关心隔离域。
    nonisolated(unsafe) static let shared = LogManager()

    @Published private(set) var logs: [LogEntry] = []
    private let maxLogEntries = 5000

    nonisolated private init() {}

    // MARK: 初始化
    func initialize() {
        loadFromDisk()
        importSigningdLogTail()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDiagnostic(_:)),
            name: Notification.Name("cn.analy.resign.diagnostic"), object: nil)
    }

    /// 🔴 v1.1.186：把 signingd 的检测日志尾部导入日志页，让用户能看到
    /// 「检测间隔 / 距上次检测 / 下次检测」等 daemon 行为记录。
    ///
    /// 背景：signingd 日志 v1.1.186 起写到豁免目录 /var/mobile/Library/Resign/
    /// reprorefresh_at.log（RootHide 下唯一 App 与 SSH 都能看到的真实位置），
    /// 本方法在 App 启动时读它的最后 N 行并入内存日志（source=signingd）。
    /// 只在 initialize() 调一次，不会重复；直接写 logs 数组，不再回写文件。
    ///
    /// 🔴 v1.1.187：导入前过滤「启动横幅 / 诊断噪音」行（用户反馈这些不该出现在
    /// App 日志板块）——启动横幅（===/管理命令/看门狗/配置/BundleID/架构）与
    /// entitlement 自检 3 行（无法自检/namespace/若怀疑裸签）只对 SSH 排查有价值，
    /// 对用户看检测记录毫无意义，直接丢弃。
    private func importSigningdLogTail() {
        let path = "/var/mobile/Library/Resign/reprorefresh_at.log"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              !content.isEmpty else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        // 过滤噪音行（前缀黑名单；匹配后整行丢弃）。
        // 🔴 v1.1.189：前缀统一不带前导空格，匹配前先 trim —— 旧版黑名单写「sudo 」，
        // 实际日志行是「  sudo …」（管理命令列表带两个空格缩进），hasPrefix 匹配失败漏网。
        let noisePrefixes = [
            "=====",            // 启动横幅分隔线（长度不固定，短前缀兜底）
            "=== 启动",
            "管理命令:",
            "sudo ",
            "已注册信号处理",
            "内存看门狗已启动",
            "超时看门狗已启动",
            "ℹ️ 无法自检 entitlement",
            "namespace: ",
            "（若怀疑裸签",
            "配置: 自动",
            "BundleID: ",
            "架构: ",
            "launchd 每小时重新拉起",
        ]
        let meaningful = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !noisePrefixes.contains { t.hasPrefix($0) }
        }
        guard !meaningful.isEmpty else { return }
        let tail = Array(meaningful.suffix(25))

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let entries = tail.map { line in
                LogEntry(id: UUID(), timestamp: Date(), level: .info,
                         message: line, source: "signingd")
            }
            self.logs.append(contentsOf: entries)
            while self.logs.count > self.maxLogEntries { self.logs.removeFirst() }
        }
    }

    // 🔴 Swift 6 迁移：selector 型通知回调会发布者线程上被调用（非主线程），
    // 显式 nonisolated；内部只调 nonisolated 的 append，UI 更新由 append 内部跳主线程。
    @objc nonisolated private func handleDiagnostic(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else { return }
        let source = (userInfo["source"] as? String) ?? "Vendor"
        let levelInt = (userInfo["level"] as? Int) ?? 0
        switch levelInt {
        case 1: warning(message, source: source)
        case 2: error(message, source: source)
        case 3:
            #if DEBUG
            debug(message, source: source)
            #else
            info(message, source: source)
            #endif
        default: info(message, source: source)
        }
    }

    // MARK: 写入日志
    nonisolated func info(_ message: String, source: String = "General")    { append(level: .info,    message: message, source: source) }
    nonisolated func warning(_ message: String, source: String = "General")  { append(level: .warning, message: message, source: source) }
    nonisolated func error(_ message: String, source: String = "General")    { append(level: .error,   message: message, source: source) }
    nonisolated func debug(_ message: String, source: String = "General")    {
        #if DEBUG
        append(level: .debug, message: message, source: source)
        #endif
    }

    // 静态 formatter 复用（append 每秒可能被调用多次，避免反复创建 DateFormatter）
    // 🔴 Swift 6 迁移：DateFormatter 非 Sendable，且 append 已改为 nonisolated（多线程调用）→
    // nonisolated(unsafe) 豁免（DateFormatter 串行使用：append 内同步调用，无并发共享）。
    nonisolated(unsafe) private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 🔴 Swift 6 迁移：append 改 nonisolated（任意线程调用：diagnostic 通知在后台线程、
    /// UI 在主线程）。文件写入自带锁；logs 数组更新统一 Task @MainActor 跳主线程。
    nonisolated private func append(level: LogLevel, message: String, source: String) {
        let now = Date()
        let entry = LogEntry(id: UUID(), timestamp: now, level: level, message: message, source: source)

        // daemon 日志：同步写入（最关键——不用 async，不丢数据）
        let ts = LogManager.dateFormat.string(from: now)
        daemonLogWrite(ts: ts, source: source, message: message)

        // 内存日志：跳主线程更新 UI（Task @MainActor 可捕获 MainActor 隔离的 self）
        Task { @MainActor [weak self] in
            self?.logs.append(entry)
            while (self?.logs.count ?? 0) > (self?.maxLogEntries ?? 50) { self?.logs.removeFirst() }
        }
        os_log("[%@][%@] %@", log: OSLog(subsystem: "cn.analy.resign", category: source),
               type: (level == .error ? .error : level == .warning ? .default : .info),
               level.displayName, source, message)
    }

    // MARK: 清空
    func clear() {
        logs.removeAll()
        deleteLogFile()
    }

    private func saveToDisk() {
        guard let url = logFileURL else { return }
        try? (try? JSONEncoder().encode(logs))?.write(to: url, options: .atomic)
    }

    private func loadFromDisk() {
        guard let url = logFileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
        Task { @MainActor [weak self] in self?.logs = decoded }
    }

    private func deleteLogFile() { if let u = logFileURL { try? FileManager.default.removeItem(at: u) } }

    private var logFileURL: URL? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReProvision")
        guard let d = dir else { return nil }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("logs.json")
    }
}
