# 进度（长任务续跑入口）

- 当前阶段：**M0 收尾**——M0-A / M0-B / M0-C 已完成模拟器与 macOS 口径验证；iPhone 实机复验由主代理执行（M0-C 包内受阻于签名账户）。下一阶段 M1。
- 环境结论（2026-09-24 复核）：Xcode 26.3 / iOS 26.2 SDK / macOS 15.7.4；无 iOS 27 SDK；PCC API 缺失；iPhone 16 Pro Max（iOS 27.0）有线连接后 `ddiServicesAvailable: true`，实机阻塞点是签名账户（Xcode 账户只有 Team 978L5PZ2LT，配置要求 66F6479Y4Q）；iPad Pro 11 (M5) 已配对 iOS 27.0 但 tunnel 不可用。详见 docs/ENVIRONMENT.md「实测变化」。

## 已验证
- macOS `swift test`（Packages/FairyCore）：103 tests / 17 suites 通过。
- `scripts/build-verify.sh`：iPhone 17 Pro 与 iPad Pro 11 (M5) 模拟器 BUILD / TEST SUCCEEDED；FairyStudioTests 28/28、FairyStudioUITests 10/10（全部真实 SwiftRuntime 引擎）。
- 端到端：Counter 模板 Count 0→1→2、状态序列 idle→validating→preparing→running→stopping→stopped、改源码重跑、文件顺序无关、class 继承 → `syntax.class`、除零 → runtimeTrap、无限循环停止（App 内 6.4 / 11.5 ms）、默认预算中断、30 次运行—停止实例 / 线程 / 任务 0。
- 夹具引擎不在 App 任何配置中（`scripts/check-release-link.sh` failures=0）。
- 契约对齐（CR-1 / B-7 / B-5）双方实现 + 测试；RuntimeContracts 源码未改。
- 汇总：verification/M0.md、verification/ACCEPTANCE.md；各包细节：docs/progress/M0-A.md、M0-B.md、M0-C.md。

## 未完成
- iPhone 实机复验、实机模型可用性与一次真实本地调用（主代理执行；脚本 `scripts/device-verify.sh`，测试 `OnDeviceModelCallTests`）。
- 产品配置（iOS 27.0）运行：需 Xcode 27 / iOS 27 SDK（macOS 26.6+）。
- PCC：SDK 缺失 + 资格未核对。
- sheet / alert / 导航 / Slider 真实引擎端到端 UI（M2）。
- verification/ACCEPTANCE.md 需按任务书第 20 节原文核对条目。

## 下一步
- M1：ProjectCore（.mojoproject、ZIP 导入校验、快照 / 事务）+ TextKit 2 编辑器（替换 M0 的 CodeTextView）+ iPhone / iPad 工作区布局。
