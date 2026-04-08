import AppKit
import SwiftUI

// MARK: - Window Controller

final class MeetingTranscriptWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onOpenSettings: (() -> Void)?

    func show(session: MeetingSession) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = MeetingTranscriptView(session: session, onOpenSettings: onOpenSettings)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 720, height: 900)
        let windowHeight = screenFrame.height
        let windowWidth: CGFloat = 720

        let window = NSWindow(
            contentRect: NSRect(
                x: screenFrame.midX - windowWidth / 2,
                y: screenFrame.minY,
                width: windowWidth,
                height: windowHeight
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .textBackgroundColor
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 400)
        window.contentViewController = NSHostingController(rootView: view)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        NSApp.setActivationPolicy(.regular)
        window.setFrame(NSRect(
            x: screenFrame.midX - windowWidth / 2,
            y: screenFrame.minY,
            width: windowWidth,
            height: windowHeight
        ), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}

// MARK: - Tab Enum

enum MeetingTab: String, CaseIterable {
    case notes
    case transcript
    case summary

    var label: String {
        switch self {
        case .notes: "📝 Notes"
        case .transcript: "📜 Transcript"
        case .summary: "✨ Summary"
        }
    }
}

// MARK: - Main View

struct MeetingTranscriptView: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var transcript: MeetingTranscript
    @State private var selectedTab: MeetingTab = .notes
    @State private var searchText: String = ""
    @State private var showSearch: Bool = false
    @State private var showSidebar: Bool = false
    @State private var historyGroups: [(date: String, entries: [MeetingHistoryEntry])] = []
    var onOpenSettings: (() -> Void)?

    init(session: MeetingSession, onOpenSettings: (() -> Void)? = nil) {
        self.session = session
        self.transcript = session.transcript
        self.onOpenSettings = onOpenSettings
    }

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Collapsible sidebar
            if showSidebar {
                meetingSidebar
                    .transition(.move(edge: .leading))

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }

            // Main content
            VStack(spacing: 0) {
                toolbar

                // No audio warning
                if session.noAudioDetected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("No audio detected. Check your microphone is on and selected correctly.")
                            .font(.caption)
                            .foregroundColor(.primary)
                        Spacer()
                        Button("Open Settings") {
                            onOpenSettings?()
                        }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                VStack(alignment: .leading, spacing: 0) {
                    // Title + date + tabs (pinned at top)
                    VStack(alignment: .leading, spacing: 0) {
                        titleSection
                        tabBar
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)

                    // Search bar
                    if showSearch {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            TextField("Search...", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($searchFieldFocused)
                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            Button(action: { showSearch = false; searchText = "" }) {
                                Text("Done")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 52)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .onAppear { searchFieldFocused = true }
                    }

                    // Tab content (fills remaining space)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                tabContent(proxy: proxy)
                            }
                            .padding(.horizontal, 48)
                            .padding(.top, 24)
                            .padding(.bottom, 60)
                            .frame(maxWidth: 720, alignment: .leading)
                            .frame(maxWidth: .infinity)
                        }
                        .onChange(of: transcript.segments.count) { _, _ in
                            if selectedTab == .transcript, let last = transcript.segments.last {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }

                statusBar
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 400)
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .onAppear {
            loadHistory()
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
                    showSearch.toggle()
                    if !showSearch { searchText = "" }
                    return nil
                }
                if event.keyCode == 53 && showSearch { // Escape
                    showSearch = false
                    searchText = ""
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: { showSidebar.toggle() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if session.isActive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)

                    LiveDurationView(startDate: transcript.startDate)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    Task { await session.stop() }
                }) {
                    Text("Stop recording")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.red))
                }
                .buttonStyle(.plain)
            } else if transcript.endDate != nil {
                Text(transcript.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Untitled", text: $transcript.meetingName)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primary)

            Text(dateSubtitle)
                .font(.callout)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
    }

    private var dateSubtitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let endDate = transcript.endDate {
            let endFormatter = DateFormatter()
            endFormatter.timeStyle = .short
            return "\(formatter.string(from: transcript.startDate)) — \(endFormatter.string(from: endDate))"
        }
        return formatter.string(from: transcript.startDate)
    }

    // MARK: - Tab Bar (Underline style)

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(MeetingTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        Text(tab.label)
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .orange : .secondary)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                if selectedTab == tab {
                                    Rectangle()
                                        .fill(Color.orange)
                                        .frame(height: 2)
                                        .offset(y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(proxy: ScrollViewProxy) -> some View {
        switch selectedTab {
        case .notes:
            notesTab
        case .transcript:
            transcriptTab
        case .summary:
            summaryTab
        }
    }

    // MARK: - Notes Tab (Notion-style)

    private var filteredSegments: [TranscriptSegment] {
        guard !searchText.isEmpty else { return transcript.segments }
        return transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private static let notesFont = Font.custom("Georgia", size: 15)

    private var notesTab: some View {
        ZStack(alignment: .topLeading) {
            if transcript.notes.isEmpty {
                Text("Start typing your notes...")
                    .font(Self.notesFont)
                    .foregroundColor(Color(nsColor: .placeholderTextColor))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $transcript.notes)
                .font(Self.notesFont)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Transcript Tab

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if transcript.segments.isEmpty {
                if session.isActive {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Listening — segments appear every ~30 seconds")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    Text("No transcript yet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }

            ForEach(filteredSegments) { segment in
                TranscriptSegmentRow(segment: segment, highlightText: searchText)
                    .id(segment.id)
            }

            if session.isActive && !transcript.segments.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.secondary.opacity(0.4)).frame(width: 4, height: 4)
                        Circle().fill(Color.secondary.opacity(0.3)).frame(width: 4, height: 4)
                        Circle().fill(Color.secondary.opacity(0.2)).frame(width: 4, height: 4)
                    }
                    Text("Listening...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Summary Tab

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            if session.isActive {
                // During meeting
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundColor(.orange.opacity(0.4))
                    Text("Summary will be generated when the meeting ends")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if transcript.segments.isEmpty {
                Text("No transcript to summarize.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 40)
            } else {
                // Post-meeting summary
                summaryContent
            }
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Meeting Stats
            VStack(alignment: .leading, spacing: 10) {
                SummarySectionHeader(title: "Meeting Stats")

                HStack(spacing: 24) {
                    StatBlock(value: transcript.formattedDuration, label: "Duration")
                    StatBlock(value: "\(transcript.segments.count)", label: "Segments")

                    let myCount = transcript.segments.filter { $0.speaker == .me }.count
                    let total = max(transcript.segments.count, 1)
                    let myPct = Int(Double(myCount) / Double(total) * 100)
                    StatBlock(value: "\(myPct)%", label: "You spoke", color: .orange)
                    StatBlock(value: "\(100 - myPct)%", label: "Others spoke", color: .blue)
                }
            }

            // Key Topics (placeholder — would be LLM-generated)
            VStack(alignment: .leading, spacing: 10) {
                SummarySectionHeader(title: "Key Topics")
                Text("Key topics will be extracted from the transcript using the local cleanup model after the meeting ends.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }

            // TL;DR (placeholder)
            VStack(alignment: .leading, spacing: 10) {
                SummarySectionHeader(title: "TL;DR")
                Text("A brief summary of the meeting will appear here, generated locally after the meeting ends.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let url = session.fileURL {
                Button(action: {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(url.lastPathComponent)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if !transcript.segments.isEmpty {
                Text("\(transcript.segments.count) segments")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1)
        }
    }

    // MARK: - Meeting Sidebar

    private var meetingSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Meetings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Current meeting
            if session.isActive {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("Recording")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    Text(transcript.meetingName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            // Past meetings
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if historyGroups.isEmpty {
                        Text("No past meetings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    ForEach(historyGroups, id: \.date) { group in
                        Text(group.date)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 2)

                        ForEach(group.entries) { entry in
                            Button(action: {
                                openMeetingFile(entry.fileURL)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text(entry.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)

            Divider()
                .padding(.horizontal, 12)

            // Open vault button
            Button(action: {
                openMeetingsFolder()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                    Text(Self.openFolderButtonLabel)
                        .font(.system(size: 12))
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Smart File Opening

    private static let obsidianPreferenceKey = "meetingOpenInObsidian"
    private static let obsidianPreferenceSetKey = "meetingOpenPreferenceSet"

    private static var hasObsidian: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "obsidian://")!) != nil
    }

    private static var hasObsidianVault: Bool {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(".obsidian").path)
    }

    /// The label for the bottom sidebar button, based on detected state.
    static var openFolderButtonLabel: String {
        let prefSet = UserDefaults.standard.bool(forKey: obsidianPreferenceSetKey)
        if prefSet {
            return UserDefaults.standard.bool(forKey: obsidianPreferenceKey)
                ? "Open in Obsidian" : "Open in Finder"
        }
        return hasObsidian ? "Open in Obsidian" : "Open in Finder"
    }

    private func openMeetingFile(_ fileURL: URL) {
        guard Self.hasObsidian else {
            NSWorkspace.shared.open(fileURL)
            return
        }

        let prefSet = UserDefaults.standard.bool(forKey: Self.obsidianPreferenceSetKey)
        if prefSet {
            if UserDefaults.standard.bool(forKey: Self.obsidianPreferenceKey) {
                openFileInObsidian(fileURL)
            } else {
                NSWorkspace.shared.open(fileURL)
            }
            return
        }

        // First time — vault exists? Open directly. No vault? Ask.
        if Self.hasObsidianVault {
            UserDefaults.standard.set(true, forKey: Self.obsidianPreferenceSetKey)
            UserDefaults.standard.set(true, forKey: Self.obsidianPreferenceKey)
            openFileInObsidian(fileURL)
        } else {
            showObsidianVaultPrompt(then: fileURL)
        }
    }

    private func openMeetingsFolder() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        guard Self.hasObsidian else {
            NSWorkspace.shared.open(dir)
            return
        }

        let prefSet = UserDefaults.standard.bool(forKey: Self.obsidianPreferenceSetKey)
        let useObsidian = prefSet
            ? UserDefaults.standard.bool(forKey: Self.obsidianPreferenceKey)
            : Self.hasObsidianVault

        if useObsidian {
            if !Self.hasObsidianVault { ensureObsidianVault() }
            let path = dir.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dir.path
            if let url = URL(string: "obsidian://open?path=\(path)") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        NSWorkspace.shared.open(dir)
    }

    private func showObsidianVaultPrompt(then fileURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Open in Obsidian?"
        alert.informativeText = "Your meetings folder can be set up as an Obsidian vault for rich markdown editing, linking, and search. This creates a .obsidian folder in your meetings directory."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create Vault & Open")
        alert.addButton(withTitle: "Use Default App")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            ensureObsidianVault()
            UserDefaults.standard.set(true, forKey: Self.obsidianPreferenceSetKey)
            UserDefaults.standard.set(true, forKey: Self.obsidianPreferenceKey)
            openFileInObsidian(fileURL)
        } else {
            UserDefaults.standard.set(true, forKey: Self.obsidianPreferenceSetKey)
            UserDefaults.standard.set(false, forKey: Self.obsidianPreferenceKey)
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func openFileInObsidian(_ fileURL: URL) {
        let path = fileURL.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileURL.path
        if let url = URL(string: "obsidian://open?path=\(path)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ensureObsidianVault() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        let obsidianDir = dir.appendingPathComponent(".obsidian")
        if !FileManager.default.fileExists(atPath: obsidianDir.path) {
            try? FileManager.default.createDirectory(at: obsidianDir, withIntermediateDirectories: true)
        }
    }

    private func loadHistory() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        historyGroups = MeetingHistory.loadEntries(from: dir)
    }
}

// MARK: - Summary Helpers

private struct SummarySectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.secondary)
            .tracking(0.5)
    }
}

private struct StatBlock: View {
    let value: String
    let label: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    var highlightText: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)

            Text(segment.speaker.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(speakerColor))

            highlightedText
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var highlightedText: Text {
        guard !highlightText.isEmpty else { return Text(segment.text) }

        var attributed = AttributedString(segment.text)
        let query = highlightText.lowercased()
        var searchRange = attributed.startIndex..<attributed.endIndex

        while let range = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.5)
            attributed[range].foregroundColor = .black
            searchRange = range.upperBound..<attributed.endIndex
        }

        return Text(attributed)
    }

    private var speakerColor: Color {
        switch segment.speaker {
        case .me:
            return .orange
        case .remote:
            return .blue
        }
    }
}

// MARK: - Live Duration Timer

struct LiveDurationView: View {
    let startDate: Date

    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formattedDuration)
            .onReceive(timer) { tick in
                now = tick
            }
    }

    private var formattedDuration: String {
        let total = Int(now.timeIntervalSince(startDate))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
