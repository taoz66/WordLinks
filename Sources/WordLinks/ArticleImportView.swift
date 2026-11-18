import AppKit
import SwiftUI

/// Present the drafts and their destination together, including on first open.
struct ArticleImportRequest: Identifiable {
    let id = UUID()
    let items: [ArticleImportItem]
    let folderID: UUID?
}

struct ArticleImportItem: Identifiable {
    let id = UUID()
    let name: String
    var draft: ArticleDraft?
    var loadError: String?
    var isIncluded = true
    var savedArticleID: UUID?
    var saveError: String?

    init(draft: ArticleDraft, name: String? = nil) {
        self.name = name ?? draft.fileName
        self.draft = draft
    }

    init(url: URL) {
        name = url.lastPathComponent
        do { draft = try ArticleDraft.read(from: url) }
        catch { loadError = error.localizedDescription; isIncluded = false }
    }
}

/// Preparation and results share one sheet, so a failed file never hides the
/// articles that succeeded, and every editable draft remains available.
struct ArticleImportSheet: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ArticleImportItem]
    @State private var selectedID: UUID?
    @State private var attemptedImport = false
    @State private var showsCompactBatchList = false
    let targetFolderID: UUID?
    let onAdded: ([UUID]) -> Void

    init(items: [ArticleImportItem], targetFolderID: UUID?, onAdded: @escaping ([UUID]) -> Void) {
        _items = State(initialValue: items)
        _selectedID = State(initialValue: items.first?.id)
        self.targetFolderID = targetFolderID
        self.onAdded = onAdded
    }

    private var selectedIndex: Int? { items.firstIndex { $0.id == selectedID } }
    private var pendingCount: Int {
        items.filter { $0.isIncluded && $0.savedArticleID == nil && $0.draft?.canSave == true }.count
    }
    private var successCount: Int { items.filter { $0.savedArticleID != nil }.count }
    private var failureCount: Int { items.filter { $0.loadError != nil || $0.saveError != nil }.count }
    private var skippedCount: Int { items.filter { !$0.isIncluded && $0.loadError == nil && $0.savedArticleID == nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("添加文章", "Add Articles")).font(.title2.weight(.semibold))
                    if items.count > 1 {
                        Text(L("逐篇检查、修改或取消勾选，然后一起加入阅读库。", "Review, edit or deselect articles before adding them to your library."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            Divider()
            GeometryReader { geometry in
                let compactBatch = items.count > 1 && geometry.size.width < 850
                HStack(spacing: 0) {
                    if items.count > 1 && !compactBatch {
                        batchList.frame(width: 215)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        if compactBatch {
                            compactBatchPicker
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            Divider()
                        }
                        selectedDraft
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                if attemptedImport || failureCount > 0 {
                    Text(L("成功 \(successCount) 篇 · 失败 \(failureCount) 篇 · 跳过 \(skippedCount) 篇",
                           "Added \(successCount) · Failed \(failureCount) · Skipped \(skippedCount)"))
                        .font(.callout).foregroundStyle(failureCount > 0 ? .secondary : .primary)
                        .lineLimit(2)
                }
                Spacer()
                Button(attemptedImport ? L("完成", "Done") : L("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if pendingCount > 0 || !attemptedImport {
                    Button(attemptedImport ? L("继续添加 \(pendingCount) 篇", "Add \(pendingCount) More")
                           : items.count > 1 ? L("加入阅读库（\(pendingCount)）", "Add to Library (\(pendingCount))")
                           : L("加入阅读库", "Add to Library"), action: addIncludedArticles)
                        .keyboardShortcut(.defaultAction)
                        .disabled(pendingCount == 0)
                }
            }
            .padding(16)
        }
        .sheetViewport(preferredSize: NSSize(width: items.count > 1 ? 1040 : 560,
                                           height: items.count > 1 ? 740 : 600),
                       minimumSize: NSSize(width: 520, height: 420))
    }

    private var compactBatchPicker: some View {
        Button { showsCompactBatchList.toggle() } label: {
            HStack(spacing: 8) {
                Label(L("文章（\(items.count)）", "Articles (\(items.count))"), systemImage: "doc.on.doc")
                if let index = selectedIndex {
                    Text(items[index].draft?.title.isEmpty == false
                         ? items[index].draft!.title : items[index].name)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
            }
        }
        .buttonStyle(.borderless)
        .help(L("选择要检查的文章", "Choose an article to review"))
        .popover(isPresented: $showsCompactBatchList) {
            batchList.frame(width: 340, height: 260)
                .padding(8)
        }
        .onChange(of: selectedID) { _, _ in showsCompactBatchList = false }
    }

    @ViewBuilder
    private var selectedDraft: some View {
        Group {
            if let index = selectedIndex, items[index].draft != nil {
                ArticleDraftEditor(draft: Binding(
                    get: { items[index].draft! },
                    set: { items[index].draft = $0; items[index].saveError = nil }
                ), isSaved: items[index].savedArticleID != nil, saveError: items[index].saveError)
                .id(items[index].id)
            } else if let index = selectedIndex {
                ContentUnavailableView {
                    Label(L("无法读取此文件", "Could Not Read This File"), systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text(items[index].loadError ?? L("请选择其他文章。", "Choose another article."))
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var batchList: some View {
        List(selection: $selectedID) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: $items[index].isIncluded)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(items[index].draft == nil || items[index].savedArticleID != nil)
                        .accessibilityLabel(L("加入 \(items[index].name)", "Include \(items[index].name)"))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(items[index].draft?.title.isEmpty == false ? items[index].draft!.title : items[index].name)
                            .font(.callout.weight(.medium)).lineLimit(3)
                        if items[index].savedArticleID != nil {
                            Label(L("已加入", "Added"), systemImage: "checkmark.circle.fill")
                        } else if items[index].loadError != nil || items[index].saveError != nil {
                            Label(L("需要处理", "Needs Attention"), systemImage: "exclamationmark.circle")
                        } else if !items[index].isIncluded {
                            Text(L("跳过", "Skipped"))
                        } else {
                            Text(items[index].name).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .tag(items[index].id)
            }
        }
        .listStyle(.inset)
        .accessibilityLabel(L("待导入文章", "Articles to Import"))
        .accessibilityIdentifier("articleImportBatchList")
    }

    private func addIncludedArticles() {
        attemptedImport = true
        var added: [UUID] = []
        for index in items.indices where items[index].isIncluded && items[index].savedArticleID == nil {
            guard let draft = items[index].draft else { continue }
            guard draft.canSave else {
                items[index].saveError = draft.validationMessage ?? L("请检查标题和正文。", "Check the title and text.")
                continue
            }
            do {
                let article = try store.addMarkdown(markdown: draft.markdown, sourceName: draft.fileName,
                    folderID: targetFolderID,
                    sourceFilePath: draft.keepsSourceLinked ? draft.sourceFileURL?.standardizedFileURL.path : nil)
                items[index].savedArticleID = article.id
                items[index].saveError = nil
                added.append(article.id)
            } catch { items[index].saveError = error.localizedDescription }
        }
        if !added.isEmpty { onAdded(added) }
        if items.count == 1, successCount == 1 { dismiss() }
    }

}

private struct ArticleDraftEditor: View {
    @Binding var draft: ArticleDraft
    let isSaved: Bool
    let saveError: String?
    @State private var showsDetails = false
    @State private var linkError: String?
    @State private var independentDraft: ArticleDraft?
    @State private var fieldsHeight: CGFloat = 80
    private var isLinked: Bool { draft.keepsSourceLinked && draft.sourceFileURL != nil }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 460
            let inset: CGFloat = compact ? 12 : 20
            let spacing: CGFloat = compact ? 8 : 12
            let minimumEditorHeight = min(220, max(48, geometry.size.height * 0.22))
            // Reserve the body label, spacing and a useful text viewport.
            // Optional fields can then expand naturally before they need to scroll.
            let fieldsBudget = max(48, geometry.size.height - inset * 2
                                   - 20 - spacing * 2 - minimumEditorHeight
                                   - (isSaved ? 28 + spacing : 0))
            VStack(alignment: .leading, spacing: spacing) {
                if isSaved {
                    Label(L("已加入阅读库", "Added to Library"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                scrollingFields(maximumHeight: fieldsBudget)
                Text(L("正文", "Article Text")).font(.callout.weight(.medium))
                NativeCardTextEditor(text: $draft.body, placeholder: L("输入正文", "Enter text"),
                                     label: L("文章正文", "Article Text"), minimumHeight: minimumEditorHeight,
                                     maximumHeight: .greatestFiniteMagnitude, isEditable: !isLinked && !isSaved,
                                     fillsAvailableHeight: true, textInset: EditorSurface.textInset,
                                     accessibilityIdentifier: "articleDraftBody")
                    .frame(minHeight: minimumEditorHeight, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            .padding(inset)
        }
        .onChange(of: draft.keepsSourceLinked) { _, isLinked in
            guard isLinked else {
                if var edited = independentDraft {
                    edited.keepsSourceLinked = false
                    independentDraft = nil
                    draft = edited
                }
                return
            }
            guard let url = draft.sourceFileURL else { return }
            var edited = draft
            edited.keepsSourceLinked = false
            independentDraft = edited
            do {
                var original = try ArticleDraft.read(from: url)
                original.keepsSourceLinked = true
                draft = original
                linkError = nil
            } catch {
                draft.keepsSourceLinked = false
                linkError = error.localizedDescription
            }
        }
    }

    private func scrollingFields(maximumHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("articleImportSaveError")
                }
                metadataFields.disabled(isLinked || isSaved)
                supportingInformation
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Native focus rings extend outside a text field's layout bounds.
            .padding(8)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ArticleDraftFieldsHeight.self, value: geometry.size.height)
                }
            }
        }
        .modifier(ArticleDraftFieldsScrollEdges())
        .frame(height: min(maximumHeight, max(1, fieldsHeight)))
        .padding(.horizontal, -8)
        .onPreferenceChange(ArticleDraftFieldsHeight.self) { fieldsHeight = $0 }
    }

    @ViewBuilder
    private var supportingInformation: some View {
        if !draft.notices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(draft.notices.enumerated()), id: \.offset) { _, notice in
                    Label(notice, systemImage: "info.circle")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        if let issue = draft.validationMessage, !draft.title.isEmpty || !draft.body.isEmpty {
            Label(issue, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
        }
        if let linkError {
            Label(linkError, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
        }
        if let url = draft.sourceFileURL {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L("与原文件同步", "Keep in Sync with Original File"), isOn: $draft.keepsSourceLinked)
                    .disabled(isSaved)
                Text(isLinked
                     ? L("阅读库会跟随原文件更新。请在原文件中编辑正文和文章信息。", "The library follows changes to the original file. Edit the text and details in that file.")
                     : L("保存独立副本。开启同步会改用原文件内容；关闭同步可返回当前编辑。", "Saves a separate copy. Sync uses the original file; turn it off to return to your edits."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("文章标题", "Article Title"), text: $draft.title)
                .textFieldStyle(.roundedBorder).font(.title3)
                .accessibilityIdentifier("articleDraftTitle")
            DisclosureGroup(L("补充信息（选填）", "Article Details (Optional)"), isExpanded: $showsDetails) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text(L("作者", "Author")).foregroundStyle(.secondary)
                        TextField(L("作者姓名", "Author Name"), text: $draft.author)
                            .accessibilityIdentifier("articleDraftAuthor")
                    }
                    GridRow {
                        Text(L("日期", "Date")).foregroundStyle(.secondary)
                        TextField(L("例如 2026-11-11", "e.g. 2026-11-11"), text: $draft.date)
                            .accessibilityIdentifier("articleDraftDate")
                    }
                    GridRow {
                        Text(L("来源", "Source")).foregroundStyle(.secondary)
                        TextField(L("媒体或书籍名称", "Publication or Book"), text: $draft.source)
                            .accessibilityIdentifier("articleDraftSource")
                    }
                    GridRow {
                        Text(L("原文链接", "Original URL")).foregroundStyle(.secondary)
                        TextField("https://…", text: $draft.sourceURL)
                            .accessibilityIdentifier("articleDraftSourceURL")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 8)
                // DisclosureGroup clips its revealed content separately from
                // the scroll view. Keep native bezels and focus rings inside it.
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
            .padding(.trailing, -8)
        }
    }

}

private struct ArticleDraftFieldsScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // These are editable form controls; a scroll-edge fade must not erase
            // their borders or focus indication.
            content.scrollEdgeEffectHidden()
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ArticleDraftFieldsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ArticleTemplatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("模板", "Template")).font(.title2.weight(.semibold))
            ScrollView {
                Text(ArticleTemplate.markdown).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .editorSurface()
            Text(L("阅读器支持部分Markdown语法", "The reader supports some Markdown syntax"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if didCopy {
                    Label(L("已复制", "Copied"), systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("templateCopyConfirmation")
                }
                Spacer()
                Button(L("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("复制", "Copy")) {
                    NSPasteboard.general.clearContents()
                    didCopy = NSPasteboard.general.setString(ArticleTemplate.markdown, forType: .string)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .sheetViewport(preferredSize: NSSize(width: 620, height: 460),
                       minimumSize: NSSize(width: 420, height: 340))
    }

}
