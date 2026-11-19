import AppKit
import SwiftUI

enum KeyAction {
    case up, down, left, right, delete, enter, escape, pageUp, pageDown, home, end
}

/// Routes keyboard events from the window to the visible page.
final class KeyboardRouter {
    static let shared = KeyboardRouter()
    var handler: ((KeyAction) -> Bool)?
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationRail()
                ZStack(alignment: .bottom) {
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let banner = state.message {
                        BannerView(banner: banner) { state.message = nil }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .task(id: banner.id) {
                                try? await Task.sleep(nanoseconds: 6_000_000_000)
                                if state.message?.id == banner.id { state.message = nil }
                            }
                    }
                }
                .background(Theme.content)
                .clipShape(UnevenCorner(radius: 8))
                .overlay(UnevenCorner(radius: 8).stroke(Theme.contentBorder, lineWidth: 1))
            }
        }
        .background(
            ZStack {
                VisualEffectBackground(material: .underWindowBackground)
                Theme.window.opacity(0.88)
            }
            .ignoresSafeArea()
        )
        .animation(.easeOut(duration: 0.18), value: state.message)
        .sheet(isPresented: $state.runTaskShown) { RunTaskSheet().environmentObjects(state, monitor, preferences) }
        .sheet(item: $state.properties) { record in
            PropertiesSheet(record: record).environmentObjects(state, monitor, preferences)
        }
        .sheet(item: Binding(
            get: { state.pendingEfficiency.map(EfficiencyRequest.init) },
            set: { if $0 == nil { state.pendingEfficiency = nil } }
        )) { request in
            EfficiencyConfirmSheet(records: request.records).environmentObjects(state, monitor, preferences)
        }
        .onChange(of: state.page) { page in
            state.selection = nil
            updateDemand(for: page)
        }
        .onChange(of: preferences.processColumns) { _ in updateDemand(for: state.page) }
        .onAppear { updateDemand(for: state.page) }
    }

    @ViewBuilder
    private var page: some View {
        switch state.page {
        case .processes: ProcessesPage()
        case .performance: PerformancePage()
        case .appHistory: AppHistoryPage()
        case .startup: StartupPage()
        case .users: UsersPage()
        case .details: DetailsPage()
        case .services: ServicesPage()
        case .settings: SettingsPage()
        }
    }

    /// Only sample what the current page shows.
    private func updateDemand(for page: Page) {
        var demand = SampleDemand()
        let columns = preferences.processColumns
        switch page {
        case .processes:
            demand.perProcessNetwork = columns.contains(.network)
            demand.perProcessGPU = columns.contains(.gpu)
        case .appHistory:
            demand.perProcessNetwork = true
            demand.perProcessGPU = false
        case .performance:
            demand.perProcessNetwork = false
            demand.perProcessGPU = false
            demand.threadCount = true
        default:
            demand.perProcessNetwork = false
            demand.perProcessGPU = false
        }
        monitor.demand = demand
    }
}

extension View {
    func environmentObjects(_ state: AppState, _ monitor: Monitor, _ preferences: Preferences) -> some View {
        environmentObject(state).environmentObject(monitor).environmentObject(preferences)
    }
}

private struct EfficiencyRequest: Identifiable {
    var id: String { records.map { String($0.pid) }.joined(separator: ",") }
    var records: [ProcessRecord]
}

/// Rounds only the top-leading corner, like the Windows 11 content layer.
struct UnevenCorner: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.maxY + 1))
        path.closeSubpath()
        return path
    }
}

// MARK: - Toolbar content

/// App icon and name, shown at the leading edge of the unified toolbar.
struct ToolbarTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18, height: 18)
            Text("Task Manager")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
        }
        .fixedSize()
        .padding(.leading, 4)
    }
}

/// The search box centered in the toolbar. It filters whichever page is open.
struct ToolbarSearchField: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            TextField("Type a name, publisher, or PID to search", text: $state.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onExitCommand {
                    state.search = ""
                    focused = false
                }
            if !state.search.isEmpty {
                Button {
                    state.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.input))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? Color.accentColor : Theme.inputBorder, lineWidth: focused ? 1.5 : 1)
        )
        .onChange(of: state.focusSearch) { focus in
            if focus {
                focused = true
                state.focusSearch = false
            }
        }
        .onChange(of: state.search) { text in
            // Searching from Performance or Settings jumps to Processes, like Windows.
            if !text.isEmpty, state.page == .performance || state.page == .settings {
                state.page = .processes
            }
        }
    }
}

// MARK: - Navigation rail

struct NavigationRail: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        let expanded = preferences.navigationExpanded
        VStack(alignment: .leading, spacing: 2) {
            NavItem(title: expanded ? "Collapse navigation" : "Expand navigation", symbol: "line.3.horizontal",
                    selected: false, expanded: false) {
                withAnimation(.easeOut(duration: 0.15)) { preferences.navigationExpanded.toggle() }
            }
            .padding(.bottom, 6)
            ForEach(Page.navigable) { page in
                NavItem(title: page.title, symbol: page.symbol, selected: state.page == page, expanded: expanded) {
                    state.page = page
                }
            }
            Spacer()
            NavItem(title: Page.settings.title, symbol: Page.settings.symbol,
                    selected: state.page == .settings, expanded: expanded) {
                state.page = .settings
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(width: expanded ? 220 : 56, alignment: .leading)
    }
}

private struct NavItem: View {
    var title: String
    var symbol: String
    var selected: Bool
    var expanded: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .frame(width: 20)
                if expanded {
                    Text(title)
                        .font(.tmBody)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .frame(maxWidth: expanded ? .infinity : 48, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Theme.selection : (hovering ? Theme.hover : .clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .onHover { hovering = $0 }
        .help(title)
    }
}
