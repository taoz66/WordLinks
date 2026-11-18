import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryRoute: Hashable {
    case library
    case folder(UUID)
    case vocabulary
    case byArticle
}

struct LibraryWindow: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var route: LibraryRoute? = .library
    @State private var selectedArticleID: UUID?
    @State private var articleOffsetOverride: (articleID: UUID, offset: Int)?
    @State private var articleSourceReveal: ReaderSourceReveal?
    @State private var selectedStudyArticleID: UUID?
    @State private var selectedEntryKey: String?
    @AppStorage("study.showsMeanings") private var showsMeanings = true
    @AppStorage("study.showsExamples") private var showsExamples = true
    @State private var newProfileName = ""
    @State private var newFolderName = ""
    @State private var isCreatingProfile = false
    @State private var isCreatingFolder = false
    @State private var isRenamingProfile = false
    @State private var renamedProfileName = ""
    @State private var renamingFolder: LibraryFolder?
    @State private var renamedFolderName = ""
    @State private var isConfirmingDeleteProfile = false
    @State private var restoringBackupURL: URL?
    @State private var errorMessage: String?
    @State private var articleImportRequest: ArticleImportRequest?
    @State private var isShowingArticleTemplates = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDistractionFree = false
    @State private var isExpandingSidebar = false
    @State private var sidebarExpandResetWork: DispatchWorkItem?
    @State private var toolbarGeometry = LibraryToolbarGeometry()
    @State private var detailToolbarGeometry = LibraryToolbarGeometry()
    @StateObject private var intensiveModels = IntensiveReadingModelPool()
    @StateObject private var studyEditing = StudyInlineEditCoordinator()
    @StateObject private var studyExporter = StudyLibraryExporter()
    @StateObject private var studyWindow = StudyLibraryWindowContext()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .toolbar(removing: .sidebarToggle)
        } content: {
            contentColumn
                .toolbar(removing: .sidebarToggle)
                .background {
                    LibraryToolbarColumnReader(geometry: toolbarGeometry, isDistractionFree: isDistractionFree)
                }
        } detail: {
            detailColumn
                .toolbar(removing: .sidebarToggle)
                .background {
                    LibraryToolbarColumnReader(geometry: detailToolbarGeometry, isDistractionFree: isDistractionFree)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(studyEditing)
        .focusedSceneValue(\.studyLibraryExport, studyExportCommandState)
        .background {
            StudyLibraryWindowReader(context: studyWindow)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isStudyRoute && hasStudyFeedback {
                studyFeedback.background(.bar)
            }
        }
        // Keep minWidth at 980pt at rest so the toolbar never overflows, while relaxing
        // the SwiftUI split floor only during an animated sidebar expand so AppKit
        // doesn't snap detail width at completion when winWidth < 980 + sidebar.
        .frame(minWidth: (isDistractionFree || isExpandingSidebar) ? 420 : 980, minHeight: 640)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if !isDistractionFree { sidebarToolbar }
            if !isDistractionFree, let title = detailToolbarTitle {
                detailTitleToolbar(title: title)
            }
            toolbar
        }
        .focusedSceneValue(\.librarySidebar, sidebarCommandState)
        .focusedSceneValue(\.readerDisplay, readerDisplayCommandState)
        .background {
            ReaderFocusWindow(isActive: isDistractionFree,
                              backgroundColor: AppearanceSettingsStore.shared.readingStyle.readerBackground,
                              onToggle: toggleDistractionFree,
                              onRegenerateIntensiveReading: {
                                  readingIntensiveModel?.regenerate()
                              })
        }
        .alert(L("词文库", "Wordlinks"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L("好", "OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L("新建档案", "New Profile"), isPresented: $isCreatingProfile) {
            TextField(L("档案名称", "Profile Name"), text: $newProfileName)
            Button(L("取消", "Cancel"), role: .cancel) { newProfileName = "" }
            Button(L("创建", "Create")) { createProfile() }
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L("重命名档案", "Rename Profile"), isPresented: $isRenamingProfile) {
            TextField(L("档案名称", "Profile Name"), text: $renamedProfileName)
            Button(L("取消", "Cancel"), role: .cancel) { renamedProfileName = "" }
            Button(L("保存", "Save")) { commitRenameActiveProfile() }
                .disabled(renamedProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L("新建文件夹", "New Folder"), isPresented: $isCreatingFolder) {
            TextField(L("文件夹名称", "Folder Name"), text: $newFolderName)
            Button(L("取消", "Cancel"), role: .cancel) { newFolderName = "" }
            Button(L("创建", "Create")) { createFolder() }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L("重命名文件夹", "Rename Folder"), isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil; renamedFolderName = "" } }
        )) {
            TextField(L("文件夹名称", "Folder Name"), text: $renamedFolderName)
            Button(L("取消", "Cancel"), role: .cancel) {
                renamingFolder = nil
                renamedFolderName = ""
            }
            Button(L("保存", "Save")) { commitRenameFolder() }
                .disabled(renamedFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L("删除档案“\(store.archive.name)”及其中全部文章和积累？",
                 "Delete profile “\(store.archive.name)” and all its articles and cards?"),
               isPresented: $isConfirmingDeleteProfile) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("删除档案", "Delete Profile"), role: .destructive) {
                perform { try store.deleteProfile(store.archive.id) }
            }
        } message: {
            Text(L("此操作无法撤销。已导出的资料文件不受影响。",
                   "This cannot be undone. Exported data files will be kept."))
        }
        .alert(L("使用此自动备份替换当前档案内容？",
                 "Replace the current profile contents with this automatic backup?"),
               isPresented: Binding(
                get: { restoringBackupURL != nil },
                set: { if !$0 { restoringBackupURL = nil } }
               )) {
            Button(L("取消", "Cancel"), role: .cancel) { restoringBackupURL = nil }
            Button(L("恢复备份", "Restore Backup")) {
                if let url = restoringBackupURL {
                    restoringBackupURL = nil
                    perform { try store.restoreAutomaticBackup(from: url) }
                }
            }
        } message: {
            Text(L("当前内容会先保存为一份新的自动备份。",
                   "The current contents will first be saved as a new automatic backup."))
        }
        .sheet(item: $articleImportRequest) { request in
            ArticleImportSheet(items: request.items, targetFolderID: request.folderID) { ids in
                guard let last = ids.last else { return }
                selectedArticleID = last
                route = request.folderID.map(LibraryRoute.folder) ?? .library
            }
            .id(request.id)
            .environmentObject(store)
        }
        .sheet(isPresented: $isShowingArticleTemplates) {
            ArticleTemplatesSheet()
        }
        .onChange(of: store.archive.id) { _, _ in
            exitDistractionFree()
            intensiveModels.synchronizeScope(profileID: store.archive.id,
                                             targetLanguage: aiSettings.studyLanguage)
            selectedArticleID = store.archive.lastArticleID
            selectedStudyArticleID = nil
            selectedEntryKey = nil
            articleOffsetOverride = nil
            articleSourceReveal = nil
        }
        .onChange(of: selectedArticleID) { _, articleID in
            if articleID == nil { exitDistractionFree() }
            if articleOffsetOverride?.articleID != articleID { articleOffsetOverride = nil }
            if articleSourceReveal?.articleID != articleID { articleSourceReveal = nil }
        }
        .onChange(of: aiSettings.studyLanguage) { _, _ in
            intensiveModels.synchronizeScope(profileID: store.archive.id,
                                             targetLanguage: aiSettings.studyLanguage)
        }
        .onChange(of: route) { _, _ in
            if readingArticle == nil {
                exitDistractionFree()
            }
        }
        .onAppear {
            if selectedArticleID == nil { selectedArticleID = store.archive.lastArticleID }
        }
    }

    private var readingArticle: LibraryArticle? {
        switch route ?? .library {
        case .library, .folder:
            return store.archive.articles.first { $0.id == selectedArticleID }
        case .vocabulary, .byArticle:
            return nil
        }
    }

    private var isStudyRoute: Bool { route == .vocabulary || route == .byArticle }

    private var studyExportCommandState: StudyLibraryExportCommandState? {
        isStudyRoute ? StudyLibraryExportCommandState(
            isEnabled: studyExporter.canExport(store: store),
            exportLibrary: { exportStudyCards(.library) }) : nil
    }

    private var readerDisplayCommandState: ReaderDisplayCommandState {
        ReaderDisplayCommandState(
            isFocusAvailable: isDistractionFree || readingArticle != nil,
            isFocused: isDistractionFree,
            onToggleFocus: toggleDistractionFree,
            intensiveModel: readingIntensiveModel,
            isStudyDisplayAvailable: isStudyRoute,
            showsMeanings: showsMeanings,
            showsExamples: showsExamples,
            onSetShowsMeanings: { value in withAnimation(studyDisplayAnimation) { showsMeanings = value } },
            onSetShowsExamples: { value in withAnimation(studyDisplayAnimation) { showsExamples = value } })
    }

    private var sidebarCommandState: LibrarySidebarCommandState {
        LibrarySidebarCommandState(isVisible: areLibraryColumnsVisible, onToggle: toggleLibrarySidebar)
    }

    /// Detail availability is independent of search and display options.
    private var currentStudyExportScope: StudyExportScope? {
        if route == .vocabulary, let key = selectedEntryKey,
           store.entries.contains(where: { $0.key == key }) { return .entry(key) }
        if route == .byArticle, let id = selectedStudyArticleID,
           store.archive.articles.contains(where: { $0.id == id }),
           store.cards.contains(where: { $0.articleID == id }) { return .article(id) }
        return nil
    }

    private func exportStudyCards(_ scope: StudyExportScope) {
        guard isStudyRoute else { return }
        studyExporter.export(scope: scope, store: store, window: studyWindow.window,
                             language: AppLanguageStore.shared.language,
                             finishEditing: studyEditing.finishEditing)
    }

    private var hasStudyFeedback: Bool {
        studyEditing.errorMessage != nil || studyExporter.errorMessage != nil || studyExporter.successMessage != nil
    }

    @ViewBuilder
    private var studyFeedback: some View {
        if let message = studyEditing.errorMessage {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).frame(maxWidth: .infinity, alignment: .leading)
                Button(L("重试", "Retry")) { studyEditing.retry() }
                if studyEditing.hasActiveEdit {
                    Button(L("放弃草稿", "Discard Draft")) { studyEditing.cancelEditing() }
                } else if studyEditing.canDismissError {
                    Button(L("关闭", "Dismiss")) { studyEditing.dismissError() }
                }
            }
            .padding(12)
        } else if let message = studyExporter.errorMessage {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).frame(maxWidth: .infinity, alignment: .leading)
                Button(studyExporter.retryUsesSavedSnapshot ? L("重试本次导出", "Retry This Export")
                                                           : L("重试", "Retry")) { studyExporter.retry() }
                    .disabled(!studyExporter.canRetry)
                Button(L("关闭", "Dismiss")) { studyExporter.dismissError() }
            }
            .padding(12)
        } else if let message = studyExporter.successMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                Text(message)
                Spacer(minLength: 0)
            }
            .padding(12)
            .accessibilityElement(children: .combine)
        }
    }

    private var readingIntensiveModel: IntensiveReadingModel? {
        guard let article = readingArticle else { return nil }
        return intensiveModels.model(for: article, profileID: store.archive.id,
                                     store: store, settings: aiSettings)
    }

    private var areLibraryColumnsVisible: Bool {
        !isDistractionFree && columnVisibility != .doubleColumn && columnVisibility != .detailOnly
    }

    private var sidebarAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    private var studyDisplayAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }

    private func updateFocusState(_ changes: () -> Void) {
        // AppKit owns the split animation. Keep SwiftUI's toolbar and
        // visibility bookkeeping out of that animation transaction.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    private func prepareSplitExpansionWindowFloorIfNeeded() {
        guard !reduceMotion,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = toolbarGeometry.hostWindow else { return }
        sidebarExpandResetWork?.cancel()
        isExpandingSidebar = true
        window.contentMinSize.width = 420
        window.minSize.width = 420
        let work = DispatchWorkItem {
            isExpandingSidebar = false
        }
        sidebarExpandResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func toggleLibrarySidebar() {
        if isDistractionFree {
            prepareSplitExpansionWindowFloorIfNeeded()
            updateFocusState {
                isDistractionFree = false
                columnVisibility = .all
            }
            return
        }
        if toolbarGeometry.isSidebarCollapsed,
           !reduceMotion,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           toolbarGeometry.hostWindow != nil {
            prepareSplitExpansionWindowFloorIfNeeded()
            DispatchQueue.main.async {
                if !toolbarGeometry.toggleSidebar() {
                    withAnimation(sidebarAnimation) {
                        columnVisibility = .all
                    }
                }
            }
            return
        }
        if toolbarGeometry.toggleSidebar() {
            return
        }
        withAnimation(sidebarAnimation) {
            columnVisibility = areLibraryColumnsVisible ? .doubleColumn : .all
        }
    }

    private func toggleDistractionFree() {
        if isDistractionFree {
            exitDistractionFree()
        } else if readingArticle != nil {
            updateFocusState {
                isDistractionFree = true
            }
        }
    }

    private func exitDistractionFree() {
        guard isDistractionFree else { return }
        prepareSplitExpansionWindowFloorIfNeeded()
        updateFocusState {
            isDistractionFree = false
        }
    }

    private var sidebar: some View {
        List(selection: $route) {
            Section(L("阅读库", "Library")) {
                Label(L("全部文章", "All Articles"), systemImage: "books.vertical")
                    .tag(LibraryRoute.library)
                ForEach(store.archive.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(folder.name)
                        .tag(LibraryRoute.folder(folder.id))
                        .contextMenu {
                            Button(L("重命名…", "Rename…")) { renameFolder(folder) }
                            Button(L("删除文件夹", "Delete Folder"), role: .destructive) {
                                perform { try store.deleteFolder(folder.id) }
                            }
                        }
                }
                Button { isCreatingFolder = true } label: {
                    Label(L("新建文件夹…", "New Folder…"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .help(L("新建文章文件夹", "Create Article Folder"))
            }
            Section(L("积累", "Study")) {
                Label(L("词条", "Words"), systemImage: "list.dash.header.rectangle")
                    .tag(LibraryRoute.vocabulary)
                Label(L("文章", "Articles"), systemImage: "doc.text")
                    .tag(LibraryRoute.byArticle)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let backups = store.automaticBackups()
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.profiles) { profile in
                        Button {
                            perform { try store.selectProfile(profile.id) }
                        } label: {
                            if profile.id == store.archive.id {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                    Divider()
                    Button(L("新建档案…", "New Profile…")) { isCreatingProfile = true }
                    Button(L("重命名当前档案…", "Rename Current Profile…")) { renameActiveProfile() }
                    Button(L("导入档案…", "Import Profile…"), action: importProfile)
                    Button(L("导出当前档案…", "Export Current Profile…"), action: exportProfile)
                    if !backups.isEmpty {
                        Menu(L("恢复自动备份", "Restore Automatic Backup")) {
                            ForEach(backups, id: \.path) { url in
                                Button(backupTitle(url)) { confirmRestoreBackup(url) }
                            }
                        }
                    }
                    if store.profiles.count > 1 {
                        Divider()
                        Button(L("删除当前档案", "Delete Current Profile"), role: .destructive) {
                            confirmDeleteProfile()
                        }
                    }
                } label: {
                    Label(store.archive.name, systemImage: "person.crop.circle")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("library.profile")
                .accessibilityLabel(L("个人档案：\(store.archive.name)", "Profile: \(store.archive.name)"))
                .help(L("切换或管理个人档案", "Switch or manage profiles"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch route ?? .library {
        case .library:
            ArticleListColumn(title: L("全部文章", "All Articles"), folderID: nil,
                              selectedArticleID: $selectedArticleID, window: studyWindow.window,
                              onImport: importArticles, onCreate: createArticle,
                              onTemplates: { isShowingArticleTemplates = true },
                              onError: { errorMessage = $0.localizedDescription })
        case .folder(let id):
            ArticleListColumn(title: store.archive.folders.first(where: { $0.id == id })?.name ?? L("文件夹", "Folder"),
                              folderID: id, selectedArticleID: $selectedArticleID, window: studyWindow.window,
                              onImport: importArticles, onCreate: createArticle,
                              onTemplates: { isShowingArticleTemplates = true },
                              onError: { errorMessage = $0.localizedDescription })
        case .vocabulary:
            VocabularyListColumn(selectedEntryKey: $selectedEntryKey, showsMeanings: showsMeanings)
        case .byArticle:
            ArticleStudyListColumn(selectedArticleID: $selectedStudyArticleID)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch route ?? .library {
        case .library, .folder:
            if let article = store.archive.articles.first(where: { $0.id == selectedArticleID }) {
                let profileID = store.archive.id
                let intensiveModel = intensiveModels.model(for: article, profileID: profileID,
                                                           store: store, settings: aiSettings)
                ArticleReaderView(article: article, store: store, aiSettings: aiSettings,
                                  initialOffset: readingOffset(for: article),
                                  sourceReveal: articleSourceReveal,
                                  isDistractionFree: isDistractionFree,
                                  onExitDistractionFree: exitDistractionFree,
                                  intensiveModel: intensiveModel)
                    .id("\(profileID)-\(article.id)-\(article.text.hashValue)-\(aiSettings.studyLanguage.rawValue)")
            } else {
                ContentUnavailableView(L("选择一篇文章", "Select an Article"), systemImage: "doc.text")
                    .navigationTitle("")
            }
        case .vocabulary:
            if let key = selectedEntryKey {
                VocabularyEntryDetail(entryKey: key, showsMeanings: showsMeanings,
                                      showsExamples: showsExamples, openSource: openStudySource)
                    .id(key)
            } else {
                ContentUnavailableView(L("选择一个词条", "Select an Entry"), systemImage: "text.book.closed")
                    .navigationTitle("")
            }
        case .byArticle:
            if let article = store.archive.articles.first(where: { $0.id == selectedStudyArticleID }),
               store.archive.cards.contains(where: { $0.articleID == article.id }) {
                ArticleStudyDetail(article: article, showsMeanings: showsMeanings,
                                   showsExamples: showsExamples, openEntry: openStudyEntry,
                                   openSource: openStudySource)
            } else {
                ContentUnavailableView(L("选择一篇文章", "Select an Article"), systemImage: "doc.text")
                    .navigationTitle("")
            }
        }
    }

    private func openStudyEntry(_ card: StudyCard) {
        selectedEntryKey = normalizedExpression(card.expression)
        route = .vocabulary
    }

    private func openStudySource(_ card: StudyCard) {
        guard let article = store.archive.articles.first(where: { $0.id == card.articleID }) else { return }
        selectedArticleID = article.id
        articleOffsetOverride = (article.id, card.isDetached == true ? 0 : card.start)
        articleSourceReveal = ReaderSourceReveal(card: card)
        route = article.folderID.map(LibraryRoute.folder) ?? .library
    }

    private func readingOffset(for article: LibraryArticle) -> Int {
        guard let jump = articleOffsetOverride, jump.articleID == article.id else { return article.readOffset }
        return jump.offset
    }

    @ToolbarContentBuilder
    private func detailTitleToolbar(title: String) -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            detailTitleToolbarItem(title: title).sharedBackgroundVisibility(.hidden)
        } else {
            detailTitleToolbarItem(title: title)
        }
        #else
        detailTitleToolbarItem(title: title)
        #endif
    }

    private func detailTitleToolbarItem(title: String) -> some ToolbarContent {
        ToolbarItem(id: "library.detailTitle", placement: .principal) {
            LibraryColumnToolbarTitle(title: title, geometry: detailToolbarGeometry, fillsColumnWidth: true)
                .frame(minWidth: 1, maxWidth: .infinity, alignment: .leading)
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(id: "library.sidebar", placement: .navigation) {
            Button(action: toggleLibrarySidebar) {
                Label {
                    Text(L("阅读库边栏", "Library Sidebar"))
                } icon: {
                    ReaderToolbarIcon(systemName: "sidebar.left")
                }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(L("阅读库边栏", "Library Sidebar"))
            .accessibilityValue(areLibraryColumnsVisible ? L("已显示", "Shown") : L("已隐藏", "Hidden"))
            .help(areLibraryColumnsVisible ? L("隐藏阅读库边栏", "Hide library sidebar")
                                           : L("显示阅读库边栏", "Show library sidebar"))
        }
    }

    private var detailToolbarTitle: String? {
        readingArticle?.title
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if readingArticle != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: toggleDistractionFree) {
                    Label {
                        Text(L("专注阅读", "Distraction-free Reading"))
                    } icon: {
                        ReaderToolbarIcon(systemName: "viewfinder",
                                          activeSystemName: "arrow.down.right.and.arrow.up.left",
                                          isActive: isDistractionFree)
                    }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(isDistractionFree ? L("退出专注阅读", "Exit Focused Reading")
                                                      : L("专注阅读", "Distraction-free Reading"))
                .accessibilityIdentifier("reader.focus.toggle")
                .accessibilityAddTraits(isDistractionFree ? .isSelected : [])
                .help(isDistractionFree ? L("退出专注阅读（⇧⌘F 或 Esc）", "Exit focused reading (⇧⌘F or Esc)")
                                        : L("专注阅读（⇧⌘F）", "Distraction-free reading (⇧⌘F)"))

                if let model = readingIntensiveModel {
                    IntensiveReadingControl(model: model)
                        .id(ObjectIdentifier(model))
                }
            }
        }
        if route == .vocabulary || route == .byArticle {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle(L("显示释义", "Show Definitions"), isOn: $showsMeanings.animation(studyDisplayAnimation))
                    Toggle(L("显示例句", "Show Examples"), isOn: $showsExamples.animation(studyDisplayAnimation))
                } label: {
                    Label { Text(L("显示选项", "Display Options")) } icon: {
                        ReaderToolbarIcon(systemName: "slider.horizontal.3")
                    }
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("study.displayOptions")
                .menuIndicator(.visible)
                .accessibilityLabel(L("显示选项", "Display Options"))
                .help(L("显示或隐藏释义和例句", "Show or hide definitions and examples"))

                Menu {
                    if let scope = currentStudyExportScope {
                        Button(route == .vocabulary ? L("导出当前词条…", "Export Current Entry…")
                                                   : L("导出当前文章关联词条…", "Export Entries from Current Article…")) {
                            exportStudyCards(scope)
                        }
                    }
                    Button(L("导出整个词条库…", "Export Entire Entry Library…")) { exportStudyCards(.library) }
                        .keyboardShortcut("e", modifiers: .command)
                } label: {
                    Label { Text(L("导出", "Export")) } icon: {
                        ReaderToolbarIcon(systemName: "arrow.up.doc")
                    }
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("study.export")
                .menuIndicator(.visible)
                .accessibilityLabel(L("导出积累", "Export Saved Cards"))
                .help(L("导出积累为 CSV", "Export saved cards as CSV"))
                .disabled(!studyExporter.canExport(store: store))
            }
        }
        if !isDistractionFree {
            // The toolbar draws the glass, shape and hover/press states. A
            // fixed spacer keeps Settings on its own glass instead of joining
            // the reading-mode group.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            #endif
            ToolbarItem(id: "reader.settings", placement: .primaryAction) {
                SettingsLink {
                    Label { Text(L("设置", "Settings")) } icon: {
                        ReaderToolbarIcon(systemName: "gearshape")
                    }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(L("设置", "Settings"))
                .help(L("设置", "Settings"))
            }
        }
    }

    private func importArticles() {
        let panel = NSOpenPanel()
        panel.title = L("从文件添加文章", "Add Articles from Files")
        panel.prompt = L("检查文章", "Review Articles")
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "markdown") ?? .plainText]
        panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        presentFilePanel(panel, in: studyWindow.window) { response in
            guard response == .OK else { return }
            prepareArticles(panel.urls.map(ArticleImportItem.init(url:)))
        }
    }

    private func createArticle() {
        prepareArticles([ArticleImportItem(draft: ArticleDraft(), name: L("新文章", "New Article"))])
    }

    private func prepareArticles(_ items: [ArticleImportItem]) {
        guard !items.isEmpty else { return }
        articleImportRequest = ArticleImportRequest(items: items, folderID: selectedFolderID)
    }

    private var selectedFolderID: UUID? {
        if case .folder(let id)? = route { return id }
        return nil
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = L("导入档案", "Import Profile")
        panel.prompt = L("导入", "Import")
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        presentFilePanel(panel, in: studyWindow.window) { response in
            guard response == .OK, let url = panel.url else { return }
            perform { try store.importProfile(from: url) }
        }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.title = L("导出当前档案", "Export Current Profile")
        panel.prompt = L("导出", "Export")
        panel.nameFieldLabel = L("名称：", "Name:")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(store.archive.name).readingtool.json"
        presentFilePanel(panel, in: studyWindow.window) { response in
            guard response == .OK, let url = panel.url else { return }
            perform { try store.exportActiveProfile(to: url) }
        }
    }

    private func createProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProfileName = ""
        perform { try store.createProfile(name: name) }
    }

    private func renameActiveProfile() {
        renamedProfileName = store.archive.name
        isRenamingProfile = true
    }

    private func commitRenameActiveProfile() {
        let name = renamedProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        renamedProfileName = ""
        guard !name.isEmpty else { return }
        perform { try store.renameProfile(store.archive.id, name: name) }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        perform { try store.createFolder(name: name) }
    }

    private func renameFolder(_ folder: LibraryFolder) {
        renamedFolderName = folder.name
        renamingFolder = folder
    }

    private func commitRenameFolder() {
        guard let folder = renamingFolder else { return }
        let name = renamedFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingFolder = nil
        renamedFolderName = ""
        guard !name.isEmpty else { return }
        perform { try store.renameFolder(folder.id, name: name) }
    }

    private func confirmDeleteProfile() {
        isConfirmingDeleteProfile = true
    }

    private static let backupDateFormatterZH: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let backupDateFormatterEN: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func backupTitle(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let formatter = AppLanguageStore.shared.language == .english
            ? Self.backupDateFormatterEN : Self.backupDateFormatterZH
        return formatter.string(from: date)
    }

    private func confirmRestoreBackup(_ url: URL) {
        restoringBackupURL = url
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private func presentFilePanel(_ panel: NSSavePanel, in window: NSWindow?,
                              completion: @escaping (NSApplication.ModalResponse) -> Void) {
    if let window {
        panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
        panel.begin(completionHandler: completion)
    }
}

private struct ArticleListColumn: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    let title: String
    let folderID: UUID?
    @Binding var selectedArticleID: UUID?
    let window: NSWindow?
    let onImport: () -> Void
    let onCreate: () -> Void
    let onTemplates: () -> Void
    let onError: (Error) -> Void
    @State private var query = ""
    @State private var removingArticle: LibraryArticle?

    private var articles: [LibraryArticle] {
        store.archive.articles
            .filter { folderID == nil || $0.folderID == folderID }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.sourceName.localizedCaseInsensitiveContains(query) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List(selection: $selectedArticleID) {
            ForEach(articles) { article in
                ArticleListRowLabel(title: article.title)
                    .tag(article.id)
                    .contextMenu {
                        Menu(L("移动到文件夹", "Move to Folder")) {
                            Button(L("阅读库根目录", "Library Root")) { move(article, to: nil) }
                            ForEach(store.archive.folders) { folder in
                                Button(folder.name) { move(article, to: folder.id) }
                            }
                        }
                        Button(L("在 Finder 中显示", "Show in Finder")) { revealInFinder(article) }
                        Button(L("导出 Markdown…", "Export Markdown…")) { export(article) }
                        Button(L("从阅读库移除", "Remove from Library"), role: .destructive) {
                            removingArticle = article
                        }
                    }
            }
        }
        .listStyle(.inset)
        .overlay {
            if articles.isEmpty {
                ContentUnavailableView(query.isEmpty ? L("暂无文章", "No Articles Yet") : L("没有匹配文章", "No Matching Articles"),
                                       systemImage: query.isEmpty ? "doc.badge.plus" : "magnifyingglass")
            }
        }
        .nativeLibraryControlBar {
            HStack(spacing: 8) {
                NativeLibrarySearchField(prompt: L("搜索文章", "Search Articles"), text: $query)
                Menu {
                    Button(L("新建文章…", "New Article…"), action: onCreate)
                    Button(L("从文件导入…", "Import from Files…"), action: onImport)
                    Divider()
                    Button(L("模板", "Template"), action: onTemplates)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .fixedSize()
                .help(L("添加文章", "Add Articles"))
                .accessibilityLabel(L("添加文章", "Add Articles"))
                .accessibilityIdentifier("addArticleMenu")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .alert(removingArticle.map { L("从阅读库移除“\($0.title)”及其积累？",
                                       "Remove “\($0.title)” and its cards from the library?") } ?? "",
               isPresented: Binding(
                get: { removingArticle != nil },
                set: { if !$0 { removingArticle = nil } }
               )) {
            Button(L("取消", "Cancel"), role: .cancel) { removingArticle = nil }
            Button(L("移除", "Remove"), role: .destructive) {
                if let article = removingArticle {
                    removingArticle = nil
                    commitRemove(article)
                }
            }
        }
        .navigationTitle("")
    }

    private func move(_ article: LibraryArticle, to folderID: UUID?) {
        do { try store.moveArticle(article.id, to: folderID) }
        catch { onError(error) }
    }

    private func revealInFinder(_ article: LibraryArticle) {
        do {
            let url = try store.articleFileURL(article.id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { onError(error) }
    }

    private func commitRemove(_ article: LibraryArticle) {
        do {
            try store.deleteArticle(article.id)
            if selectedArticleID == article.id { selectedArticleID = nil }
        } catch { onError(error) }
    }

    private func export(_ article: LibraryArticle) {
        let panel = NSSavePanel()
        panel.title = L("导出 Markdown", "Export Markdown")
        panel.prompt = L("导出", "Export")
        panel.nameFieldLabel = L("名称：", "Name:")
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = article.sourceName
        presentFilePanel(panel, in: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try store.exportArticle(article.id, to: url) }
            catch { onError(error) }
        }
    }
}

private struct VocabularyRow: Identifiable {
    let key: String
    let expression: String
    let cards: [StudyCard]
    var id: String { key }
    var firstCreatedAt: Date { cards.map(\.createdAt).min() ?? .distantPast }
    var meanings: [String] { orderedMeanings(in: cards) }
}

private struct VocabularyListColumn: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    @Binding var selectedEntryKey: String?
    let showsMeanings: Bool
    @State private var query = ""

    private var entries: [VocabularyRow] {
        let groups = Dictionary(grouping: store.archive.cards, by: { normalizedExpression($0.expression) })
        return groups.compactMap { key, cards in
            let ordered = cards.sorted(by: newestCardFirst)
            guard let expression = ordered.last?.expression else { return nil }
            return VocabularyRow(key: key, expression: expression, cards: ordered)
        }
        .filter { query.isEmpty || $0.expression.localizedCaseInsensitiveContains(query) || $0.meanings.contains { $0.localizedCaseInsensitiveContains(query) } }
        .sorted {
            if $0.firstCreatedAt != $1.firstCreatedAt { return $0.firstCreatedAt > $1.firstCreatedAt }
            return $0.key < $1.key
        }
    }

    var body: some View {
        List(selection: $selectedEntryKey) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.expression)
                        .lineLimit(1).truncationMode(.tail).help(entry.expression)
                    if showsMeanings {
                        Text(entry.meanings.joined(separator: L("；", "; ")))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .tag(entry.key)
            }
        }
        .listStyle(.inset)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(query.isEmpty ? L("还没有词条积累", "No Words Yet") : L("没有匹配词条", "No Matching Entries"),
                                       systemImage: query.isEmpty ? "text.book.closed" : "magnifyingglass")
            }
        }
        .nativeLibraryControlBar {
            NativeLibrarySearchField(prompt: L("搜索词条或释义", "Search Expressions or Meanings"), text: $query)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .navigationTitle("")
    }
}

struct VocabularyEntryDetail: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    let entryKey: String
    let showsMeanings: Bool
    let showsExamples: Bool
    let openSource: (StudyCard) -> Void

    private var cards: [StudyCard] {
        store.archive.cards.filter { normalizedExpression($0.expression) == entryKey }
            .sorted(by: newestCardFirst)
    }

    var body: some View {
        ScrollView {
            StudyEntryCard(expression: cards.last?.expression ?? L("词条", "Entry"),
                           cards: cards, showsSourceTitle: true, showsMeanings: showsMeanings,
                           showsExamples: showsExamples, openSource: openSource)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
    }
}

private struct ArticleStudyListColumn: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    @Binding var selectedArticleID: UUID?
    @State private var query = ""

    private var articles: [LibraryArticle] {
        let groups = Dictionary(grouping: store.archive.cards, by: \.articleID)
        return store.archive.articles
            .filter { groups[$0.id] != nil }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.sourceName.localizedCaseInsensitiveContains(query) }
            .sorted {
                let left = groups[$0.id]?.map(\.createdAt).max() ?? .distantPast
                let right = groups[$1.id]?.map(\.createdAt).max() ?? .distantPast
                if left != right { return left > right }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var body: some View {
        List(selection: $selectedArticleID) {
            ForEach(articles) { article in
                ArticleListRowLabel(title: article.title)
                    .tag(article.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if articles.isEmpty {
                ContentUnavailableView(query.isEmpty ? L("还没有文章积累", "No Articles with Study Notes Yet") : L("没有匹配文章", "No Matching Articles"),
                                       systemImage: query.isEmpty ? "doc.text" : "magnifyingglass")
            }
        }
        .nativeLibraryControlBar {
            NativeLibrarySearchField(prompt: L("搜索文章", "Search Articles"), text: $query)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .navigationTitle("")
    }
}

/// Keep article content on the native list surface; the system owns selection
/// and the glass control layer above it.
private struct ArticleListRowLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.body)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .help(title)
    }
}

struct ArticleStudyDetail: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    let article: LibraryArticle
    let showsMeanings: Bool
    let showsExamples: Bool
    let openEntry: (StudyCard) -> Void
    let openSource: (StudyCard) -> Void

    private var cards: [StudyCard] {
        store.archive.cards.filter { $0.articleID == article.id }.sorted {
            let leftDetached = $0.isDetached == true
            let rightDetached = $1.isDetached == true
            if leftDetached != rightDetached { return !leftDetached }
            if !leftDetached {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
            }
            return newestCardFirst($0, $1)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(cards) { card in
                    StudyEntryCard(expression: card.expression, cards: [card],
                                   showsSourceTitle: false, showsMeanings: showsMeanings,
                                   showsExamples: showsExamples, openEntry: { openEntry(card) },
                                   openSource: openSource)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture { openEntry(card) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
    }
}

/// A single layout for an article's record and an entry's collected meanings and examples.
private struct StudyEntryCard: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    @EnvironmentObject private var editing: StudyInlineEditCoordinator
    @Environment(\.undoManager) private var undoManager
    let expression: String
    let cards: [StudyCard]
    let showsSourceTitle: Bool
    let showsMeanings: Bool
    let showsExamples: Bool
    var openEntry: (() -> Void)? = nil
    let openSource: (StudyCard) -> Void

    private var meanings: [String] { orderedMeanings(in: cards) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let openEntry {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    expressionText
                    Spacer(minLength: 0)
                    Button(action: openEntry) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("查看词条的全部释义与例句", "View all meanings and examples for this entry"))
                    .accessibilityLabel(L("查看词条：\(expression)", "View entry: \(expression)"))
                }
            } else {
                expressionText
            }

            if showsMeanings {
                ForEach(meanings, id: \.self) { meaning in
                    if meaning != meanings.first { Divider() }
                    VStack(alignment: .leading, spacing: 8) {
                        StudyInlineEditableText(text: meaning,
                            target: StudyInlineEditTarget(profileID: store.archive.id,
                                cardIDs: cards.filter { $0.meaning == meaning }.map(\.id), field: .meaning),
                            store: store, coordinator: editing, font: .systemFont(ofSize: 15, weight: .medium),
                            lineSpacing: 4, placeholder: L("释义", "Definition"),
                            label: L("释义", "Definition"), undoManager: undoManager)
                        VStack(alignment: .leading, spacing: showsExamples ? 16 : 10) {
                            ForEach(cards.filter { $0.meaning == meaning }) { card in
                                StudySourceView(card: card, showsSourceTitle: showsSourceTitle,
                                                showsExample: showsExamples, openSource: openSource)
                            }
                        }
                    }
                }
            } else {
                // Keep each source available without exposing hidden meanings through grouping.
                VStack(alignment: .leading, spacing: showsExamples ? 16 : 10) {
                    ForEach(cards) { card in
                        StudySourceView(card: card, showsSourceTitle: showsSourceTitle,
                                        showsExample: showsExamples, openSource: openSource)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var expressionText: some View {
        if openEntry != nil, let card = cards.first {
            StudyInlineEditableText(text: expression,
                target: StudyInlineEditTarget(profileID: store.archive.id, cardIDs: [card.id], field: .expression),
                store: store, coordinator: editing, font: .systemFont(ofSize: 22, weight: .semibold),
                placeholder: L("词条", "Entry"), label: L("词条", "Entry"), undoManager: undoManager)
        } else {
            Text(expression)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Both study routes read the same cards and the same preserved source sentence.
private struct StudySourceView: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    let card: StudyCard
    let showsSourceTitle: Bool
    let showsExample: Bool
    let openSource: (StudyCard) -> Void

    private var article: LibraryArticle? {
        store.archive.articles.first { $0.id == card.articleID }
    }

    private var emphasizedSentence: AttributedString {
        let sentence = store.originalSentence(for: card)
        var text = AttributedString(sentence)
        text.foregroundColor = .secondary
        for range in StudySentenceEmphasis.ranges(in: sentence, for: card, article: article) {
            guard let start = AttributedString.Index(range.lowerBound, within: text),
                  let end = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[start..<end].font = .system(size: 15, weight: .bold, design: .serif)
            text[start..<end].foregroundColor = .primary
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsExample {
                Text(emphasizedSentence)
                    .font(.system(size: 15, design: .serif))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(card.createdAt, style: .date)
                    .fixedSize()
                if showsSourceTitle, let article {
                    Text("·")
                    Text(article.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(article.title)
                }
                if card.isDetached == true {
                    Image(systemName: "exclamationmark.circle")
                        .help(L("原文位置已变更", "Original Location Changed"))
                        .accessibilityLabel(L("原文位置已变更", "Original Location Changed"))
                }
                Spacer(minLength: 12)
                if let article {
                    Button { openSource(card) } label: {
                        Text(L("查看原文", "View Source"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize()
                    }
                    .buttonStyle(.link)
                    .help(L("查看《\(article.title)》原文", "View source: “\(article.title)”"))
                    .accessibilityLabel(L("查看原文：\(article.title)", "View source: \(article.title)"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func newestCardFirst(_ left: StudyCard, _ right: StudyCard) -> Bool {
    if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
    return left.id.uuidString < right.id.uuidString
}

/// Preserve the most recent record order while grouping identical meanings.
private func orderedMeanings(in cards: [StudyCard]) -> [String] {
    var seen = Set<String>()
    return cards.sorted(by: newestCardFirst).compactMap { card in
        seen.insert(card.meaning).inserted ? card.meaning : nil
    }
}

private func normalizedExpression(_ expression: String) -> String {
    expression.replacingOccurrences(of: "...", with: "…")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
}
