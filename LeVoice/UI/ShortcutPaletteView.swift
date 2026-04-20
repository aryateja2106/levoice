import AppKit
import SwiftUI

/// The SwiftUI body of the shortcut palette. Shows the frontmost app's menu
/// shortcuts in a filterable list.
struct ShortcutPaletteView: View {
    @ObservedObject var viewModel: ShortcutPaletteViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "command.square.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.appName.isEmpty ? "No App Focused" : viewModel.appName)
                        .font(.headline)
                    Text(viewModel.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-read shortcuts from the current frontmost app")
                .buttonStyle(.borderless)
            }
            TextField("Filter by name or menu path", text: $viewModel.filter)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
        }
        .padding(16)
    }

    private var list: some View {
        Group {
            if viewModel.filteredEntries.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if viewModel.showRecentSection {
                            sectionHeader("Recent")
                            ForEach(viewModel.recentEntries) { entry in
                                ShortcutPaletteRow(entry: entry, onFire: { viewModel.fire(entry) })
                                Divider()
                            }
                            sectionHeader("All Shortcuts")
                        }
                        ForEach(viewModel.filteredEntries) { entry in
                            ShortcutPaletteRow(entry: entry, onFire: { viewModel.fire(entry) })
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(viewModel.emptyMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(viewModel.filteredEntries.count) of \(viewModel.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy as JSON") { viewModel.copyAsJSON() }
                .disabled(viewModel.entries.isEmpty)
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

private struct ShortcutPaletteRow: View {
    let entry: ShortcutEntry
    let onFire: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { if entry.enabled { onFire() } }) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .fontWeight(.medium)
                        .foregroundStyle(entry.enabled ? .primary : .secondary)
                    if entry.menuPath.count > 1 {
                        Text(entry.menuPath.dropLast().joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                Text(entry.displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(entry.enabled ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(hovering && entry.enabled
                ? Color.accentColor.opacity(0.12)
                : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.enabled)
        .onHover { hovering = $0 }
        .help(entry.enabled
            ? "Click or press Enter to run · \(entry.displayString)"
            : "Disabled in the target app")
    }
}

/// View state for the palette. Pure @MainActor so SwiftUI can bind it safely.
@MainActor
final class ShortcutPaletteViewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var bundleId: String = ""
    @Published var subtitle: String = "Refresh to load the frontmost app."
    @Published var entries: [ShortcutEntry] = []
    @Published var recentEntries: [ShortcutEntry] = []
    @Published var filter: String = ""
    @Published var capturedAt: Date?

    /// Live AX references keyed by entry id. Only valid while the target app is running.
    private var axElements: [UUID: AXUIElement] = [:]
    /// The app that was frontmost when the palette was last refreshed — the one
    /// we should return focus to before pressing a menu item.
    private var targetApp: NSRunningApplication?

    /// Usage store for recent/frequent ranking. Local-only, UserDefaults-backed.
    private let usageStore = ShortcutUsageStore()

    var filteredEntries: [ShortcutEntry] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            if entry.title.lowercased().contains(trimmed) { return true }
            if entry.menuPath.joined(separator: " ").lowercased().contains(trimmed) { return true }
            if entry.displayString.lowercased().contains(trimmed) { return true }
            return false
        }
    }

    /// Recent entries only show when there's no active filter — filtering is
    /// a flat search across everything.
    var showRecentSection: Bool {
        filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recentEntries.isEmpty
    }

    var emptyMessage: String {
        if !filter.isEmpty { return "No shortcuts match \"\(filter)\"." }
        if entries.isEmpty {
            return "No shortcuts captured yet. Make sure Accessibility is granted, focus the app you want to inspect, then click refresh."
        }
        return ""
    }

    /// Walks the frontmost app's menu and reloads the list. **Must be called
    /// before the palette window steals focus** — `NSWorkspace.frontmostApplication`
    /// is read synchronously at the top to capture the intended target app.
    func refresh() {
        let previousName = appName
        subtitle = "Reading menu…"

        // Capture target app synchronously — if we defer this to the background
        // task, LeVoice's window will already be key by the time we read it.
        let target = NSWorkspace.shared.frontmostApplication
        self.targetApp = target

        Task.detached(priority: .userInitiated) {
            let capture: AppMenuIntrospecter.Capture?
            if let target {
                capture = AppMenuIntrospecter.captureWithElements(app: target)
            } else {
                capture = AppMenuIntrospecter.captureFrontmostAppWithElements()
            }
            await MainActor.run {
                guard let capture else {
                    self.appName = previousName
                    self.subtitle = "Could not read the frontmost app's menu. Check Accessibility permission."
                    return
                }
                self.appName = capture.graph.appName
                self.bundleId = capture.graph.bundleId
                self.entries = capture.graph.entries
                self.axElements = capture.elements
                self.capturedAt = capture.graph.capturedAt
                self.subtitle = Self.formatSubtitle(count: capture.graph.entries.count, bundleId: capture.graph.bundleId)
                self.recentEntries = self.usageStore.recent(
                    bundleId: capture.graph.bundleId,
                    entries: capture.graph.entries,
                    limit: 5
                )
            }
        }
    }

    /// Executes the selected shortcut. Closes the palette, returns focus to the
    /// target app, then triggers the menu item via `AXUIElementPerformAction`.
    /// Silently no-ops if the AX element is gone — falling through would synth
    /// a keystroke instead, but that path hasn't been implemented yet.
    @discardableResult
    func fire(_ entry: ShortcutEntry) -> Bool {
        guard let element = axElements[entry.id] else { return false }

        // Record usage BEFORE closing the palette so even if press fails, the
        // user's intent is captured.
        usageStore.record(bundleId: bundleId, menuPath: entry.menuPath)

        // Close the palette.
        NSApp.keyWindow?.orderOut(nil)

        // Restore focus to the target app, then press.
        let target = targetApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            target?.activate(options: [])
            // Tiny additional delay so AX sees the frontmost app as the target
            // again — some apps lazy-refresh their menu focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                _ = AppMenuIntrospecter.press(element: element)
            }
        }
        return true
    }

    /// Copy the full graph to the pasteboard as pretty-printed JSON.
    func copyAsJSON() {
        guard !entries.isEmpty else { return }
        let graph = AppShortcutGraph(
            bundleId: bundleId,
            appName: appName,
            capturedAt: capturedAt ?? Date(),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(graph),
              let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    private static func formatSubtitle(count: Int, bundleId: String) -> String {
        let bundleSuffix = bundleId.isEmpty ? "" : " · \(bundleId)"
        let word = count == 1 ? "shortcut" : "shortcuts"
        return "\(count) \(word)\(bundleSuffix)"
    }
}
