# 进度（长任务续跑入口）

- 当前阶段：**W 阶段整合完成**（2026-09-30）。W1 项目/工作区 + W2 助手闭环 + W3 解释器广度
  全部在 main 工作树实现并测试；UI 已重排为"左（会话历史/设置）—中（聊天）—右（运行预览）"三面板。
- 已验证（2026-09-30）：
  - `scripts/spm.sh test`：183 项全绿（SwiftRuntime 101 含 36 个差分夹具 + W4 标准库、
    ProjectCore 22、FoundationAI 49 含 OpenRouter 14 项 mock、NativeBridge 21 等）；
  - iOS 27 模拟器（iPhone 17 Pro iOS27 / iPad Pro 11 iOS27，已创建）：App 单测 43/43、
    UI 测试三面板/全流程通过；真实模型调用在模拟器仍不可用（属预期）；
  - 标准库 supported 72 → 138（docs/SWIFT_SUPPORT.md 已重生成）；模板 23 个按 8 类分组。
- 主要能力：agent 工具循环（设备端）、[[MORE]] 自动续作、OpenRouter 云端后端（Keychain 存 Key、
  独立授权、逐类错误映射，见 docs/OPENROUTER.md）、多会话历史（内存态）。
- 未完成 / 待实机：
  - **OpenRouter 真实 API 验证**（需用户 Key：设 FAIRY_OPENROUTER_LIVE=1 + FAIRY_OPENROUTER_KEY
    跑门控测试；>4096 token 请求 / 多文件生成 / 失败恢复 / 取消不落盘的实机口径）；
  - iPhone 实机 AI_EVAL 三固定任务（签名账户阻塞仍是前置，见下）；
  - 对话历史持久化（内存态，待 M3 定序列化边界）、真实 FoundationModels Tool 挂接已做（agent），
    候选隔离运行仍在 M3；
  - W4 网页运行时 / 数据持久化 / 导出；W5 视觉统一与打磨；之后 M1–M5 细化验收。
- 环境注记：iOS 27.0 模拟器运行时已装但默认无设备（已手工创建 iPhone 17 Pro iOS27 /
  iPad Pro 11 iOS27）；`build-verify.sh` 需 `FAIRY_OS=26.3.1`（脚本已支持）指向 26.3 设备。
- 历史环境结论（M0 期）：iPhone 实机签名账户阻塞（Team 978L5PZ2LT ≠ 要求 66F6479Y4Q）未解决；
  详见 docs/ENVIRONMENT.md。

## 历史记录

- M0 阶段（解释器、桥接、协调器、模型可用性）与更早的环境/验证记录见 git 历史
  与 `docs/progress/`、`verification/`；W1–W3 各包记录见 `docs/progress/W1.md`、
  `docs/progress/W2.md`、`docs/progress/W3.md`。
