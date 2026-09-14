import Darwin
import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("nettop client")
struct NetTopClientTests {
    @Test("A finite nettop process emits one CSV block through the client", .timeLimit(.minutes(1)))
    func streamsFiniteCSVBlock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexFuelGaugeNetTop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("fake-nettop")
        try #"""
        #!/bin/sh
        printf '%s\n' ',bytes_in,bytes_out,' 'Codex.42,10,20,'
        """#.write(to: scriptURL, atomically: true, encoding: .utf8)
        #expect(chmod(scriptURL.path, 0o755) == 0)

        let client = NetTopClient(executableURL: scriptURL)
        let samples: [NettopNetworkSample] = await withCheckedContinuation { continuation in
            client.onSamples = { samples in
                client.stop()
                continuation.resume(returning: samples)
            }
            client.onDisconnected = { message in
                Issue.record("Unexpected nettop disconnect: \(message)")
            }
            client.start(interval: 1)
        }

        #expect(samples.count == 1)
        #expect(samples[0].processName == "Codex")
        #expect(samples[0].bytesIn == 10)
        #expect(samples[0].bytesOut == 20)
    }
}
