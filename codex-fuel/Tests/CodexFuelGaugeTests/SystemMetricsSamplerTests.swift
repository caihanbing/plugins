import Foundation
import Testing
@testable import CodexFuelGauge

@Suite("System metrics sampler")
struct SystemMetricsSamplerTests {
    @Test("CPU percentage uses busy ticks over total ticks")
    func calculatesCPUPercentageFromTickDeltas() {
        let previous = CPUUsageSample(user: 20, system: 10, idle: 70, nice: 0)
        let current = CPUUsageSample(user: 50, system: 20, idle: 130, nice: 0)

        #expect(SystemMetricsCalculator.cpuPercent(previous: previous, current: current) == 40)
    }

    @Test("Memory ratio includes active wired and compressed pages")
    func calculatesMemoryRatio() {
        let sample = MemoryUsageSample(
            activePages: 2,
            wiredPages: 1,
            compressedPages: 1,
            physicalBytes: 8 * 4_096,
            pageSize: 4_096
        )

        #expect(SystemMetricsCalculator.memoryRatio(sample) == 0.5)
        #expect(SystemMetricsCalculator.memoryUsedBytes(sample) == 4 * 4_096)
    }

    @Test("Network rates use elapsed seconds for each direction")
    func calculatesNetworkRates() {
        let previous = InterfaceByteCounters(bytesIn: 100, bytesOut: 200)
        let current = InterfaceByteCounters(bytesIn: 1_100, bytesOut: 700)

        let rates = SystemMetricsCalculator.networkRates(
            previous: previous,
            current: current,
            elapsedSeconds: 2
        )

        #expect(rates.bytesInPerSecond == 500)
        #expect(rates.bytesOutPerSecond == 250)
    }

    @Test("Application metrics convert cumulative nanosecond CPU time to percent")
    func buildsApplicationMetricRates() {
        let app = AppMetricSnapshot(
            application: .init(displayName: "Codex.app", bundleName: "Codex.app"),
            cpuTicks: 200_000_000,
            memoryBytes: 2_048,
            bytesIn: 100,
            bytesOut: 300,
            processCount: 2
        )

        let metric = SystemMetricsCalculator.applicationMetric(app, elapsedSeconds: 2)

        #expect(metric.cpuPercent == 10)
        #expect(metric.memoryBytes == 2_048)
        #expect(metric.bytesInPerSecond == 50)
        #expect(metric.bytesOutPerSecond == 150)
    }

    @Test("Nettop interval deltas attach directly to native process snapshots")
    func attachesNettopIntervalDeltas() {
        let process = ProcessMetricSnapshot(
            identity: .init(pid: 42, startTime: 1_000),
            application: .init(displayName: "Codex.app", bundleName: "Codex.app"),
            processName: "Codex",
            cpuTicks: 100,
            memoryBytes: 2_048,
            bytesIn: 0,
            bytesOut: 0
        )
        let network = NettopNetworkSample(
            processToken: "Codex.42",
            processName: "Codex",
            pid: 42,
            bytesIn: 80,
            bytesOut: 20
        )

        let merged = SystemMetricsCalculator.attachingNetworkDeltas(
            to: [process],
            samplesByPID: [42: network]
        )

        #expect(merged.count == 1)
        #expect(merged[0].bytesIn == 80)
        #expect(merged[0].bytesOut == 20)
    }

    @Test("Nettop block framer waits for a repeated header and handles split input")
    func framesNettopBlocks() {
        var framer = NettopCSVBlockFramer()

        #expect(framer.append(Data(",bytes_in,bytes_out,\nCodex.1,10,20,\n".utf8)).isEmpty)

        let blocks = framer.append(Data(",bytes_in,bytes_out,\n微信.2,5,6,\n".utf8))

        #expect(blocks.count == 1)
        #expect(blocks[0].count == 1)
        #expect(blocks[0][0].processName == "Codex")
        #expect(blocks[0][0].bytesIn == 10)
    }

    @Test("Nettop block framer flushes the last block")
    func flushesLastNettopBlock() {
        var framer = NettopCSVBlockFramer()
        _ = framer.append(Data(",bytes_in,bytes_out,\nCodex.1,10,20,\n".utf8))

        let block = framer.finish()

        #expect(block?.count == 1)
        #expect(block?[0].bytesOut == 20)
    }

    @Test("Reconnect schedule caps at the final delay")
    func capsReconnectDelay() {
        let schedule = SystemMetricsReconnectSchedule()

        #expect(schedule.delay(forAttempt: 0) == 2)
        #expect(schedule.delay(forAttempt: 1) == 5)
        #expect(schedule.delay(forAttempt: 4) == 60)
        #expect(schedule.delay(forAttempt: 20) == 60)
    }

    @Test("Process sampling enumerates live processes without aborting")
    func enumeratesLiveProcessesWithoutStackCorruption() {
        let samples = DarwinMetricsProvider().processSamples()

        #expect(!samples.isEmpty)
    }
}
