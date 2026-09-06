import SwiftUI
import UIKit

@main
struct TwinzoScanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // AR work is continuous and the operator is holding the device
                // at arm's length, not touching it, so the idle timer would
                // otherwise dim the screen mid-inspection.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}
