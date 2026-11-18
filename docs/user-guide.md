# WordLinks User Guide

WordLinks (词文库) is a native macOS English reading library and contextual vocabulary builder. You can read bundled or imported articles continuously, save contextual word cards with their original sentences, and use offline or AI-powered sentence-by-sentence intensive reading.

## Core Concepts

| Term | Description |
| --- | --- |
| **Profile** | An isolated workspace containing its own articles, folders, reading positions, and saved vocabulary cards (independent of AI service settings). |
| **Folder** | Single-level organization within a profile. Deleting a folder moves its articles back to the root library without deleting them. |
| **Expression** | The normalized English word or phrase saved on a vocabulary card (which may be a base form rather than the exact inflected selection). |
| **Card** | A saved vocabulary record anchored to an article position, storing the expression, definition, original selection, and full source sentence. |
| **Entry** | A group of cards sharing the same normalized expression (case-insensitive, collapsed whitespace). |
| **Intensive Mode** | Sentence-by-sentence bilingual alignment with interactive hover highlighting between English words and Chinese phrases. |
| **Focus Mode** | Distraction-free reading mode (`⇧⌘F`) that collapses library sidebars and auto-hides window chrome when idle. |

## Library, Importing & Sync

- **Adding Articles**: Click the `+` menu next to the search field to create a new article, import `.md` / `.markdown` / `.txt` files (UTF-8 or UTF-16), or view the built-in Markdown template.
- **File Synchronization**: Imported articles are stored as managed copies by default. Enabling file sync links an external file as the source of truth so edits made in external editors automatically update the article while preserving valid highlights.
- **Data Safety & Backups**: All profile writes are atomic and retain the last 10 automatic backups under `~/Library/Application Support/ReadingToolDaily/`. Profiles can be exported and imported as JSON archives.

## Reading & Focus Mode

- **Reading Themes**: Choose between **Standard**, **Book**, **Focus**, and **Magazine** in **Settings → Appearance**. Each theme remembers its own font size, line spacing, paragraph spacing, and side margins.
- **In-Page Search & System Lookup**: Press `⌘F` to search within an article (`⌘G` / `⇧⌘G` to navigate matches, `Esc` to close). Select any text to use macOS Look Up or Translate.
- **Focus Mode (`⇧⌘F`)**: Collapses the sidebar and article list and hides toolbar controls after ~3 seconds of inactivity. Moving the mouse or pressing a key brings controls back smoothly.

## Vocabulary Cards & Export

- **Saving Cards**: Highlight any word or phrase in an article to open the card editor near your selection. For lowercase inflected English words in the bundled lexicon (e.g., `books → book`, `arriving → arrive`), the base form is prefilled automatically without overwriting manual edits.
- **Reviewing & Inline Editing**: Browse cards grouped by **Vocabulary** or **By Article**. Click **View in Article** to jump directly to the original passage. Double-click a definition or expression to edit inline with full `⌘Z` Undo/Redo support.
- **CSV Export (`⌘E`)**: Export the entire vocabulary library, the current entry, or cards from a specific article as a UTF-8 (with BOM) 6-column CSV file compatible with Excel and flashcard tools.

## AI Services & Intensive Reading

Configure AI providers in **Settings → AI**:

- **ChatGPT**: Sign in via OpenAI's official OAuth flow using an eligible ChatGPT subscription.
- **Custom API**: Connect any OpenAI-compatible Chat Completions endpoint (remote providers or local runners such as Ollama, LM Studio, or vLLM). Leave the API key blank for unauthenticated local endpoints.
- **Apple Intelligence**: Uses macOS 26+ on-device `FoundationModels` with zero network traffic.

All API keys and tokens are stored in the macOS Keychain.

### Built-in Offline Intensive Reading

WordLinks bundles 50 open-licensed articles (Global Voices, Wikipedia, and PLOS), including 33 core articles with pre-generated, verified bilingual intensive reading data (`intensive-reading.json`) that work completely offline out of the box. Right-click or Control-click the Intensive Reading toolbar button to regenerate an article using your active AI provider.
