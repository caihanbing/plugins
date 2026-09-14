import AppKit
import Darwin
import Foundation

enum NetworkMonitorState: Equatable, Sendable {
    case warmingUp
    case live
    case stale
    case unavailable(String)

    var message: String {
        switch self {
        case .warmingUp: "网络采样中…"
        case .live: "网络实时"
        case .stale: "网络数据已过期"
        case let .unavailable(message): message
        }
    }
}

struct SystemApplicationMetric: Identifiable, Equatable, Sendable {
    let application: ApplicationIdentity
    let cpuPercent: Double
    let memoryBytes: UInt64
    let bytesInPerSecond: Double
    let bytesOutPerSecond: Double

    var id: String { application.stableID }
    var networkBytesPerSecond: Double { bytesInPerSecond + bytesOutPerSecond }
}

struct SystemMetricsSnapshot: Equatable, Sendable {
    let receivedAt: Date
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64?
    let memoryTotalBytes: UInt64
    let bytesInPerSecond: Double?
    let bytesOutPerSecond: Double?
    let topCPU: [SystemApplicationMetric]
    let topMemory: [SystemApplicationMetric]
    let topNetwork: [SystemApplicationMetric]
    let networkState: NetworkMonitorState
}

protocol SystemMetricsSampling: AnyObject {
    var onSnapshot: ((SystemMetricsSnapshot) -> Void)? { get set }

    func start(interval: TimeInterval)
    func setInterval(_ interval: TimeInterval)
    func stop()
}

struct CPUUsageSample: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 { user + system + idle + nice }
    var busy: UInt64 { user + system + nice }
}

struct MemoryUsageSample: Equatable, Sendable {
    let activePages: UInt64
    let wiredPages: UInt64
    let compressedPages: UInt64
    let physicalBytes: UInt64
    let pageSize: UInt64
}

struct InterfaceByteCounters: Equatable, Sendable {
    let bytesIn: UInt64
    let bytesOut: UInt64
}

struct NetworkRates: Equatable, Sendable {
    let bytesInPerSecond: Double
    let bytesOutPerSecond: Double
}

enum SystemMetricsCalculator {
    static func cpuPercent(previous: CPUUsageSample, current: CPUUsageSample) -> Double {
        guard current.total >= previous.total, current.busy >= previous.busy else { return 0 }
        let totalDelta = current.total - previous.total
        guard totalDelta > 0 else { return 0 }
        let busyDelta = current.busy - previous.busy
        return min(100, max(0, Double(busyDelta) / Double(totalDelta) * 100))
    }

    static func memoryUsedBytes(_ sample: MemoryUsageSample) -> UInt64 {
        (sample.activePages + sample.wiredPages + sample.compressedPages) * sample.pageSize
    }

    static func memoryRatio(_ sample: MemoryUsageSample) -> Double {
        guard sample.physicalBytes > 0 else { return 0 }
        return min(1, Double(memoryUsedBytes(sample)) / Double(sample.physicalBytes))
    }

    static func networkRates(
        previous: InterfaceByteCounters,
        current: InterfaceByteCounters,
        elapsedSeconds: Double
    ) -> NetworkRates {
        guard
            elapsedSeconds > 0,
            current.bytesIn >= previous.bytesIn,
            current.bytesOut >= previous.bytesOut
        else {
            return NetworkRates(bytesInPerSecond: 0, bytesOutPerSecond: 0)
        }

        return NetworkRates(
            bytesInPerSecond: Double(current.bytesIn - previous.bytesIn) / elapsedSeconds,
            bytesOutPerSecond: Double(current.bytesOut - previous.bytesOut) / elapsedSeconds
        )
    }

    static func applicationMetric(_ app: AppMetricSnapshot, elapsedSeconds: Double) -> SystemApplicationMetric {
        let safeElapsed = max(elapsedSeconds, 0.001)
        return SystemApplicationMetric(
            application: app.application,
            cpuPercent: max(0, Double(app.cpuTicks) / (safeElapsed * 1_000_000_000) * 100),
            memoryBytes: app.memoryBytes,
            bytesInPerSecond: Double(app.bytesIn) / safeElapsed,
            bytesOutPerSecond: Double(app.bytesOut) / safeElapsed
        )
    }

