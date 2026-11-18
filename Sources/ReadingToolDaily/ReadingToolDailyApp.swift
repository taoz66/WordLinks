import SwiftUI

@main
struct ReadingToolDailyApp: App {
    @StateObject private var bootstrap = AppBootstrap()
    @StateObject private var aiSettings = AISettingsStore()
    @State private var language = AppLanguageStore.shared
    @State private var appearance = AppearanceSettingsStore.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if let store = bootstrap.store {
                    LibraryWindow()
                        .environmentObject(store)
                        .environmentObject(aiSettings)
                } else {
                    ContentUnavailableView(
                        L("无法打开本地资料", "Unable to open local library"),
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(bootstrap.errorMessage ?? L("请检查应用本地资料后重试。", "Check the local library and try again."))
                    )
                    .frame(minWidth: 980)
                }
            }
            .frame(minHeight: 640)
            .environment(\.locale, language.locale)
            .preferredColorScheme(appearance.colorScheme)
            .onAppear {
                appearance.applyAppAppearance()
                appearance.applyAppIcon()
            }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
            LibrarySidebarCommands()
            ReaderDisplayCommands()
            StudyLibraryExportCommands()
        }
        Settings {
            SettingsWindowView()
                .environmentObject(aiSettings)
        }
    }
}

@MainActor
private final class AppBootstrap: ObservableObject {
    @Published var store: ReadingLibraryStore?
    @Published var errorMessage: String?

    init() {
        do {
            store = try ReadingLibraryStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
