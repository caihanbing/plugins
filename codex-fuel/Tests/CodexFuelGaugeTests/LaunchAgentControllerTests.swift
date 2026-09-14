import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("Launch agent fallback")
struct LaunchAgentControllerTests {
    @Test("Launch agent plist runs the installed app at user login")
    func buildsLaunchAgentPlist() throws {
        let bundleURL = URL(fileURLWithPath: "/Users/example/Applications/CodexFuelGauge.app")
        let data = try LaunchAgentPlistBuilder.data(for: bundleURL)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let plist = try #require(object as? [String: Any])
        let arguments = try #require(plist["ProgramArguments"] as? [String])

        #expect(plist["Label"] as? String == "com.codexfuelgauge.app")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(arguments == ["/usr/bin/open", "-a", bundleURL.path])
    }
}
