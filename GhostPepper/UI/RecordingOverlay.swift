import SwiftUI
import AppKit

enum OverlayMessage: String {
    case recording = "Recording..."
    case modelLoading = "Loading models..."
    case cleaningUp = "Cleaning up..."
    case transcribing = "Transcribing..."
}

class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayPillView>?

    func show(message: OverlayMessage = .recording) {
        if let hostingView = hostingView, let panel = panel {
            hostingView.rootView = OverlayPillView(message: message)
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let hosting = NSHostingView(rootView: OverlayPillView(message: message))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        self.hostingView = hosting

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 150
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}

struct OverlayPillView: View {
    let message: OverlayMessage
    @State private var isPulsing = false

    private var dotColor: Color {
        switch message {
        case .recording: return .red
        case .modelLoading: return .orange
        case .cleaningUp, .transcribing: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if message == .modelLoading {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .opacity(isPulsing ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            }

            Text(message.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.85))
        )
        .onAppear { isPulsing = true }
    }
}
