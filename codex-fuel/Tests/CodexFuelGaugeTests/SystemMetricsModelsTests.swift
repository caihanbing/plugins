import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("System metrics models")
struct SystemMetricsModelsTests {
    @Test("Application identity prefers the outermost app bundle")
    func resolvesOutermostAppBundleIdentity() {
        let identity = ApplicationIdentityResolver.resolve(
            processName: "Codex Helper (Renderer)",
            executablePath: "/Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper"
        )

        #expect(identity.displayName == "Codex.app")
        #expect(identity.bundleName == "Codex.app")
        #expect(identity.bundleURL?.path == "/Applications/Codex.app")
    }

    @Test("Application identity falls back to the process name")
    func fallsBackToProcessNameWhenNoBundleExists() {
        let identity = ApplicationIdentityResolver.resolve(
            processName: "sshd",
            executablePath: "/usr/sbin/sshd"
        )

        #expect(identity.displayName == "sshd")
        #expect(identity.bundleName == nil)
    }

    @Test("The parser keeps the real three-column nettop boundary")
    func parsesActualNettopRowsAndSkipsRepeatedHeaders() {
        let csv = #"""
        ,bytes_in,bytes_out,
        Codex (Service).1290,14442882,8809605,
        ,bytes_in,bytes_out,
        微信.42,10,20,
        Helper.Agent,30,40,
        """#

        let samples = NettopCSVParser.parse(csv)

        #expect(samples.count == 3)
        #expect(samples[0].processToken == "Codex (Service).1290")
        #expect(samples[0].processName == "Codex (Service)")
        #expect(samples[0].pid == 1_290)
        #expect(samples[0].bytesIn == 14_442_882)
        #expect(samples[0].bytesOut == 8_809_605)

        #expect(samples[1].processToken == "微信.42")
        #expect(samples[1].processName == "微信")
        #expect(samples[1].pid == 42)

        #expect(samples[2].processToken == "Helper.Agent")
        #expect(samples[2].processName == "Helper.Agent")
        #expect(samples[2].pid == nil)
    }

    @Test("Malformed nettop rows are ignored")
    func skipsMalformedNettopRows() {
        let samples = NettopCSVParser.parse(#"""
        ,bytes_in,bytes_out,
        broken-row
        bad.number,not-a-number,12,
        missing-output,18,,
        Valid Helper.77,18,19,
        """#)

        #expect(samples.count == 1)
        #expect(samples[0].processToken == "Valid Helper.77")
        #expect(samples[0].processName == "Valid Helper")
        #expect(samples[0].pid == 77)
        #expect(samples[0].bytesIn == 18)
        #expect(samples[0].bytesOut == 19)
    }

    @Test("The first cumulative sample only establishes a baseline")
    func firstCumulativeSampleEstablishesBaseline() {
        var timeline = ProcessMetricsTimeline()

        let first = timeline.ingest([
            processSample(
                pid: 42,
                startTime: 1_000,
                processName: "Codex",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 120,
                memoryBytes: 512,
                bytesIn: 300,
                bytesOut: 200
            )
        ])

        #expect(first.isEmpty)
    }

    @Test("Tick deltas are computed from the previous cumulative sample")
    func computesTickDeltasFromPreviousSample() {
        var timeline = ProcessMetricsTimeline()
        _ = timeline.ingest([
            processSample(
                pid: 42,
                startTime: 1_000,
                processName: "Codex",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 120,
                memoryBytes: 512,
                bytesIn: 300,
                bytesOut: 200
            )
        ])

        let second = timeline.ingest([
            processSample(
                pid: 42,
                startTime: 1_000,
                processName: "Codex",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 165,
                memoryBytes: 640,
                bytesIn: 420,
                bytesOut: 260
            )
        ])

        #expect(second.count == 1)
        #expect(second[0].application.displayName == "Codex.app")
        #expect(second[0].processName == "Codex")
        #expect(second[0].cpuTicks == 45)
        #expect(second[0].memoryBytes == 640)
        #expect(second[0].bytesIn == 120)
        #expect(second[0].bytesOut == 60)
    }

    @Test("Counter rollbacks become a fresh baseline")
    func treatsCounterRollbackAsFreshBaseline() {
        var timeline = ProcessMetricsTimeline()
        _ = timeline.ingest([
            processSample(
                pid: 99,
                startTime: 2_000,
                processName: "Codex",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 500,
                memoryBytes: 1_024,
                bytesIn: 700,
                bytesOut: 800
            )
        ])

        let rollback = timeline.ingest([
            processSample(
                pid: 99,
                startTime: 2_000,
                processName: "Codex",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 520,
                memoryBytes: 1_024,
                bytesIn: 720,
                bytesOut: 100
            )
        ])

        #expect(rollback.isEmpty)

        let afterRollback = timeline.ingest([
            processSample(
                pid: 99,
                startTime: 2_000,
                processName: "Codex",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 550,
                memoryBytes: 2_048,
                bytesIn: 740,
                bytesOut: 145
            )
        ])

        #expect(afterRollback.count == 1)
        #expect(afterRollback[0].cpuTicks == 30)
        #expect(afterRollback[0].bytesIn == 20)
        #expect(afterRollback[0].bytesOut == 45)
    }

    @Test("PID reuse is separated by start time")
    func separatesPidReuseByStartTime() {
        var timeline = ProcessMetricsTimeline()
        _ = timeline.ingest([
            processSample(
                pid: 77,
                startTime: 1_000,
                processName: "Worker",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 200,
                memoryBytes: 256,
                bytesIn: 40,
                bytesOut: 50
            )
        ])

        let reusedPidBaseline = timeline.ingest([
            processSample(
                pid: 77,
                startTime: 2_000,
                processName: "Worker",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 250,
                memoryBytes: 384,
                bytesIn: 60,
                bytesOut: 70
            )
        ])

        #expect(reusedPidBaseline.isEmpty)

        let reusedPidDelta = timeline.ingest([
            processSample(
                pid: 77,
                startTime: 2_000,
                processName: "Worker",
                executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                cpuTicks: 275,
                memoryBytes: 384,
                bytesIn: 68,
                bytesOut: 80
            )
        ])

        #expect(reusedPidDelta.count == 1)
        #expect(reusedPidDelta[0].cpuTicks == 25)
    }

    @Test("App grouping collapses helper processes into the outermost app")
    func groupsProcessesByApplicationIdentity() {
        let grouped = AppMetricsAggregator.group([
            processSnapshot(
                pid: 31,
                startTime: 1_000,
                processName: "Acme Helper",
                executablePath: "/Applications/Acme Suite.app/Contents/Frameworks/Acme Helper.app/Contents/MacOS/Acme Helper",
                cpuTicks: 40,
                memoryBytes: 100,
                bytesIn: 10,
                bytesOut: 15
            ),
            processSnapshot(
                pid: 32,
                startTime: 1_000,
                processName: "Acme Renderer",
                executablePath: "/Applications/Acme Suite.app/Contents/Frameworks/Acme Renderer.app/Contents/MacOS/Acme Renderer",
                cpuTicks: 25,
                memoryBytes: 90,
                bytesIn: 8,
                bytesOut: 12
            ),
            processSnapshot(
                pid: 33,
                startTime: 1_000,
                processName: "微信",
                executablePath: nil,
                cpuTicks: 7,
                memoryBytes: 200,
                bytesIn: 5,
                bytesOut: 7
            )
        ])

        #expect(grouped.count == 2)
        #expect(grouped[0].application.displayName == "Acme Suite.app")
        #expect(grouped[0].cpuTicks == 65)
        #expect(grouped[0].memoryBytes == 190)
        #expect(grouped[0].networkBytes == 45)
        #expect(grouped[0].processCount == 2)
        #expect(grouped[1].application.displayName == "微信")
    }

    @Test("Top five sorting uses the requested metric kind and limits results")
    func sortsTopAppsByMetricKind() {
        let apps = [
            appSnapshot(name: "Gamma.app", cpuTicks: 10, memoryBytes: 300, bytesIn: 12, bytesOut: 8, processCount: 1),
            appSnapshot(name: "Beta.app", cpuTicks: 10, memoryBytes: 200, bytesIn: 15, bytesOut: 5, processCount: 1),
            appSnapshot(name: "Alpha.app", cpuTicks: 10, memoryBytes: 200, bytesIn: 20, bytesOut: 20, processCount: 1),
            appSnapshot(name: "Delta.app", cpuTicks: 8, memoryBytes: 500, bytesIn: 60, bytesOut: 40, processCount: 1),
            appSnapshot(name: "Zero.app", cpuTicks: 0, memoryBytes: 0, bytesIn: 0, bytesOut: 0, processCount: 1),
            appSnapshot(name: "Epsilon.app", cpuTicks: 3, memoryBytes: 1, bytesIn: 1, bytesOut: 1, processCount: 1)
        ]

        #expect(TopAppSorter.topFive(apps, for: .cpu).map(\.application.displayName) == ["Alpha.app", "Beta.app", "Gamma.app", "Delta.app", "Epsilon.app"])
        #expect(TopAppSorter.topFive(apps, for: .memory).map(\.application.displayName) == ["Delta.app", "Gamma.app", "Alpha.app", "Beta.app", "Epsilon.app"])
        #expect(TopAppSorter.topFive(apps, for: .network).map(\.application.displayName) == ["Delta.app", "Alpha.app", "Beta.app", "Gamma.app", "Epsilon.app"])
    }

    @Test("Top five filtering uses the selected metric's zero value")
    func filtersZeroRowsForTheSelectedMetric() {
        let apps = [
            appSnapshot(name: "CPU.app", cpuTicks: 4, memoryBytes: 0, bytesIn: 0, bytesOut: 0, processCount: 1),
            appSnapshot(name: "Memory.app", cpuTicks: 0, memoryBytes: 8, bytesIn: 0, bytesOut: 0, processCount: 1),
            appSnapshot(name: "Network.app", cpuTicks: 0, memoryBytes: 0, bytesIn: 3, bytesOut: 2, processCount: 1)
        ]

        #expect(TopAppSorter.topFive(apps, for: .cpu).map(\.application.displayName) == ["CPU.app"])
        #expect(TopAppSorter.topFive(apps, for: .memory).map(\.application.displayName) == ["Memory.app"])
        #expect(TopAppSorter.topFive(apps, for: .network).map(\.application.displayName) == ["Network.app"])
    }

    @Test("Grouping preserves zero snapshots until metric sorting")
    func groupingPreservesZeroSnapshots() {
        let grouped = AppMetricsAggregator.group([
            processSnapshot(
                pid: 55,
                startTime: 1_000,
                processName: "Idle",
                executablePath: "/Applications/Idle.app/Contents/MacOS/Idle",
                cpuTicks: 0,
                memoryBytes: 0,
                bytesIn: 0,
                bytesOut: 0
            )
        ])

        #expect(grouped.count == 1)
        #expect(grouped[0].processCount == 1)
        #expect(TopAppSorter.topFive(grouped, for: .cpu).isEmpty)
    }

    @Test("Top five ties use ascending application names")
    func breaksTopAppTiesByName() {
        let apps = [
            appSnapshot(name: "Zulu.app", cpuTicks: 9, memoryBytes: 1, bytesIn: 1, bytesOut: 1, processCount: 1),
            appSnapshot(name: "Alpha.app", cpuTicks: 9, memoryBytes: 1, bytesIn: 1, bytesOut: 1, processCount: 1),
            appSnapshot(name: "Middle.app", cpuTicks: 9, memoryBytes: 1, bytesIn: 1, bytesOut: 1, processCount: 1)
        ]

        #expect(TopAppSorter.topFive(apps, for: .cpu).map(\.application.displayName) == ["Alpha.app", "Middle.app", "Zulu.app"])
    }

    @Test("Metric formatting inputs compute rates and memory ratio")
    func computesMetricFormattingInputs() {
        let input = MetricFormattingInputBuilder.make(
            cpuTickDelta: 45,
            memoryBytes: 512,
            totalMemoryBytes: 2_048,
            bytesInDelta: 120,
            bytesOutDelta: 60,
            intervalSeconds: 4
        )

        #expect(input.memoryRatio == 0.25)
        #expect(input.cpuTicksPerSecond == 11.25)
        #expect(input.bytesInPerSecond == 30)
        #expect(input.bytesOutPerSecond == 15)
    }

    @Test("Metric formatting returns zeros when the denominator is missing")
    func handlesMissingFormattingDenominators() {
        let input = MetricFormattingInputBuilder.make(
            cpuTickDelta: 45,
            memoryBytes: 512,
            totalMemoryBytes: 0,
            bytesInDelta: 120,
            bytesOutDelta: 60,
            intervalSeconds: 0
        )

        #expect(input.memoryRatio == 0)
        #expect(input.cpuTicksPerSecond == 0)
        #expect(input.bytesInPerSecond == 0)
        #expect(input.bytesOutPerSecond == 0)
    }
}

private extension SystemMetricsModelsTests {
    func processSample(
        pid: UInt64,
        startTime: UInt64,
        processName: String,
        executablePath: String?,
        cpuTicks: UInt64,
        memoryBytes: UInt64,
        bytesIn: UInt64,
        bytesOut: UInt64
    ) -> ProcessMetricSample {
        .init(
            identity: .init(pid: pid, startTime: startTime),
            processName: processName,
            executablePath: executablePath,
            cpuTicks: cpuTicks,
            memoryBytes: memoryBytes,
            bytesIn: bytesIn,
            bytesOut: bytesOut
        )
    }

    func processSnapshot(
        pid: UInt64,
        startTime: UInt64,
        processName: String,
        executablePath: String?,
        cpuTicks: UInt64,
        memoryBytes: UInt64,
        bytesIn: UInt64,
        bytesOut: UInt64
    ) -> ProcessMetricSnapshot {
        let application = ApplicationIdentityResolver.resolve(
            processName: processName,
            executablePath: executablePath
        )

        return .init(
            identity: .init(pid: pid, startTime: startTime),
            application: application,
            processName: processName,
            cpuTicks: cpuTicks,
            memoryBytes: memoryBytes,
            bytesIn: bytesIn,
            bytesOut: bytesOut
        )
    }

    func appSnapshot(
        name: String,
        cpuTicks: UInt64,
        memoryBytes: UInt64,
        bytesIn: UInt64,
        bytesOut: UInt64,
        processCount: UInt64
    ) -> AppMetricSnapshot {
        .init(
            application: .init(displayName: name, bundleName: name),
            cpuTicks: cpuTicks,
            memoryBytes: memoryBytes,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            processCount: processCount
        )
    }
}
