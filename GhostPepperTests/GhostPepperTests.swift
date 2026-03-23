import XCTest
import SwiftUI
@testable import GhostPepper

@MainActor
final class GhostPepperTests: XCTestCase {
    func testAppStateInitialStatus() {
        // AppState is @MainActor so we test basic enum
        XCTAssertEqual(AppStatus.ready.rawValue, "Ready")
        XCTAssertEqual(AppStatus.recording.rawValue, "Recording...")
        XCTAssertEqual(AppStatus.transcribing.rawValue, "Transcribing...")
        XCTAssertEqual(AppStatus.error.rawValue, "Error")
    }

    func testOverlayHostingViewDoesNotManageWindowSizingConstraints() {
        let overlay = RecordingOverlayController()
        overlay.show(message: .recording)
        defer { overlay.dismiss() }

        let panel: NSPanel? = unwrapPrivateOptional(named: "panel", from: overlay)
        let hostingView: NSHostingView<OverlayPillView>? = unwrapPrivateOptional(
            named: "hostingView",
            from: overlay
        )

        XCTAssertNotNil(panel)
        XCTAssertNotNil(hostingView)
        XCTAssertEqual(hostingView?.sizingOptions, [])
        XCTAssertFalse(panel?.contentView is NSHostingView<OverlayPillView>)
    }

    private func unwrapPrivateOptional<T>(named name: String, from object: Any) -> T? {
        let mirror = Mirror(reflecting: object)
        guard let child = mirror.children.first(where: { $0.label == name }) else {
            return nil
        }

        let optionalMirror = Mirror(reflecting: child.value)
        guard optionalMirror.displayStyle == .optional else {
            return child.value as? T
        }

        return optionalMirror.children.first?.value as? T
    }
}
