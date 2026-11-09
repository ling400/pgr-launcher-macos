import SwiftUI

/// Root window content: sidebar + routed page + collapsible log console.
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @State private var logConsoleExpanded = false

    /// Routing is owned by AppState (`showSettings` / `showKeyMapping` / `showLogs`)
    /// so other parts of the app can drive navigation too.
    private var page: Binding<SidebarPage> {
        Binding(
            get: {
                if state.showSettings { return .settings }
                if state.showKeyMapping { return .keymap }
                if state.showLogs { return .logs }
                return .game
            },
            set: { newValue in
                state.showSettings = newValue == .settings
                state.showKeyMapping = newValue == .keymap
                state.showLogs = newValue == .logs
            }
        )
    }

    var body: some View {
        ZStack {
            AmbientBackground()

            HStack(spacing: 0) {
                SidebarView(page: page)

                VStack(spacing: 0) {
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if page.wrappedValue == .game {
                        LogConsoleBar(expanded: $logConsoleExpanded)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1080, minHeight: 648)
        .background(PGRTheme.bgBase)
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: logConsoleExpanded)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page.wrappedValue {
        case .game:
            GamePage()
                .transition(.opacity)
        case .keymap:
            KeyMappingPage(mapper: state.keyMapper)
                .transition(.opacity)
        case .logs:
            LogsPage()
                .transition(.opacity)
        case .settings:
            SettingsPage()
                .transition(.opacity)
        }
    }
}
