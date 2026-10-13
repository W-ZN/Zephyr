import Sparkle

/// Sparkle's controller is created only for a normal app launch. Its persisted preferences belong
/// to Sparkle, so the settings UI reads and changes the updater directly.
final class AppUpdater {
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    func start() {
        controller.startUpdater()
    }
}
