import SwiftUI
import UniformTypeIdentifiers

// MARK: - 原生文件选择器（无 SwiftUI sheet 中间层）

/// 直接从 root VC present UIDocumentPickerViewController，无需 sheet 包裹
private final class IPAFilePicker: NSObject, UIDocumentPickerDelegate {
    private let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

    func present() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }

        // 用 import/copy 模式 (asCopy: true)。
        // 该模式下系统会在把文件交给 App 前自行完成下载：iCloud 云盘文件先在选择器里出现下载箭头，
        // 下载完成后才回传一个本地真实副本的 security-scoped URL，不会像 open 模式那样直接给
        // .icloud 占位符活体 URL 导致「无法读取这个 .ipa」。
        // 同时这种模式下选择器右上角有「打开」按钮、文件带圆形勾选框，点击→勾选→打开的交互明确，
        // 不会出现 open 模式「点了没反应」的问题（用户实测反馈）。
        // 注：v1.1.157 起 repro-importdaemon 已删除，拷贝兜底统一由 repro-helper 执行；
        // RootHide 下 iCloud 导入场景已废弃（overlay 内读不到 iCloud 真实路径）。
        var types: [UTType] = []
        if let ipa = UTType(filenameExtension: "ipa") { types.append(ipa) }
        types.append(.archive)
        types.append(.data)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        top.present(picker, animated: true)

        // 强引用自己，防止 delegate 回调前被释放
        objc_setAssociatedObject(picker, "keeper", self, .OBJC_ASSOCIATION_RETAIN)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            LogManager.shared.info("用户选择了文件: \(url.lastPathComponent)", source: "AppsView")
            onPick(url)
        }
        controller.dismiss(animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
    }
}

// MARK: - 已安装应用列表

