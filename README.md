# OpenAnyway 2.0

一个用 **Swift + SwiftUI** 编写的原生 macOS 应用，专门解决 **“XXX 已损坏，无法打开。你应该将它移到废纸篓”**、“无法验证开发者”、“Apple 无法检查其是否包含恶意软件” 等打不开软件的问题。拖入应用，自动找出打不开的原因，一键修复；需要在系统设置里点“仍要打开”时，也能自动帮你点。

## 1. 功能

**自动检查（只读）**

- 支持任意文件：`.app`、`.dmg`、`.pkg/.mpkg`、插件（`.vst3/.component/.plugin/.bundle/.framework/.prefPane` 等）、命令行工具、脚本。
- 扫描**包内全部文件**的 `com.apple.quarantine` 隔离标记，显示下载来源（浏览器名称与下载网址）。
- 签名完整性与签名类型（未签名 / ad-hoc / Developer ID / App Store / Apple），读取 Entitlements。
- Gatekeeper (`spctl`)、公证票据 (`stapler`)、DMG 校验 (`hdiutil verify`)、PKG 签名、SHA-256。
- 处理器架构（是否需要 Rosetta、是否根本不兼容）、最低系统版本、是否位于只读 DMG 中、是否需要管理员权限。

**检查结果 → 推荐修复**

| 情况 | 推荐操作 | 风险 |
|---|---|---|
| 签名有效，只是未公证 / 被 Gatekeeper 拒绝 | 移除隔离标记（递归） | 低~中 |
| 未签名或 ad-hoc 签名不完整（开源软件常见） | 移除隔离标记 + ad-hoc 重签名 | 中 |
| 开发者签名已损坏（文件被改动/下载不完整） | 建议重新下载；可选 ad-hoc 重签名 | 高 |
| 应用在只读 DMG 中 | 先复制到 `/Applications` | 低 |
| DMG/PKG/工具被隔离 | 移除隔离标记（核对 SHA-256 后为低风险） | 低~中 |
| DMG 校验失败或哈希不一致 / 架构不兼容 | 不提供修复，只给建议 | — |

- 需要权限时自动使用 macOS 标准管理员密码框（`osascript … with administrator privileges`，参数全部 `quoted form` 转义）。
- 重签名前默认用 APFS 克隆备份到 `~/Library/Application Support/MacAppDoctor/Backups/`。
- 应用声明了 Entitlements（如 VMware Fusion 的虚拟化权限）时，**不会**预选重签名，因为 ad-hoc 重签名会让这些功能失效。
- 修复后自动复查，并可一键“打开试试”；也提供“隐私与安全性 → 仍要打开”的系统入口。

**一键放行（仍要打开）**

- 对原本正式签名、被重签名过的应用，macOS 只能在“系统设置 → 隐私与安全性”里手动放行。
- 一键放行会自动打开应用触发拦截、关掉提示、找到这个应用对应的“仍要打开”按钮并点击，你只需用触控 ID 或密码确认。
- 需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 OpenAnyway。不会点击“移到废纸篓”，也不接触密码。

**不会**：全局关闭 Gatekeeper（`spctl --master-disable`）、关闭 SIP、修改系统安全数据库、自动运行未知程序。

## 2. 如何在 Mac 上打开和运行

**快捷方式**：已安装并启动过 Xcode 的用户，可尝试双击 `一键构建并运行.command`，它会在本机编译并打开 APP（并非预编译应用）。如果 macOS 拦截 `.command` 或编译报错，请使用下面的 Xcode 方式。

1. 在 Mac 上解压本 ZIP。
2. 双击 `MacAppDoctor.xcodeproj`，使用 **Xcode 15 或更新版本**打开（推荐较新的稳定版）。
3. 在 Xcode 顶部 Scheme 中选择 `MacAppDoctor`，运行目标选择 `My Mac`。
4. 菜单栏 `Product → Run`，或者按 `⌘R`。
5. 首次启动后拖入需要检测的文件。无需安装 Python，也无需手工运行终端命令。