    static func applicationMetrics(
        _ apps: [AppMetricSnapshot],
        elapsedSeconds: Double
    ) -> [SystemApplicationMetric] {
        apps.map { applicationMetric($0, elapsedSeconds: elapsedSeconds) }
    }

    static func attachingNetworkDeltas(
        to processes: [ProcessMetricSnapshot],
        samplesByPID: [UInt64: NettopNetworkSample]
    ) -> [ProcessMetricSnapshot] {
        processes.map { process in
            guard let network = samplesByPID[process.identity.pid] else {
                return process
            }

            return ProcessMetricSnapshot(
                identity: process.identity,
                application: process.application,
                processName: process.processName,
                cpuTicks: process.cpuTicks,
                memoryBytes: process.memoryBytes,
                bytesIn: network.bytesIn,
                bytesOut: network.bytesOut
            )
        }
    }
}

struct SystemMetricsReconnectSchedule: Sendable {
    private let delays: [TimeInterval] = [2, 5, 15, 30, 60]

    func delay(forAttempt attempt: Int) -> TimeInterval {
        delays[min(max(0, attempt), delays.count - 1)]
    }
}

protocol NativeMetricsProviding: AnyObject {
    var logicalProcessorCount: Int { get }

    func cpuUsageSample() -> CPUUsageSample?
    func memoryUsageSample() -> MemoryUsageSample?
    func interfaceByteCounters() -> InterfaceByteCounters?
    func processSamples() -> [ProcessMetricSample]
}

final class DarwinMetricsProvider: NativeMetricsProviding {
    let logicalProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    func cpuUsageSample() -> CPUUsageSample? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = withUnsafeBytes(of: info.cpu_ticks) { rawBuffer in
            Array(rawBuffer.bindMemory(to: UInt32.self))
        }
        guard ticks.count > CPU_STATE_NICE else { return nil }
        return CPUUsageSample(
            user: UInt64(ticks[Int(CPU_STATE_USER)]),
            system: UInt64(ticks[Int(CPU_STATE_SYSTEM)]),
            idle: UInt64(ticks[Int(CPU_STATE_IDLE)]),
            nice: UInt64(ticks[Int(CPU_STATE_NICE)])
        )
    }

    func memoryUsageSample() -> MemoryUsageSample? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return MemoryUsageSample(
            activePages: UInt64(info.active_count),
            wiredPages: UInt64(info.wire_count),
            compressedPages: UInt64(info.compressor_page_count),
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            pageSize: UInt64(vm_kernel_page_size)
        )
    }

    func interfaceByteCounters() -> InterfaceByteCounters? {
        var mib: [Int32] = [
            Int32(CTL_NET),
            Int32(PF_ROUTE),
            0,
            0,
            Int32(NET_RT_IFLIST2),
            0,
        ]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        var data = [UInt8](repeating: 0, count: length)
        let result = data.withUnsafeMutableBytes { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0)
        }
        guard result == 0 else { return nil }

        var offset = 0
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        let headerSize = MemoryLayout<if_msghdr2>.size
        // The route dump interleaves interface records with shorter address
        // records, so read only the common length/type prefix before loading
        // an if_msghdr2 payload.
        let messageTypeOffset = MemoryLayout<UInt16>.size + MemoryLayout<UInt8>.size
        let minimumMessageSize = messageTypeOffset + MemoryLayout<UInt8>.size

        while offset + minimumMessageSize <= length {
            let messageLength: Int = data.withUnsafeBytes { rawBuffer in
                Int(rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
            let messageType = data[offset + messageTypeOffset]
            guard messageLength >= minimumMessageSize, offset + messageLength <= length else { break }

            if messageType == UInt8(RTM_IFINFO2), messageLength >= headerSize {
                let header: if_msghdr2 = data.withUnsafeBytes { rawBuffer in
                    rawBuffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                }
                if header.ifm_flags & Int32(IFF_UP) != 0,
                   header.ifm_flags & Int32(IFF_LOOPBACK) == 0
                {
                    bytesIn += header.ifm_data.ifi_ibytes
                    bytesOut += header.ifm_data.ifi_obytes
                }
            }
            offset += messageLength
        }

        return InterfaceByteCounters(bytesIn: bytesIn, bytesOut: bytesOut)
    }

    func processSamples() -> [ProcessMetricSample] {
        let requestedBytes = proc_listallpids(nil, 0)
        guard requestedBytes > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(requestedBytes) / MemoryLayout<pid_t>.size + 1)
        let returnedBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedBytes > 0 else { return [] }

        let count = min(Int(returnedBytes) / MemoryLayout<pid_t>.size, pids.count)
        var samples: [ProcessMetricSample] = []
        samples.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_taskallinfo()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(
                    pid,
                    PROC_PIDTASKALLINFO,
                    0,
                    pointer,
                    Int32(MemoryLayout<proc_taskallinfo>.size)
                )
            }
            guard result == Int32(MemoryLayout<proc_taskallinfo>.size) else { continue }

            let identity = ProcessIdentity(
                pid: UInt64(pid),
                startTime: UInt64(info.pbsd.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbsd.pbi_start_tvusec)
            )
            let processName = processName(for: pid)
            let executablePath = executablePath(for: pid)
            let memoryBytes = UInt64(info.ptinfo.pti_resident_size)

            samples.append(ProcessMetricSample(
                identity: identity,
                processName: processName,
                executablePath: executablePath,
                cpuTicks: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system,
                memoryBytes: memoryBytes,
                bytesIn: 0,
                bytesOut: 0
            ))
        }
        return samples
    }

    private func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_name(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return "进程 \(pid)" }
        return String(cString: buffer)
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

}

