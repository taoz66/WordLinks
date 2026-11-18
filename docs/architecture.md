# WordLinks Architecture & Development Guide

This document describes the codebase layout, data model boundaries, build scripts, and test suites for WordLinks.

## Tech Stack & Build Scripts

- **Package & Language**: SwiftPM (`Package.swift`), Swift tools 6.0 / Swift 5 language mode, minimum target macOS 14.0. UI is built with SwiftUI + AppKit (`NSTextView`, `NSSplitView`), Markdown parsing uses `swift-markdown` 0.5.0 (pinned in `Package.resolved`), and the bundled English lexicon is queried read-only via `CSQLite`.
- **App Entry**: [WordLinksApp.swift](../Sources/WordLinks/WordLinksApp.swift) initializes `ReadingLibraryStore`, `AISettingsStore`, language, and appearance stores before injecting the main library window and settings window. If local library data fails to open, an explicit error view is presented without overwriting existing files.
- **Packaging & Signing**:
  - `Scripts/build-app.sh`: Builds a release binary with Xcode 26+ SDK (required for `FoundationModels` / Apple Intelligence and native layered icon compilation), assembles `build/Wordlinks.app`, installs resources and icons, and signs the bundle.
  - `Scripts/sign-app.sh`: Signs the bundle using a stable local code-signing identity in `~/Library/Application Support/ReadingToolDaily/CodeSigning/` and verifies with `codesign --verify --strict`.
- **Testing**: `swift test` or `Scripts/test.sh '<Filter>'`.

## Source Layout

All application source files live under `Sources/WordLinks/`:

| Area | Files | Responsibility |
| --- | --- | --- |
| App Entry & Localization | `WordLinksApp.swift`, `Localization.swift` | Scene setup, environment injection, `L(中文, English)` helper |
| Library Window | `LibraryWindow.swift` | Split-view layout, profile/folder management, study routing, import/export triggers |
| Toolbar & Split Geometry | `LibrarySidebarCommands.swift`, `ReaderDisplayCommands.swift` | Sidebar/display menu commands, detail toolbar title width synchronization |
| Inline Study Editing | `InlineStudyEditing.swift` | Per-window edit coordinator, native text editor, error recovery, system Undo/Redo |
| CSV Export | `StudyLibraryExport.swift`, `StudyLibraryCommands.swift` | Consistent snapshot capture, UTF-8 BOM CSV encoding, `NSSavePanel` delegate, `⌘E` |
| Data Persistence | `ReadingLibraryStore.swift`, `BundledCollections.swift` | Models, profile CRUD, atomic writes, 10-backup rotation, file sync, bundled articles |
| Import & Markdown | `ArticleDraft.swift`, `ArticleHeaderField.swift`, `ArticleImportView.swift`, `ArticleMarkdownDocument.swift`, `ArticleTextBlock.swift` | Format detection, metadata header parsing, batch import, Markdown block/inline styling |
| Reader & Typography | `ArticleReaderView.swift`, `ReaderDocumentStyling.swift`, `ReaderArticleByline.swift`, `ReaderSourceReveal.swift` | AppKit `NSTextView` bridge, selection/search/progress, byline rendering, source reveal |
| Focus & Split Animation | `ReaderFocusWindow.swift`, `ReaderSplitAnimationCoordinator.swift` | Native split collapse/expand, 3s idle chrome auto-hide, safe-area compensation |
| Cards & Morphology | `CardEditorSheet.swift`, `MorphologyLookup.swift`, `SelectionContext.swift`, `ArticleRevision.swift`, `StudySentenceEmphasis.swift` | Card popover/drafts/AI suggestions, SQLite lemmatization, sentence extraction, anchor relocation |
| AI Routing & Settings | `AIService.swift`, `AICustomProfiles.swift`, `AISettingsView.swift`, `AICustomConfigurationDraft.swift`, `CustomAIConfigurationForm.swift`, `AIModelPicker.swift`, `AIExplanationRequest.swift`, `AIExplanationPopover.swift`, `AIUsageIssue.swift`, `AIServiceLogo.swift`, `AIServiceTestFeedback.swift` | Provider switching with revision isolation, custom API form, model menu, Ask AI popover |
| ChatGPT OAuth | `ChatGPTAuth.swift`, `ChatGPTAccountStore.swift`, `ChatGPTClient.swift`, `ChatGPTConfigurationDraft.swift`, `ChatGPTConfigurationForm.swift`, `ChatGPTError.swift`, `ChatGPTAuthDiagnostics.swift` | OAuth PKCE (`127.0.0.1` loopback), token refresh, Responses SSE streaming, redacted diagnostics |
| Apple Intelligence | `AppleIntelligenceService.swift`, `AppleIntelligenceConfigurationDraft.swift`, `AppleIntelligenceConfigurationForm.swift` | On-device `SystemLanguageModel` / `LanguageModelSession` wrapper |
| Intensive Reading | `IntensiveReadingView.swift`, `IntensiveReadingModels.swift`, `IntensiveReadingControl.swift` | Per-article model pool, batched generation, source/translation segment mapping |
| Shared Controls & Appearance | `NativeLibrarySearchField.swift`, `EditorSurface.swift`, `SheetViewport.swift`, `ChoiceCardButtonStyle.swift`, `AppearanceSettings.swift`, `AppIconColor.swift`, `SettingsWindowView.swift` | Search bar, `safeAreaBar` / `safeAreaInset` control bars, reading styles, app icon variants |

## Data Directory Structure

The default root directory is `~/Library/Application Support/ReadingToolDaily/` (overridable via `READINGTOOL_DAILY_DATA_DIR`):

```text
ReadingToolDaily/
├── profiles.json                  # Profile index & active profile ID
├── Profiles/<profile UUID>/
│   ├── library.json               # ProfileArchive (version: 1)
│   ├── Articles/<article UUID>/<source filename>
│   ├── Backups/*.json             # Last 10 automatic library.json backups
│   └── intensive-reading.json     # Cached per-article/language intensive translations
├── LocalCollections/              # Optional private local collections (not tracked in git)
└── CodeSigning/                   # Local code-signing certificate & dedicated keychain
```

- **Unicode Offset Boundary**: Persisted `StudyCard.start/end` and `LibraryArticle.readOffset` store Unicode scalar offsets. AppKit `NSTextView` / `NSRange` uses UTF-16 code units; conversions happen strictly at the AppKit boundary.
- **Bundled Resources**: `Resources/Language/lexicon.sqlite3` is opened read-only. `Resources/Licensed/` contains 50 open-licensed articles (5 Global Voices, 30 Wikipedia, 15 PLOS) and `intensive-reading.json` for instant offline intensive reading.

## Running Targeted Tests

```sh
zsh Scripts/test.sh 'ReadingLibraryStoreTests|ArticleFileSyncTests|BundledCollectionsTests'
```

Or run the full suite with `swift test`.
