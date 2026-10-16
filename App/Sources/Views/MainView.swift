import SwiftUI
import UIKit

// MARK: - 主界面：系统原生 TabView + 原生 TabBar

// MARK: - iOS 26 液态玻璃适配（v2.1.34）
// 🔴 仅 iOS 26+（新系统）生效。CI 构建机 SDK 是 iOS 18（无 glassEffect 符号），
// 不能直接调 SwiftUI glassEffect；改在运行时经 NSClassFromString 反射拿 UIGlassEffect
// （UIKit 26 新增类），旧 SDK 编译、新系统渲染真玻璃。调用处自带颜色兜底，
// 即使反射失败也只是退回原纯色背景，不影响可用性。

/// 运行时解析 UIGlassEffect 并渲染的玻璃层（iOS 26+；旧系统 effect 为 nil → 透明）。
struct LiquidGlassBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: Self.glassEffect())
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}

    /// 反射取 UIGlassEffect（先试类方法 +effect，再试 init；拿不到返回 nil）。
    static func glassEffect() -> UIVisualEffect? {
        guard let cls = NSClassFromString("UIGlassEffect") as? NSObject.Type else { return nil }
        let effectSel = NSSelectorFromString("effect")
        if cls.responds(to: effectSel),
           let r = cls.perform(effectSel)?.takeUnretainedValue() as? UIVisualEffect {
            return r
        }
        let newSel = NSSelectorFromString("new")
        if cls.responds(to: newSel),
           let r = cls.perform(newSel)?.takeUnretainedValue() as? UIVisualEffect {
            return r
        }
        return nil
    }
}

struct MainView: View {
    @ObservedObject private var resign = ResignProgress.shared

    var body: some View {
        VStack(spacing: 0) {
            // 续签横幅（顶部固定，仅进行中显示）
            if resign.isResigning {
                resignBanner
            }

            // 系统 TabView + 原生 TabBar（100% 可靠）
            TabView {
                AppsView()
                    .tabItem {
                        Image(systemName: "square.stack.3d.up")
                        Text("应用")
                    }
                SettingsView()
                    .tabItem {
                        Image(systemName: "gearshape")
                        Text("设置")
                    }
                LogView()
                    .tabItem {
                        Image(systemName: "doc.text")
                        Text("日志")
                    }
                HealthView()
                    .tabItem {
                        Image(systemName: "chart.bar.doc.horizontal")
                        Text("状态")
                    }
            }
            .accentColor(.blue)
        }
    }

    /// 续签进行中横幅
    private var resignBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(resign.title)
                    .font(.subheadline.weight(.semibold))
                Text(resign.message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)   // 与顶栏a刷新图标同X轴对齐
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background {
            if #available(iOS 26.0, *) {
                // iOS 26：橙色微光兜底 + 液态玻璃
                ZStack {
                    Color(.systemOrange).opacity(0.12)
                    LiquidGlassBackground()
                }
            } else {
                Color(.systemOrange).opacity(0.12)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}
