import Darwin
import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("App Server client")
struct CodexAppServerClientTests {
    @Test("Client handshakes and reads quota from a child process", .timeLimit(.minutes(1)))
    func clientCompletesHandshakeAndReadsQuotaFromFakeProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexFuelGaugeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              echo '{"id":0,"result":{"userAgent":"fake"}}'
              ;;
            *'"method":"account/rateLimits/read"'*)
              echo '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":40,"windowDurationMins":60,"resetsAt":1787275064}}}}'
              ;;
          esac
        done
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        #expect(chmod(scriptURL.path, 0o755) == 0)

        let client = CodexAppServerClient()
        let snapshot = await withCheckedContinuation { continuation in
            client.onSnapshot = { snapshot in
                continuation.resume(returning: snapshot)
            }
            client.start(binaryURL: scriptURL)
        }
        client.stop()

        #expect(snapshot.mainRemainingPercent == 60)
    }
}
