# 项目格式：`.mojoproject` 文档包

> W1 定义。清单结构体见 `Packages/FairyCore/Sources/ProjectCore/Model/ProjectManifest.swift`；
> 读写实现见 `Store/ProjectStore.swift`、`Store/ProjectLibrary.swift`、`Store/ZipArchive.swift`。

## 包布局

`<projectID>.mojoproject/`（目录，`projectID` 为 UUID）：

```
<uuid>.mojoproject/
  project.json            # 清单（UTF-8 JSON，ISO-8601 日期，pretty + sorted keys）
  Sources/                # Swift 源码（交给运行时的只有 Sources/ 下 .swift）
  Resources/              # 只读资源（W1 占位）
  Documents/              # 用户文档（W1 占位）
  Data/                   # 业务数据（W4 使用）
  Tests/                  # 项目内测试（W1 占位）
```

常量见 `ProjectLayout`：包扩展名 `mojoproject`、清单文件名 `project.json`、
目录名 `Sources` / `Resources` / `Documents` / `Data` / `Tests`。

## project.json 全字段

| 字段 | 含义 |
|---|---|
| `schemaVersion` | 清单格式版本（当前 1）。更高版本拒绝打开，不猜未知字段语义 |
| `projectID` | 项目身份（UUID）。复制/导入一律换新 ID |
| `displayName` | 作品名（重命名只改此字段） |
| `runtimeVersion` | 创建/迁移时的运行时语义版本（"主.次.修订"，如 "0.1.0"）。作品卡兼容性对比用 |
| `languageProfile` | 语言配置（v1 固定 `swift-subset-v1`） |
| `moduleName` | 传给运行时的模块名（显示名派生：只留 ASCII 字母数字下划线，空则 "App"） |
| `entryKind` | `nativeSwift`（`web` 为 W4 预留） |
| `entryFile` | 脚本入口：顶层代码文件的项目相对路径（与 `entrySymbol` 互斥） |
| `entrySymbol` | 根视图入口：根 View 类型名（与 `entryFile` 互斥；都为空 = `@main App` 入口） |
| `category` | 可选；模板库分类名（首页「模板」区按此分组；缺省归入「其他」） |
| `sourceRoots` / `resourceRoots` | 源码/资源根（默认 `["Sources"]` / `["Resources"]`） |
| `dataSchemaVersion` | `Data/` 的 schema 版本；0 = 尚无数据模型 |
| `requestedCapabilities` | 声明需要的宿主能力（capability catalog ID），供权限预检 |
| `templateID` | 从模板创建时的模板 ID（空白/导入为 null） |
| `createdAt` / `modifiedAt` | 创建/修改时间（每次提交更新 `modifiedAt`） |
| `revision` | 修订号：每次成功提交单调 +1 |
| `files` | 文件表：`[{id, path}]`（内容只存各自文件，不进清单） |
| `appliedChangeSets` | 最近提交的 ChangeSet ID（幂等去重，保留最近 500） |

## fileID 稳定语义

- 文件身份是 `files[]` 中的 `id`，不是路径。**改名只改 `path`，`id` 不变**；
  运行时的 `ProgramSource` 文件顺序无关，跨改名引用不断。
- `entryFile` 存的是路径：入口文件改名时提交逻辑按同 `fileID` 的新路径同步清单；
  入口文件被删时清单保留旧路径（工作区给出内联诊断提示，由用户恢复或改名回入口路径）。

## 原子写与快照

- 提交流程：`revision` 匹配 → `ChangeSetPreview.apply` 内存演算
  （哈希/路径/上限一次验清，失败不碰磁盘）→ 全新临时目录写所有文件 + manifest
  → 同卷 `FileManager.replaceItemAt` 整体替换 → `revision` + 1。
- 幂等：`appliedChangeSets` 含本次 `changeSetID` 即抛 `alreadyApplied`（不写盘）。
- 写前记录：旧 manifest + 本次被覆盖/改名/删除文件的旧内容写入
  `Documents/.snapshots/<projectID>/r<rev>/`（`r<rev>` = 提交前的修订号），最小回滚。
  注意：`.snapshots` 在包外（`Documents/` 下），导出 ZIP 不包含它。
- 推送：每次成功提交后，`snapshots()` 的所有订阅者收到新快照（含其他窗口/AI 的提交）。
- 删除作品：作品包 + `.snapshots/<projectID>` + `Data/<projectID>` 一起移除（删前二次确认）。

## ZIP 规则（导入/导出）

- 导出：`project.json` + 包内全部文件，stored（不压缩）编码，自带实现（`ZipArchive`，无第三方依赖）。
- 导入先解码（stored + deflate 都接受；加密、`data-descriptor`、未知压缩方法拒绝），再逐条拒绝：
  - 路径穿越（`..`、`.`、空段）、绝对路径、控制字符（与 `ChangeSetPreview.validatePath` 同规则）；
  - 符号链接（外部属性文件类型 `0o120000`）；
  - 大小写冲突（大小写不敏感文件系统上会互相覆盖，按小写比较）；
  - 限制（由 `ProjectLimits.default` 派生）：文件数 ≤ `maxSourceFiles × 2`、
    单文件 ≤ `maxFileBytes`、总量 ≤ `maxTotalSourceBytes × 2`。
- `project.json` 存在 → 按项目包导入：校验 `schemaVersion`、文件表逐一核对
  （缺失/非 UTF-8 拒绝），**换新 `projectID`、`revision` 清零**；
  缺失 → 按“裸源码包”导入：`.swift` 收进 `Sources/`（取文件名），入口取首个
  `struct X: View`，找不到则 `ContentView`，其余文本文件保留相对路径。
- 导入单个 `.swift`：复制进新托管包的 `Sources/`，**不碰原文件**。
