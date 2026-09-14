import Foundation

enum SystemMetricKind: String, CaseIterable, Codable, Sendable {
    case cpu
    case memory
    case network
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: UInt64
    let startTime: UInt64
}

struct ApplicationIdentity: Hashable, Sendable {
    let displayName: String
    let bundleName: String?
    let bundleURL: URL?

    init(displayName: String, bundleName: String?, bundleURL: URL? = nil) {
        self.displayName = displayName
        self.bundleName = bundleName
        self.bundleURL = bundleURL
    }

    var stableID: String {
        if let bundleName, !bundleName.isEmpty {
            return "bundle:\(bundleName)"
        }
        return "process:\(displayName)"
    }
}

enum ApplicationIdentityResolver {
    static func resolve(processName: String, executablePath: String?) -> ApplicationIdentity {
        if let executablePath, !executablePath.isEmpty {
            let components = executablePath.split(separator: "/").map(String.init)
            if let bundleIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                let outermostBundle = components[bundleIndex]
                let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
                return ApplicationIdentity(
                    displayName: outermostBundle,
                    bundleName: outermostBundle,
                    bundleURL: URL(fileURLWithPath: bundlePath)
                )
            }
        }

        return ApplicationIdentity(displayName: processName, bundleName: nil)
    }
}

struct ProcessMetricSample: Equatable, Sendable {
    let identity: ProcessIdentity
    let processName: String
    let executablePath: String?
    let application: ApplicationIdentity
    let cpuTicks: UInt64
    let memoryBytes: UInt64
    let bytesIn: UInt64
    let bytesOut: UInt64

    init(
        identity: ProcessIdentity,
        processName: String,
        executablePath: String?,
        cpuTicks: UInt64,
        memoryBytes: UInt64,
        bytesIn: UInt64,
        bytesOut: UInt64
    ) {
        self.identity = identity
        self.processName = processName
        self.executablePath = executablePath
        self.application = ApplicationIdentityResolver.resolve(
            processName: processName,
            executablePath: executablePath
        )
        self.cpuTicks = cpuTicks
        self.memoryBytes = memoryBytes
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

struct ProcessMetricSnapshot: Equatable, Sendable {
    let identity: ProcessIdentity
    let application: ApplicationIdentity
    let processName: String
    let cpuTicks: UInt64
    let memoryBytes: UInt64
    let bytesIn: UInt64
    let bytesOut: UInt64

    var networkBytes: UInt64 { bytesIn + bytesOut }
}

struct AppMetricSnapshot: Equatable, Sendable {
    let application: ApplicationIdentity
    let cpuTicks: UInt64
    let memoryBytes: UInt64
    let bytesIn: UInt64
    let bytesOut: UInt64
    let processCount: UInt64

    var networkBytes: UInt64 { bytesIn + bytesOut }
}

struct NettopNetworkSample: Equatable, Sendable {
    let processToken: String
    let processName: String
    let pid: UInt64?
    let bytesIn: UInt64
    let bytesOut: UInt64
}

struct MetricFormattingInput: Equatable, Sendable {
    let cpuTicksPerSecond: Double
    let memoryRatio: Double
    let bytesInPerSecond: Double
    let bytesOutPerSecond: Double
}

enum MetricFormattingInputBuilder {
    static func make(
        cpuTickDelta: UInt64,
        memoryBytes: UInt64,
        totalMemoryBytes: UInt64,
        bytesInDelta: UInt64,
        bytesOutDelta: UInt64,
        intervalSeconds: Double
    ) -> MetricFormattingInput {
        guard intervalSeconds > 0 else {
            return MetricFormattingInput(
                cpuTicksPerSecond: 0,
                memoryRatio: memoryRatio(memoryBytes: memoryBytes, totalMemoryBytes: totalMemoryBytes),
                bytesInPerSecond: 0,
                bytesOutPerSecond: 0
            )
        }

        return MetricFormattingInput(
            cpuTicksPerSecond: Double(cpuTickDelta) / intervalSeconds,
            memoryRatio: memoryRatio(memoryBytes: memoryBytes, totalMemoryBytes: totalMemoryBytes),
            bytesInPerSecond: Double(bytesInDelta) / intervalSeconds,
            bytesOutPerSecond: Double(bytesOutDelta) / intervalSeconds
        )
    }

    static func memoryRatio(memoryBytes: UInt64, totalMemoryBytes: UInt64) -> Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return min(1, Double(memoryBytes) / Double(totalMemoryBytes))
    }
}

struct ProcessMetricsTimeline {
    private var lastByIdentity: [ProcessIdentity: ProcessMetricSample] = [:]

