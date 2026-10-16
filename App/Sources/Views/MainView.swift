import SwiftUI

// MARK: - iOS 26 液态玻璃适配（v2.1.35）
// 🔴 仅 iOS 26+（新系统）生效，低版本视觉完全不变。
// 用原生 SwiftUI glassEffect（iOS 26 API）：CI 已切 Xcode 26（iOS 26 SDK）编译，
// deployment target 16.0 + #available(iOS 26.0, *) 包装 → 低版本走 else 原样式。
// 系统组件（TabBar/NavigationBar）在 iOS 26 SDK 编译下自动玻璃化，无需改代码。

// MARK: - 主界面：系统原生 TabView + 原生 TabBar

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
                // iOS 26 液态玻璃：橙色微光 + 玻璃材质（保留"进行中"语义）
                Color(.systemOrange).opacity(0.12).glassEffect(.regular)
            } else {
                Color(.systemOrange).opacity(0.12)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}
