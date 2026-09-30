# OpenRouter 云端后端（2026-09-30 接入）

产品调整：在 Apple PCC 尚未获批期间，OpenRouter 作为**可选**云端后端。Apple 本地模型与 PCC
接口原样保留；Swift 编辑器、解释器、项目格式、业务数据零改动。

## 1. 通道（要求 1）

- `OpenRouterProvider`（FoundationAI/OpenRouterProvider.swift）：原生 HTTP POST
  `/api/v1/chat/completions`，SSE 流式（`data:` 行 + `[DONE]`），快照式增量输出、
  任务取消（URLSession 取消 → CancellationError）。
- **不经过** Apple 本地模型或 LanguageModelSession，不继承 4096 上下文限制；
  `max_tokens` 按所选模型的目录上限设置。

## 2. Key 管理（要求 2）

- 设置（助手 → 设置 → OpenRouter）：启用开关、SecureField 输入 Key、连接测试、模型选择。
- Key 存 **Keychain**（App/Assistant/OpenRouterKeychain.swift，kSecAttrAccessibleAfterFirstUnlock）；
  界面只显示"已配置（…尾4位）"。不内置任何开发者 Key。
- 网络审计测试锁定边界：Key 只出现在 OpenRouterProvider.swift 的 HTTP 头；
  提示词组装文件（AssistantPipeline/Tools/Proposal）不得引用 Key（apiKeyDoesNotReachPromptAssembly）。

## 3. 模型目录与 token 预算（要求 3）

- 模型清单（2026-09-30，用户指定）：z-ai/glm-5.3-flash（默认）、deepseek/deepseek-v4.1-flash、
  openai/gpt-6-luna-pro、openai/gpt-6-luna、xiaomi/mimo-v2.6-flash、xiaomi/mimo-v2.6-pro、
  vidia/nemotron-3-ultra-550b-a55b:free（免费）。
- 上下文长度与输出上限**不在代码里编造**：设置页"更新模型目录"经 GET /api/v1/models
  实时核对并缓存（provider.modelInfo 实时优先），未核对前显示"待核对"。
- 不编造模型 ID、不自动切换模型（切换仅由用户在设置中选择，选择持久化到 UserDefaults）。
- token 统计来自响应 `usage.include` 的真实值（provider.lastUsage），按模型独立口径；
  **不使用 Apple tokenizer**。上下文超限错误映射为 `exceededContextWindowSize`，触发既有
  预算退避（缩签名 → 去旧轮次）。
- 系统提示词（AssistantSession.instructions）已重写为针对本 App 的 Apple/Swift 编程提示词：
  运行环境硬约束（不支持的语法）、受支持视图/修饰符清单、状态与数据写法、输出协议、
  多文件分批与 [[MORE]] 规则、校验回喂机制。


## 4. 变更提交纪律（要求 4）

OpenRouter 走与文本路径相同的闭环：完整接收 → ```json 块解析 → expectedBaseHash 自动填入 →
ChangeSetPreview 内存演算 → SwiftRuntime 校验 → 变更卡片 → 应用运行。
`finish_reason=length/error`、流中断 → `truncatedOutput` 失败，**不得自动提交**；
`[[MORE]]` 只在完整轮次边界触发，绝不拼接半成品流。

## 5. 能力清单不可绕过（要求 5）

提示词照常携带能力目录摘要（agent 模型另可用 readCapability 工具）；任何后端的产出都经过
同一解释器校验、同一执行预算、同一数据隔离与授权门。

## 6. 授权与显示（要求 6）

- 三个后端在设置中分别显示；OpenRouter 有**独立**授权开关（OpenRouterConsentStore，默认拒绝）。
- Broker 在发起请求前校验授权：未授权时连 HTTP 都不发起（有测试锁定 requestCount==0）。
- 设置页明示"请求将发送至 OpenRouter 及其上游模型供应商"；失败时不放宽授权。

## 7. 错误逐类处理（要求 7）

| 情形 | 映射 |
|---|---|
| 401/403 | `authFailed`（提示检查 Key） |
| 402 | `insufficientCredits` |
| 429 | `rateLimited` |
| 400/消息含 context length | `exceededContextWindowSize`（触发退避） |
| 404 / 结构不符 | `endpointIncompatible` |
| 流中途 error 对象 | 逐类映射并终止 |
| finish_reason=length/error | `truncatedOutput` |
| 用户取消 | `CancellationError`（迟到结果不落盘） |

无任何无条件重试路径。

## 8. 测试状态（如实区分）

**mock 已测**（URLProtocol 拦截，FoundationAITests/OpenRouterProviderTests.swift，49 项中 14 项）：
SSE 组装与快照、usage 独立统计、Key 只进请求头、401/402/429/400 映射、截断不提交、
流中断映射、授权门（未授权 0 请求）、授权后放行、无 Key 可用性；会话级 openRouter 后端
经同一管线应用变更（AssistantSessionTests）。

**真实 API 待验证**（需要用户自己的 Key，门控测试
`liveRequestBeyondAppleLimit`：设 `FAIRY_OPENROUTER_LIVE=1` 与 `FAIRY_OPENROUTER_KEY` 后运行）：
>4096 token 真实请求（证明不受 Apple 限制）、多文件生成、局部修改、失败恢复、取消后不落盘
的实机口径。**未跑真实 API 前，不得宣称这些能力已验证。**