如需生成独立的本机调试 `.app`：在 Xcode 中 Build 后打开菜单 `Product → Show Build Folder in Finder`，在 `Products/Debug/` 找到 `OpenAnyway.app`，可复制到 `/Applications`（若使用 Finder 直接运行，macOS 可能要求手动批准本地签名）。

如需通用架构 Release：

```bash
xcodebuild -project MacAppDoctor.xcodeproj -scheme MacAppDoctor \
  -configuration Release -derivedDataPath ./DerivedData build
```

生成的包一般位于 `DerivedData/Build/Products/Release/OpenAnyway.app`。如要**向其他 Mac 分发**，需要使用自己的 Apple Developer ID 签名、公证；本项目默认采用适合本机 Xcode 开发的 ad-hoc 签名，不等于已公证发行版。

## 3. 示例：VMware Fusion “已损坏”

1. 把 `/Applications/VMware Fusion.app`（或 DMG 里的那个）拖进 OpenAnyway 窗口。
2. 如果结论是“被 Gatekeeper 下载隔离拦截”：勾选推荐的“移除下载隔离标记”，点击开始修复（需输入管理员密码），然后“打开试试”。
3. 如果结论是“开发者签名已损坏”：说明文件内容和签名对不上，**最好从 Broadcom 官网重新下载**。VMware 依赖虚拟化等特殊权限，ad-hoc 重签名后虚拟机功能很可能无法使用。
4. DMG 可以先拖入并粘贴官网 SHA-256 核对，确认下载完整。

## 4. 已知限制

- **不是杀毒软件**。签名有效或 Gatekeeper 接受都不是绝对安全证明。
- 不联网下载发布者签名/哈希，不保证用户粘贴的 SHA-256 来自真实官方网站；用户必须自行核对来源。
- `spctl` 是系统评估，`stapler validate` 只验证是否附加了可用票据，不代表全部在线公证状态；没有将“无 stapled ticket”直接判定为恶意软件。
- APP 的检查对已挂载 DMG 内的文件可能受只读权限限制。
- Finder 右键扩展、自动监控 Gatekeeper 弹窗、批量处理**尚未实现**。
- 如果 Xcode 无法运行，请先选择 `My Mac`、检查最低 macOS 版本并根据自身环境调整签名选项。

## 5. 工程结构

```text
MacAppDoctor.xcodeproj/        Xcode 工程与共享 Scheme
MacAppDoctor/
  MacAppDoctorApp.swift        应用入口
  Core/
    Models.swift              数据模型（报告、修复动作、风险等级）
    DiagnosisEngine.swift     纯逻辑：判断原因 + 推荐修复
    ExtendedAttributes.swift  直接读写扩展属性（隔离标记、下载来源）
    CommandRunner.swift       无 shell 参数传递、管理员执行、哈希工具
    FileInspector.swift       只读检查
    RepairService.swift       按序执行修复、管理员权限回退、备份、复查
  UI/
    AppState.swift            主状态管理与异步检查
    Components.swift          通用视觉组件、文件选择
    ContentView.swift         窗口内容
    MainView.swift            唯一的主页面：拖入应用 → 一键修复 / 一键放行
    OpenAnywayAutomator.swift 自动点击系统设置里的“仍要打开”
    OpenAnywayGuide.swift     手动放行步骤
  Assets.xcassets/             App 图标
Tests/CoreSmokeTests.swift     可在 Linux/macOS 检查的策略用例
```

## 6. 开发自检

在 macOS 或有 Swift 工具链的环境中，可以执行：

```bash
swiftc -typecheck MacAppDoctor/Core/*.swift
swiftc MacAppDoctor/Core/*.swift Tests/CoreSmokeTests.swift -o /tmp/macappdoctor-test
/tmp/macappdoctor-test
```

`swiftc -typecheck` 覆盖核心模块；SwiftUI 界面和系统工具的实际集成仍需在 **macOS + Xcode** 测试。

## 7. 安全原则

用户决定软件来自何处；代码只做可验证的本地技术检查。禁止任意开启不安全的通用绕过开关，禁止删除系统安全数据库，禁止未经明确同意静默修改应用。