struct AppsView: View {
    @StateObject private var viewModel = SigningViewModel()
    @ObservedObject private var account = BridgeClient.shared
    @State private var pendingUninstall: InstalledApp?
    /// v2.2.11：待确认「清空数据」的应用
    @State private var pendingClearData: InstalledApp?
    /// 待重签的「其他应用」（用于弹出警告确认）
    @State private var pendingOtherAppResign: InstalledApp?
    /// 小黑屋说明弹窗
    @State private var showBlacklistHelp = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶栏：刷新(左) + ReSign(居中偏右) + 导入(右)
                HStack(alignment: .center) {
                    // 左侧：刷新（圆角胶囊按钮）
                    Button {
                        viewModel.resignAllApplications()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 40, height: 40)
                            .background {
                                if #available(iOS 26.0, *) {
                                    // iOS 26 液态玻璃胶囊（蓝底兜底 + 玻璃层）
                                    ZStack {
                                        Capsule().fill(Color.blue.opacity(0.1))
                                        LiquidGlassBackground().clipShape(Capsule())
                                    }
                                } else {
                                    Capsule()
                                        .fill(Color.blue.opacity(0.08))
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy || !account.isSignedIn)

                    // 中间：ReSign 标题（X轴右移，对齐底栏设置/日志中间）
                    Spacer(minLength: 0)
                    Image("NavTitle")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                        .padding(.leading, 28) // X轴右移约15格（用户要求再往右三格）
                    Spacer(minLength: 0)

                    // 右侧：导入（圆角胶囊按钮）
                    Button {
                        openFilePicker()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("导入")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.blue)
                        .frame(height: 40)
                        .padding(.horizontal, 12)
                        .background {
                            if #available(iOS 26.0, *) {
                                // iOS 26 液态玻璃胶囊（蓝底兜底 + 玻璃层）
                                ZStack {
                                    Capsule().fill(Color.blue.opacity(0.1))
                                    LiquidGlassBackground().clipShape(Capsule())
                                }
                            } else {
                                Capsule()
                                    .fill(Color.blue.opacity(0.08))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

                if viewModel.installedApps.isEmpty && viewModel.otherApps.isEmpty && viewModel.blacklistedApps.isEmpty {
                    emptyState
                } else {
                    appList
                }
            }
            .background(Color(.systemGroupedBackground)) // 浅灰底，不刺眼
            .navigationBarHidden(true)
            .scrollContentBackground(.hidden) // iOS 16+ API，去掉 NavigationView 白色背景
            .safeAreaInset(edge: .bottom) { statusBar }
            .confirmationDialog("卸载应用",
                                isPresented: Binding(get: { pendingUninstall != nil },
                                                     set: { if !$0 { pendingUninstall = nil } }),
                                titleVisibility: .visible) {
                Button("卸载 \(pendingUninstall?.displayName ?? "")", role: .destructive) {
                    if let app = pendingUninstall { viewModel.uninstall(app: app) }
                    pendingUninstall = nil
                }
                Button("取消", role: .cancel) { pendingUninstall = nil }
            } message: {
                Text("该应用及其数据会从设备上移除。")
            }
            .confirmationDialog("警告",
                                isPresented: Binding(get: { pendingOtherAppResign != nil },
                                                     set: { if !$0 { pendingOtherAppResign = nil } }),
                                titleVisibility: .visible) {
                Button("继续") {
                    if let app = pendingOtherAppResign { viewModel.resignOtherApp(app) }
                    pendingOtherAppResign = nil
                }
                Button("取消", role: .cancel) { pendingOtherAppResign = nil }
            } message: {
                if let app = pendingOtherAppResign {
                    Text("这将移除「\(app.displayName)」的当前证书，并使用你的 Apple ID 重新签发新证书。\n\n此操作可能导致该应用的保存设置和文件丢失。")
                }
            }
            .confirmationDialog("检测到 App 扩展",
                                isPresented: $viewModel.showExtensionChoice,
                                titleVisibility: .visible) {
                Button("扩展用主 profile 签名") {
                    viewModel.confirmExtensionChoice(.useMainProfile)
                }
                Button("移除所有扩展") {
                    viewModel.confirmExtensionChoice(.removeExtensions)
                }
                Button("取消", role: .cancel) {
                    viewModel.confirmExtensionChoice(.cancel)
                }
            } message: {
                Text("该 IPA 包含 PlugIns 扩展（*.appex）。\n「扩展用主 profile 签名」：iOS 要求扩展代码签名必须是具体 application-identifier，不能用通配符，因此扩展仍会各自注册具体 profile 再签名（保证可正常安装）；此选项与「标准签名」等价。\n「移除所有扩展」：签名前删除所有 PlugIns/*.appex，扩展功能将不可用。")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 打开文件选择器
    private func openFilePicker() {
        let picker = IPAFilePicker { url in
            viewModel.importIPA(url: url)
        }
        picker.present()
    }

    // MARK: 底部状态条
    @ViewBuilder
    private var statusBar: some View {
        if viewModel.isBusy || viewModel.lastError != nil || !account.isSignedIn {
            HStack(spacing: 8) {
                if viewModel.isBusy {
                    ProgressView().scaleEffect(0.7)
                    Text(viewModel.progressMessage)
                        .font(.caption)
                        .lineLimit(1)
                } else if let error = viewModel.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundColor(.orange)
                    Text("未登录 Apple ID，无法重签")
                        .font(.caption)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    // MARK: 空状态
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无旁加载的应用")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("导入一个 .ipa，或下拉刷新重新扫描设备")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("导入 IPA") {
                openFilePicker()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
            Spacer()
        }
    }

    // MARK: 应用列表（v2.3.0：ScrollView + LazyVStack + 自定义滑动行）
    //
    // 🔴 为什么不再用 List：iOS 26 的 List 在「空状态行↔数据行」条件切换时布局测量
    //    错位——栏目标题叠卡、行与空态并存且持续到下次滚动（真机三连截图实锤；
    //    footer 化 + 显式 listStyle 两次修复均无效）。LazyVStack 完全可控。
    //    右滑/左滑动作由 SwipeableRow 自绘（DragGesture 横向判定，不抢竖向滚动）。

    private var appList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {

                // ── Section 1: ReSign 签应用 ──
                sectionHeader(title: "ReSign 签应用")
                if viewModel.installedApps.isEmpty {
                    emptyRow("暂无本机签名的应用")
                } else {
                    ForEach(viewModel.installedApps) { app in
                        SwipeableRow(trailing: rowActions(app, source: .installed)) {
                            AppRowView(app: app) { viewModel.resign(app: app) }
                        }
                    }
                }

                // ── Section 2: 其它应用 ──
                HStack(spacing: 4) {
                    Text("其它应用").font(.headline)
                    Spacer()
                    if !viewModel.otherApps.isEmpty {
                        Button("重签") {
                            if let first = viewModel.otherApps.first {
                                pendingOtherAppResign = first
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isBusy || !account.isSignedIn)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
                if viewModel.otherApps.isEmpty {
                    emptyRow("暂无其它应用")
                } else {
                    ForEach(viewModel.otherApps) { app in
                        SwipeableRow(trailing: rowActions(app, source: .other)) {
                            OtherAppRowView(app: app) { pendingOtherAppResign = app }
                        }
                    }
                }

                // ── Section 3: 小黑屋 ──
                HStack(spacing: 4) {
                    Text("小黑屋").font(.headline)
                    Button {
                        showBlacklistHelp = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
                if viewModel.blacklistedApps.isEmpty {
                    emptyRow("小黑屋里还没有应用")
                } else {
                    ForEach(viewModel.blacklistedApps) { app in
                        SwipeableRow(trailing: rowActions(app, source: .blacklist)) {
                            BlacklistRowView(app: app) { viewModel.resign(app: app) }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        // 清空数据：二次确认（数据不可恢复）+ 结果弹窗
        .confirmationDialog("清空数据",
                            isPresented: Binding(get: { pendingClearData != nil },
                                                 set: { if !$0 { pendingClearData = nil } }),
                            titleVisibility: .visible) {
            Button("清空数据", role: .destructive) {
                if let app = pendingClearData { viewModel.clearAppData(app: app) }
                pendingClearData = nil
            }
            Button("取消", role: .cancel) { pendingClearData = nil }
        } message: {
            if let app = pendingClearData {
                Text("将删除「\(app.displayName)」的全部数据（文档、设置、登录态），应用本身保留。\n\n此操作不可恢复！")
            }
        }
        .alert("清空数据结果", isPresented: Binding(get: { viewModel.clearDataResultText != nil },
                                                   set: { if !$0 { viewModel.clearDataResultText = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.clearDataResultText ?? "")
        }
        .alert("小黑屋", isPresented: $showBlacklistHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("将不喜欢的应用拉黑，后续所有续签 / 签名操作将会跳过这些应用。不过手动点击「重签」仍然可以为它们签名。")
        }
    }

    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }

    /// 各分区滑动动作（左滑露出）：卸载（v2.2.10 IC 通道）/ 清空数据 / 小黑屋增删
    private func rowActions(app: InstalledApp, source: BlacklistSource) -> [SwipeActionItem] {
        var items: [SwipeActionItem] = [
            SwipeActionItem(title: "卸载", icon: "trash", tint: .red, destructive: true) {
                pendingUninstall = app
            },
            SwipeActionItem(title: "清空数据", icon: "eraser", tint: .purple, destructive: false) {
                pendingClearData = app
            },
        ]
        switch source {
        case .installed:
            items.append(SwipeActionItem(title: "小黑屋", icon: "nosign", tint: .orange, destructive: false) {
                viewModel.addToBlacklist(app, source: .installed)
            })
        case .other:
            items.append(SwipeActionItem(title: "小黑屋", icon: "nosign", tint: .orange, destructive: false) {
                viewModel.addToBlacklist(app, source: .other)
            })
        case .blacklist:
            items.append(SwipeActionItem(title: "移出", icon: "checkmark.circle", tint: .blue, destructive: false) {
                viewModel.removeFromBlacklist(app)
            })
        }
        return items
    }
    }
}

// MARK: - 徽标辅助

/// 通用胶囊徽标（注意：不能叫 badge，否则与 SwiftUI 的 View.badge() 实例方法冲突，
/// 在 View 上下文里调用会解析到实例方法导致编译错误）
private func reproBadge(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .cornerRadius(4)
}

/// 通用胶囊徽标（保留旧名兼容）
private func pill(_ text: String, color: Color) -> some View {
    reproBadge(text, color: color)
}

/// 证书 / Apple ID 来源徽标（依据 embedded.mobileprovision 到期时间判定：
/// 距今天数 < 30 视为 Apple ID 免费签，否则视为证书签）
private func signingSourcePill(_ app: InstalledApp) -> some View {
    let color: Color
    let text: String
    switch app.signingSource {
    case .cert:    (color, text) = (.purple, "证书")
    case .appleID: (color, text) = (.blue, "Apple ID")
    case .unknown: (color, text) = (.secondary, "未知")
    }
    return reproBadge(text, color: color)
}

// MARK: - 公共行组件（三个 RowView 共用，消除三份拷贝）

/// 应用图标（48×48 圆角，无图标时显示占位）
private struct AppIconView: View {
    let icon: UIImage?
    var body: some View {
        if let icon = icon {
            Image(uiImage: icon)
                .resizable()
                .frame(width: 48, height: 48)
                .cornerRadius(10)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "app").foregroundColor(.secondary))
        }
    }
}

/// 有效时间徽标：已过期 / 临近过期 / 有效 / 无描述文件
private struct ExpiryBadgeView: View {
    let app: InstalledApp
    var body: some View {
        if let daysLeft = app.daysUntilExpiry {
            if daysLeft < 0 {
                reproBadge("已过期", color: .red)
            } else if daysLeft <= 3 {
                reproBadge("\(daysLeft) 天后过期", color: .orange)
            } else {
                reproBadge("有效 (\(daysLeft) 天)", color: .green)
            }
        } else if app.hasEmbeddedProvision {
            reproBadge("到期时间未知", color: .secondary)
        } else {
            reproBadge("无描述文件", color: .secondary)
        }
    }
}

// MARK: - 应用行视图

struct AppRowView: View {
    let app: InstalledApp
    let onResign: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(icon: app.icon)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if app.isSigning {
                    ProgressView(value: Double(app.signingProgress), total: 100)
                        .frame(maxWidth: 160)
                } else {
                    HStack(spacing: 4) {
                        ExpiryBadgeView(app: app)
                        signingSourcePill(app)
                    }
                }
            }

            Spacer()

            if app.isSigning {
                Text("\(app.signingProgress)%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Button("重签", action: onResign)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 其他应用行视图
//
// v1.1.113: 行结构与徽标样式统一为与「ReSign 签应用」(AppRowView) 一致：
//   名称 / BundleID（独占一行）/ [有效期胶囊 + 证书·Apple ID 来源胶囊]。
// 原「原始签名者 Team ID + 内联到期文字 + 来源胶囊」挤在一行且行内额外 16pt 左右内边距，
// 文字易被徽标挤压截断（BundleID/TeamID 被遮挡），改为三行结构后不再互相挤压。

struct OtherAppRowView: View {
    let app: InstalledApp
    let onResign: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(icon: app.icon)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // 与 AppRowView 同款徽标：有效期 + 证书 / Apple ID 来源
                HStack(spacing: 4) {
                    ExpiryBadgeView(app: app)
                    signingSourcePill(app)
                }
            }

            Spacer()

            if app.isSigning {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button("重签", action: onResign)  // v2.2.12：语义修正（该按钮触发重签确认流程）
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(false)
            }
        }
        .padding(.vertical, 4)   // 与 AppRowView 一致，去掉额外水平内边距，避免行内容被挤压
        .contentShape(Rectangle())
    }
}

// MARK: - 小黑屋应用行视图

struct BlacklistRowView: View {
    let app: InstalledApp
    let onResign: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(icon: app.icon)

            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // 有效时间 + 证书 / Apple ID 来源
                HStack(spacing: 4) {
                    ExpiryBadgeView(app: app)
                    signingSourcePill(app)
                }
            }

            Spacer()

            if app.isSigning {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button("重签", action: onResign)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 64) // 固定行高，避免 List 单元格复用时的滚动鬼影/掉帧
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}


// MARK: - 滑动动作模型 + 可滑行容器（v2.3.0）

struct SwipeActionItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let tint: Color
    let destructive: Bool
    let handler: () -> Void
}

/// 自定义滑动行：左滑露出 trailing 动作、右滑露出 leading 动作。
/// DragGesture 横向判定后才接管，竖向滚动不受影响；动作点击后自动收回。
struct SwipeableRow<Content: View>: View {
    var leading: [SwipeActionItem] = []
    var trailing: [SwipeActionItem] = []
    @ViewBuilder var content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var baseOffset: CGFloat = 0
    @State private var dragging = false

    private let maxReveal: CGFloat = 148

    var body: some View {
        ZStack {
            // 底层动作按钮：offset<0（左滑）露右侧按钮组；offset>0（右滑）露左侧按钮组
            HStack(spacing: 8) {
                if offsetX < 0 { ForEach(trailing) { actionButton($0) } }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 8) {
                if offsetX > 0 { ForEach(leading) { actionButton($0) } }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .offset(x: offsetX)
                .gesture(swipeGesture)
        }
        .padding(.horizontal, 16)
    }

    private func actionButton(_ a: SwipeActionItem) -> some View {
        Button {
            a.handler()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offsetX = 0 }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: a.icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(a.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .frame(width: 62, height: 58)
            .background(RoundedRectangle(cornerRadius: 10).fill(a.tint))
        }
        .buttonStyle(.plain)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { v in
                if !dragging {
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    dragging = true
                    baseOffset = offsetX
                }
                let candidate = baseOffset + v.translation.width
                offsetX = min(maxReveal, max(-maxReveal, candidate))
            }
            .onEnded { _ in
                guard dragging else { return }
                dragging = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if offsetX > 44 { offsetX = maxReveal }
                    else if offsetX < -44 { offsetX = -maxReveal }
                    else { offsetX = 0 }
                }
            }
    }