# RePro 变更日志（rootless / main 分支，x.1.x 系列）

## v2.1.39 — 修复「重签失败自动卸载目标 App」

### 问题 / Problem
- 重签时若目标 App 与当前 Team ID 冲突（installd 报 `error.code == 64` / `"LaunchServicesError error 0"`），
  引擎会**在用户不知情下自动卸载目标 App 并重试**，导致用户数据（文档、设置、登录态）被静默清除。
- 这是用户明确指出的 bug：「重签失败的应用会自动卸载目标应用」。

### 根因 / Root Cause
- `RPVApplicationSigning.m` 的 `_installIpaAtPath:` 在 Team ID 冲突分支直接调用
  `uninstallApplication:` 后递归重试，没有任何用户确认环节。

### 修复 / Fix
- **移除自动卸载重试**：Team ID 冲突时不再静默卸载目标 App。
- **改为弹窗确认**：引擎发 `cn.analy.resign.uninstall-confirm` 通知（带 bundleID / 显示名 / 临时目录路径），
  SwiftUI 弹出 `confirmationDialog`「是否需要卸载」：
  - 文案：「卸载『X』会丢失该应用的数据（文档、设置、登录态等）。取消则仅清理本次重签产生的临时文件，保留应用。」
  - 「卸载」（destructive）→ 调用 `removeApplicationWithBundleIdentifier:`（沿用现有 iOS 26 回退链）。
  - 「取消」（cancel）→ 仅清理本次重签临时目录 `applicationTemporaryDirectory/<bundleID>/`，**保留目标 App**。
- 新增引擎方法 `cleanupTemporaryDirectoryForBundleIdentifier:` → 经 `RPVBridge` / `BridgeClient` 暴露给 Swift。
- 全链路：引擎 → `NSNotification` → `SigningViewModel`（主线程 observer）→ `AppsView` `.confirmationDialog` → `confirmUninstall(_:)`。
- `installCount` 平衡逻辑不受影响（冲突分支不再 `return`，统一走下方 cleanup + `installCount--` + complete 检查）。

### 改动文件
- `Vendor/ReProvision/Application Database/RPVApplicationSigning.m`（移除自动卸载重试；新增 cleanup 方法；发通知）
- `App/Sources/Bridge/RPVBridge.m` + `RPVBridge.h`（转发 cleanup）
- `App/Sources/Util/BridgeClient.swift`（新增 `cleanupTemporaryDirectory(bundleID:)`）
- `App/Sources/ViewModels/SigningViewModel.swift`（observer + `confirmUninstall` + 状态）
- `App/Sources/Views/AppsView.swift`（新增卸载确认 `confirmationDialog`）
- `Scripts/gen_pbxproj.py`、`Packages/rootless/DEBIAN/control`（版本 2.1.38 → 2.1.39）

### 版本 / Version
- `MARKETING_VERSION` 2.1.38 → 2.1.39；`CURRENT_PROJECT_VERSION` 60 → 61；deb `2.1.39~release`。

### 已知遗留 / Known Issues（重要）
- **iOS 26 卸载入口仍未 100% 坐实**：v2.1.38 在 iOS 26.0.1 真机实测 `MobileInstallationUninstall` 符号被 strip
  （dlsym 返回 NULL），「安装/卸载共用 MobileInstallation」在该固件不成立。
  - `MobileInstallationUninstall` 是**真实存在的标准私有符号**（与 `MobileInstallationInstall` 成对），并非臆想；
    只是 26.0.1 上被 strip，dlsym 取不到。
  - 用户设备为 iOS 26.6，本环境无法 SSH 探测（192.168.2.110 不可达），故 26.6 上该符号是否可用**未知**。
  - 「确认卸载」路径沿用现有 `LS + MobileInstallationUninstall` 回退并打详细诊断日志；
    **请在 26.6 真机点一次「卸载」并把日志发回**，以确证该符号在 26.6 是否可用。
  - 若 26.6 仍被 strip，需另寻 InstallCoordination 卸载类（目前框架无对称 `IXAppUninstallCoordinator`，
    仅 `IXUninstallOptions.h`；daemon 侧也无卸载实现）。

### 经验小结 / Lessons
- 用户铁律「先拿真实证据，绝不一拍脑袋改」：v2.1.38 的回退方案在 26.0.1 真机已被证伪，
  切勿在 26.6 上盲目假设同一符号可用。
- 「安装/卸载共用 MobileInstallation」是一般成立的对称假设，但在被 strip 的具体固件上会失效，
  必须以 dlsym 实测为准，不能凭「我记得能卸载」下定论。

---

## v2.1.38 — iOS 26 卸载回退尝试（已被 26.0.1 真机证伪，保留代码作诊断）
- 三个卸载点（Team ID 冲突重试 / 手动卸载按钮 / 系统通知清理）加 iOS 26 门控，回退 `MobileInstallationUninstall`。
- 26.0.1 真机：`MobileInstallationUninstall` 符号被 strip，dlsym 返回 NULL → 回退失败（见上「已知遗留」）。