final class SystemMetricsSampler: SystemMetricsSampling {
    var onSnapshot: ((SystemMetricsSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.codexfuelgauge.system-metrics")
    private let provider: NativeMetricsProviding
    private let netTop: NetTopStreaming
    private let reconnectSchedule = SystemMetricsReconnectSchedule()
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 1
    private var running = false
    private var lastTick: UInt64?
    private var lastCPU: CPUUsageSample?
    private var lastMemory: MemoryUsageSample?
    private var lastInterfaces: InterfaceByteCounters?
    private var timeline = ProcessMetricsTimeline()
    private var latestNetworkByPID: [UInt64: NettopNetworkSample] = [:]
    private var lastNetTopAt: Date?
    private var networkState: NetworkMonitorState = .warmingUp
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var wakeObserver: NSObjectProtocol?

    init(
        provider: NativeMetricsProviding = DarwinMetricsProvider(),
        netTop: NetTopStreaming = NetTopClient()
    ) {
        self.provider = provider
        self.netTop = netTop
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                self?.resetBaselines()
            }
        }
        configureNetTopCallbacks()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start(interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.interval = max(1, interval)
            self.running = true
            self.resetBaselines()
            self.netTop.start(interval: self.interval)
            self.startTimer()
        }
    }

    func setInterval(_ interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let nextInterval = max(1, interval)
            guard nextInterval != self.interval else { return }
            self.interval = nextInterval
            self.startTimer()
            self.netTop.setInterval(nextInterval)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.netTop.stop()
            self.resetBaselines()
        }
    }

    private func configureNetTopCallbacks() {
        netTop.onSamples = { [weak self] samples in
            self?.queue.async {
                guard let self else { return }
                var nextNetworkByPID: [UInt64: NettopNetworkSample] = [:]
                nextNetworkByPID.reserveCapacity(samples.count)
                for sample in samples {
                    guard let pid = sample.pid else { continue }
                    nextNetworkByPID[pid] = sample
                }
                self.latestNetworkByPID = nextNetworkByPID
                self.lastNetTopAt = Date()
                self.networkState = .live
                self.reconnectAttempt = 0
                self.reconnectWorkItem?.cancel()
                self.reconnectWorkItem = nil
            }
        }
        netTop.onDisconnected = { [weak self] message in
            self?.queue.async {
                guard let self, self.running else { return }
                self.networkState = .unavailable(message)
                self.scheduleNetTopReconnect()
            }
        }
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sampleOnQueue()
        }
        self.timer = timer
        timer.resume()
    }

    private func sampleOnQueue() {
        guard running else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedSeconds: Double
        if let lastTick {
            elapsedSeconds = max(Double(now - lastTick) / 1_000_000_000, 0.001)
        } else {
            elapsedSeconds = interval
        }
        lastTick = now

        let currentCPU = provider.cpuUsageSample()
        let cpuPercent: Double?
        if let previous = lastCPU, let currentCPU {
            cpuPercent = currentCPU.total >= previous.total
                ? SystemMetricsCalculator.cpuPercent(previous: previous, current: currentCPU)
                : nil
        } else {
            cpuPercent = nil
        }
        lastCPU = currentCPU

        let currentMemory = provider.memoryUsageSample()
        let memoryUsed = currentMemory.map(SystemMetricsCalculator.memoryUsedBytes)
        let memoryTotal = currentMemory?.physicalBytes ?? lastMemory?.physicalBytes ?? 0
        lastMemory = currentMemory

        let currentInterfaces = provider.interfaceByteCounters()
        let rates: NetworkRates?
        if let previous = lastInterfaces, let currentInterfaces {
            rates = currentInterfaces.bytesIn >= previous.bytesIn && currentInterfaces.bytesOut >= previous.bytesOut
                ? SystemMetricsCalculator.networkRates(previous: previous, current: currentInterfaces, elapsedSeconds: elapsedSeconds)
                : nil
        } else {
            rates = nil
        }
        lastInterfaces = currentInterfaces

        let nativeSamples = provider.processSamples()
        let processSnapshots = timeline.ingest(nativeSamples)
        let networkSnapshots = SystemMetricsCalculator.attachingNetworkDeltas(
            to: processSnapshots,
            samplesByPID: latestNetworkByPID
        )
        let appSnapshots = AppMetricsAggregator.group(networkSnapshots)
        let appMetrics = SystemMetricsCalculator.applicationMetrics(appSnapshots, elapsedSeconds: elapsedSeconds)
        let metricsByID = Dictionary(uniqueKeysWithValues: appMetrics.map { ($0.id, $0) })

        func top(_ kind: SystemMetricKind) -> [SystemApplicationMetric] {
            TopAppSorter.topFive(appSnapshots, for: kind).compactMap { metricsByID[$0.application.stableID] }
        }

        if let lastNetTopAt, Date().timeIntervalSince(lastNetTopAt) > interval * 2 {
            networkState = .stale
        }

        onSnapshot?(SystemMetricsSnapshot(
            receivedAt: Date(),
            cpuPercent: cpuPercent,
            memoryUsedBytes: memoryUsed,
            memoryTotalBytes: memoryTotal,
            bytesInPerSecond: rates?.bytesInPerSecond,
            bytesOutPerSecond: rates?.bytesOutPerSecond,
            topCPU: top(.cpu),
            topMemory: top(.memory),
            topNetwork: top(.network),
            networkState: networkState
        ))
    }

    private func scheduleNetTopReconnect() {
        guard running, reconnectWorkItem == nil else { return }
        let delay = reconnectSchedule.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.networkState = .warmingUp
            self.timeline = ProcessMetricsTimeline()
            self.latestNetworkByPID.removeAll()
            self.lastNetTopAt = nil
            self.netTop.start(interval: self.interval)
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func resetBaselines() {
        lastTick = nil
        lastCPU = nil
        lastMemory = nil
        lastInterfaces = nil
        timeline = ProcessMetricsTimeline()
        latestNetworkByPID.removeAll()
        lastNetTopAt = nil
        networkState = .warmingUp
    }
}