    mutating func ingest(_ samples: [ProcessMetricSample]) -> [ProcessMetricSnapshot] {
        var snapshots: [ProcessMetricSnapshot] = []
        snapshots.reserveCapacity(samples.count)

        for sample in samples {
            guard let previous = lastByIdentity[sample.identity] else {
                lastByIdentity[sample.identity] = sample
                continue
            }

            guard
                sample.cpuTicks >= previous.cpuTicks,
                sample.bytesIn >= previous.bytesIn,
                sample.bytesOut >= previous.bytesOut
            else {
                lastByIdentity[sample.identity] = sample
                continue
            }

            snapshots.append(ProcessMetricSnapshot(
                identity: sample.identity,
                application: sample.application,
                processName: sample.processName,
                cpuTicks: sample.cpuTicks - previous.cpuTicks,
                memoryBytes: sample.memoryBytes,
                bytesIn: sample.bytesIn - previous.bytesIn,
                bytesOut: sample.bytesOut - previous.bytesOut
            ))
            lastByIdentity[sample.identity] = sample
        }

        return snapshots
    }
}

enum AppMetricsAggregator {
    static func group(_ processSnapshots: [ProcessMetricSnapshot]) -> [AppMetricSnapshot] {
        struct Bucket {
            let application: ApplicationIdentity
            var cpuTicks: UInt64 = 0
            var memoryBytes: UInt64 = 0
            var bytesIn: UInt64 = 0
            var bytesOut: UInt64 = 0
            var processCount: UInt64 = 0
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        for snapshot in processSnapshots {
            let key = snapshot.application.stableID
            if buckets[key] == nil {
                buckets[key] = Bucket(application: snapshot.application)
                order.append(key)
            }

            guard var bucket = buckets[key] else { continue }
            bucket.cpuTicks += snapshot.cpuTicks
            bucket.memoryBytes += snapshot.memoryBytes
            bucket.bytesIn += snapshot.bytesIn
            bucket.bytesOut += snapshot.bytesOut
            bucket.processCount += 1
            buckets[key] = bucket
        }

        return order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return AppMetricSnapshot(
                application: bucket.application,
                cpuTicks: bucket.cpuTicks,
                memoryBytes: bucket.memoryBytes,
                bytesIn: bucket.bytesIn,
                bytesOut: bucket.bytesOut,
                processCount: bucket.processCount
            )
        }
    }
}

enum TopAppSorter {
    static func topFive(_ apps: [AppMetricSnapshot], for kind: SystemMetricKind) -> [AppMetricSnapshot] {
        apps
            .filter { metricValue(for: $0, kind: kind) > 0 }
            .sorted { lhs, rhs in
                let lhsValue = metricValue(for: lhs, kind: kind)
                let rhsValue = metricValue(for: rhs, kind: kind)
                if lhsValue != rhsValue { return lhsValue > rhsValue }
                if lhs.application.displayName != rhs.application.displayName {
                    return lhs.application.displayName < rhs.application.displayName
                }
                return lhs.application.stableID < rhs.application.stableID
            }
            .prefix(5)
            .map { $0 }
    }

    private static func metricValue(for app: AppMetricSnapshot, kind: SystemMetricKind) -> UInt64 {
        switch kind {
        case .cpu: app.cpuTicks
        case .memory: app.memoryBytes
        case .network: app.networkBytes
        }
    }
}

enum NettopCSVParser {
    static func parse(_ csv: String) -> [NettopNetworkSample] {
        let lines = csv
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else { return [] }
        let header = parseCSVLine(firstLine)
        let normalizedHeader = header.map(normalizedColumnName)
        guard let bytesInIndex = normalizedHeader.firstIndex(of: "bytes_in"),
              let bytesOutIndex = normalizedHeader.firstIndex(of: "bytes_out")
        else { return [] }

        let processIndex = normalizedHeader.firstIndex(of: "process") ?? 0
        let minimumFieldCount = max(processIndex, max(bytesInIndex, bytesOutIndex)) + 1

        return lines.dropFirst().compactMap { line in
            let fields = parseCSVLine(line)
            guard fields.count >= minimumFieldCount else { return nil }
            guard normalizedRow(fields) != normalizedHeader else { return nil }

            let processToken = fields[processIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !processToken.isEmpty,
                  let bytesIn = UInt64(fields[bytesInIndex].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let bytesOut = UInt64(fields[bytesOutIndex].trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }

            let identity = splitProcessToken(processToken)
            return NettopNetworkSample(
                processToken: processToken,
                processName: identity.name,
                pid: identity.pid,
                bytesIn: bytesIn,
                bytesOut: bytesOut
            )
        }
    }

    private static func splitProcessToken(_ token: String) -> (name: String, pid: UInt64?) {
        guard let separator = token.lastIndex(of: ".") else {
            return (token, nil)
        }

        let possiblePID = token[token.index(after: separator)...]
        guard !possiblePID.isEmpty, possiblePID.allSatisfy(\.isNumber), let pid = UInt64(possiblePID) else {
            return (token, nil)
        }

        let name = token[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? token : String(name), pid)
    }

    private static func normalizedRow(_ fields: [String]) -> [String] {
        fields.map(normalizedColumnName)
    }

    private static func normalizedColumnName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var index = line.startIndex
        var insideQuotes = false

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let nextIndex = line.index(after: index)
                if insideQuotes, nextIndex < line.endIndex, line[nextIndex] == "\"" {
                    current.append("\"")
                    index = nextIndex
                } else {
                    insideQuotes.toggle()
                }
            } else if character == "," && !insideQuotes {
                fields.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }

        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
