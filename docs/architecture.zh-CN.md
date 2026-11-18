# WordLinks（词文库）架构与开发指南

本文档面向开发者，说明 WordLinks 的工程结构、数据边界、构建脚本与测试方式。

## 技术栈与构建脚本

- **工程与语言**：SwiftPM 工程（`Package.swift`），Swift tools 6.0 / Swift 5 语言模式，最低支持 macOS 14.0。界面基于 SwiftUI + AppKit（`NSTextView`、`NSSplitView`），Markdown 解析使用 `swift-markdown` 0.5.0（锁定于 `Package.resolved`），词形数据库通过 `CSQLite` 只读访问。
- **应用入口**：[WordLinksApp.swift](../Sources/WordLinks/WordLinksApp.swift) 初始化 `ReadingLibraryStore`、`AISettingsStore`、语言与外观状态后注入主窗口与设置窗口；若本地资料打开失败则明确提示错误，不覆盖写空资料。
- **打包与签名**：
  - `Scripts/build-app.sh`：使用 Xcode 26+ SDK 编译 release（启用 `FoundationModels` 与原生分层图标编译），组装 `build/Wordlinks.app`、安装资源与图标并完成签名。
  - `Scripts/sign-app.sh`：使用 `~/Library/Application Support/ReadingToolDaily/CodeSigning/` 中稳定的本地证书签名并执行 `codesign --verify --strict` 校验。
- **运行测试**：`swift test` 或 `zsh Scripts/test.sh '<Filter>'`。

## 源码导航

所有核心源码位于 `Sources/WordLinks/`：

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| 应用入口与本地化 | `WordLinksApp.swift`、`Localization.swift` | 场景注入、环境绑定、`L(中文, English)` |
| 阅读库窗口 | `LibraryWindow.swift` | 三栏布局、档案与文件夹管理、文章/词汇视图路由、导入导出触发 |
| 工具栏与分栏几何 | `LibrarySidebarCommands.swift`、`ReaderDisplayCommands.swift` | 边栏与显示菜单命令、详情栏原生标题几何与宽度同步 |
| 积累内联编辑 | `InlineStudyEditing.swift` | 每窗口编辑协调器、原生命中编辑器、错误处理、系统 Undo/Redo |
| CSV 导出 | `StudyLibraryExport.swift`、`StudyLibraryCommands.swift` | 一致快照、UTF-8 BOM CSV 编码、`NSSavePanel` 代理与 `⌘E` |
| 核心资料存储 | `ReadingLibraryStore.swift`、`BundledCollections.swift` | 数据模型、档案 CRUD、原子保存与 10 份备份、文件同步、内置文章投放 |
| 文章导入与结构 | `ArticleDraft.swift`、`ArticleHeaderField.swift`、`ArticleImportView.swift`、`ArticleMarkdownDocument.swift`、`ArticleTextBlock.swift` | 格式识别、头字段解析、批量导入、Markdown 块与行内样式解析 |
| 阅读器与排版 | `ArticleReaderView.swift`、`ReaderDocumentStyling.swift`、`ReaderArticleByline.swift`、`ReaderSourceReveal.swift` | AppKit `NSTextView` 桥接、选区/查找/进度、署名渲染、原文定位 |
| 专注与分栏动效 | `ReaderFocusWindow.swift`、`ReaderSplitAnimationCoordinator.swift` | 原生分栏折叠/恢复、3 秒空闲显隐与安全区补偿 |
| 卡片与词形 | `CardEditorSheet.swift`、`MorphologyLookup.swift`、`SelectionContext.swift`、`ArticleRevision.swift`、`StudySentenceEmphasis.swift` | 卡片弹窗/草稿/AI 候选、SQLite 词形还原、句子提取、锚点重定位 |
| AI 路由与设置 | `AIService.swift`、`AICustomProfiles.swift`、`AISettingsView.swift`、`AICustomConfigurationDraft.swift`、`CustomAIConfigurationForm.swift`、`AIModelPicker.swift`、`AIExplanationRequest.swift`、`AIExplanationPopover.swift`、`AIUsageIssue.swift`、`AIServiceLogo.swift`、`AIServiceTestFeedback.swift` | 服务切换与修订号隔离、自定义 API 表单与模型菜单、解释弹出框 |
| ChatGPT 接入 | `ChatGPTAuth.swift`、`ChatGPTAccountStore.swift`、`ChatGPTClient.swift`、`ChatGPTConfigurationDraft.swift`、`ChatGPTConfigurationForm.swift`、`ChatGPTError.swift`、`ChatGPTAuthDiagnostics.swift` | OAuth PKCE（`127.0.0.1` loopback）、令牌刷新、Responses SSE 流、脱敏诊断 |
| Apple 智能 | `AppleIntelligenceService.swift`、`AppleIntelligenceConfigurationDraft.swift`、`AppleIntelligenceConfigurationForm.swift` | 端侧 `SystemLanguageModel` / `LanguageModelSession` 封装 |
| 精读模式 | `IntensiveReadingView.swift`、`IntensiveReadingModels.swift`、`IntensiveReadingControl.swift` | 每文章模型池、分批生成、原译文段映射与缓存渲染 |
| 通用控件与外观 | `NativeLibrarySearchField.swift`、`EditorSurface.swift`、`SheetViewport.swift`、`ChoiceCardButtonStyle.swift`、`AppearanceSettings.swift`、`AppIconColor.swift`、`SettingsWindowView.swift` | 搜索框与 `safeAreaBar` / `safeAreaInset` 控制栏、阅读风格、图标与设置窗 |

## 资料目录结构

默认根目录为 `~/Library/Application Support/ReadingToolDaily/`（可通过环境变量 `READINGTOOL_DAILY_DATA_DIR` 覆盖）：

```text
ReadingToolDaily/
├── profiles.json                  # 档案索引与当前档案 ID
├── Profiles/<profile UUID>/
│   ├── library.json               # ProfileArchive (version: 1)
│   ├── Articles/<article UUID>/<source filename>
│   ├── Backups/*.json             # 最近十份 library.json 自动备份
│   └── intensive-reading.json     # 每篇文章/语言的精读译文与对齐缓存
├── LocalCollections/              # 可选：本机私有文章集合（不入公开库）
└── CodeSigning/                   # 本地签名证书与专用 keychain
```

- **Unicode 偏移边界**：持久化的 `StudyCard.start/end` 与 `LibraryArticle.readOffset` 均使用 Unicode scalar 偏移；AppKit `NSTextView` / `NSRange` 使用 UTF-16 code unit，仅在明确边界转换。
- **内置资源**：`Resources/Language/lexicon.sqlite3` 以只读模式打开；`Resources/Licensed/` 包含 50 篇开放许可文章（5 篇 Global Voices、30 篇 Wikipedia、15 篇 PLOS）与离线精读数据 `intensive-reading.json`。

## 定向测试

```sh
zsh Scripts/test.sh 'ReadingLibraryStoreTests|ArticleFileSyncTests|BundledCollectionsTests'
```

或使用 `swift test` 运行全部测试。
