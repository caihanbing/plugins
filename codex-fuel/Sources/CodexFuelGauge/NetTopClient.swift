import Foundation

protocol NetTopStreaming: AnyObject {
    var onSamples: (([NettopNetworkSample]) -> Void)? { get set }
    var onDisconnected: ((String) -> Void)? { get set }

    func start(interval: TimeInterval)
    func setInterval(_ interval: TimeInterval)
    func stop()
}

struct NettopCSVBlockFramer {
    private var buffer = Data()
    private var currentLines: [String] = []

    mutating func append(_ data: Data) -> [[NettopNetworkSample]] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var blocks: [[NettopNetworkSample]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newline]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            buffer.removeSubrange(...newline)
            consume(String(decoding: line, as: UTF8.self), blocks: &blocks)
        }
        return blocks
    }

    mutating func finish() -> [NettopNetworkSample]? {
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: false)
            var ignoredBlocks: [[NettopNetworkSample]] = []
            consume(line, blocks: &ignoredBlocks)
        }

        guard !currentLines.isEmpty else { return nil }
        defer { currentLines.removeAll(keepingCapacity: false) }
        return NettopCSVParser.parse(currentLines.joined(separator: "\n"))
    }

    private mutating func consume(_ line: String, blocks: inout [[NettopNetworkSample]]) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isHeader(trimmed) {
            if !currentLines.isEmpty {
                blocks.append(NettopCSVParser.parse(currentLines.joined(separator: "\n")))
            }
            currentLines = [trimmed]
        } else if !currentLines.isEmpty {
            currentLines.append(trimmed)
        }
    }

    private func isHeader(_ line: String) -> Bool {
        let normalized = line.lowercased()
        return normalized.contains("bytes_in") && normalized.contains("bytes_out")
    }
}

final class NetTopClient: NetTopStreaming {
    var onSamples: (([NettopNetworkSample]) -> Void)?
    var onDisconnected: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.codexfuelgauge.net-top")
    private var process: Process?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var framer = NettopCSVBlockFramer()
    private var interval: TimeInterval = 1
    private var intentionallyStopping = false
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/nettop")) {
        self.executableURL = executableURL
    }

    func start(interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.interval = max(1, interval)
            self.startOnQueue()
        }
    }

    func setInterval(_ interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let nextInterval = max(1, interval)
            guard self.interval != nextInterval else { return }
            self.interval = nextInterval
            guard self.process != nil else { return }
            self.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue(intentional: true)
        }
    }

    private func startOnQueue() {
        stopOnQueue(intentional: true)
        intentionallyStopping = false
        framer = NettopCSVBlockFramer()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "-P",
            "-L", "1",
            "-d",
            "-x",
            "-n",
            "-s", String(format: "%.0f", interval),
            "-J", "bytes_in,bytes_out",
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consumeOnQueue(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async {
                guard let self, self.process === terminatedProcess else { return }
                if let finalBlock = self.framer.finish(), !finalBlock.isEmpty {
                    self.onSamples?(finalBlock)
                }
                let intentional = self.intentionallyStopping
                self.cleanupOnQueue()
                if !intentional {
                    if terminatedProcess.terminationStatus == 0 {
                        self.queue.asyncAfter(deadline: .now() + max(0.05, self.interval)) { [weak self] in
                            guard let self, !self.intentionallyStopping else { return }
                            self.startOnQueue()
                        }
                    } else {
                        self.onDisconnected?("nettop 已退出（退出码 \(terminatedProcess.terminationStatus)）")
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            output = outputPipe
            errorOutput = errorPipe
        } catch {
            cleanupOnQueue()
            onDisconnected?("无法启动 nettop：\(error.localizedDescription)")
        }
    }

    private func consumeOnQueue(_ data: Data) {
        for block in framer.append(data) where !block.isEmpty {
            onSamples?(block)
        }
    }

    private func stopOnQueue(intentional: Bool) {
        intentionallyStopping = intentional
        guard let process else {
            cleanupOnQueue()
            return
        }

        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        cleanupOnQueue()
    }

    private func cleanupOnQueue() {
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        try? errorOutput?.fileHandleForReading.close()
        output = nil
        errorOutput = nil
        process = nil
    }
}
