import Testing
@testable import BetterShutter

struct BetterShutterTests {
    @Test @MainActor
    func settingsConfigurationHasTabs() {
        let configuration = makeSettingsConfiguration()
        #expect(configuration.tabs.isEmpty == false)
        #expect(configuration.tabs.contains { $0.id == "general" })
    }
}
