import Foundation

protocol CodexAppServerClienting: AnyObject {
    var onSnapshot: ((RateLimitSnapshot) -> Void)? { get set }
    var onBucketUpdate: ((LimitBucket) -> Void)? { get set }
    var onConnected: (() -> Void)? { get set }
    var onDisconnected: ((String) -> Void)? { get set }

    func start(binaryURL: URL)
    func stop()
    func refresh()
}

final class CodexAppServerClient: CodexAppServerClienting {
    enum ClientError: LocalizedError {
        case notRunning
        case launchFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning:
                "Codex App Server 尚未连接"
            case let .launchFailed(message):
                "无法启动 Codex App Server：\(message)"
            case let .writeFailed(message):
                "无法向 Codex App Server 发送请求：\(message)"
            }
        }
    }

    var onSnapshot: ((RateLimitSnapshot) -> Void)?
    var onBucketUpdate: ((LimitBucket) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.codexfuelgauge.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var framer = JSONLFramer()
    private var nextRequestID = 1
    private var pendingRateLimitRequests = Set<Int>()
    private var intentionallyStopping = false

    func start(binaryURL: URL) {
        queue.async { [weak self] in
            self?.startOnQueue(binaryURL: binaryURL)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue(intentional: true)
        }
    }

    func refresh() {
        queue.async { [weak self] in
            self?.requestRateLimitsOnQueue()
        }
    }

    private func startOnQueue(binaryURL: URL) {
        stopOnQueue(intentional: true)
        intentionallyStopping = false
        framer = JSONLFramer()
        nextRequestID = 1
        pendingRateLimitRequests.removeAll()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = binaryURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
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
                let intentional = self.intentionallyStopping
                self.cleanupHandlesOnQueue()
                if !intentional {
                    self.onDisconnected?("Codex App Server 已断开（退出码 \(terminatedProcess.terminationStatus)）")
                }
            }
        }

        do {
            try process.run()
            self.process = process
            input = inputPipe.fileHandleForWriting
            output = outputPipe
            errorOutput = errorPipe
            try sendOnQueue([
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "codex_fuel_gauge",
                        "title": "Codex Fuel Gauge",
                        "version": "0.1.0",
                    ],
                ],
            ])
            try sendOnQueue(["method": "initialized", "params": [:]])
            requestRateLimitsOnQueue()
        } catch {
            stopOnQueue(intentional: false)
            onDisconnected?(ClientError.launchFailed(error.localizedDescription).localizedDescription)
        }
    }

    private func requestRateLimitsOnQueue() {
        guard process?.isRunning == true else {
            onDisconnected?(ClientError.notRunning.localizedDescription)
            return
        }

        let id = nextRequestID
        nextRequestID += 1
        pendingRateLimitRequests.insert(id)

        do {
            try sendOnQueue([
                "method": "account/rateLimits/read",
                "id": id,
            ])
        } catch {
            pendingRateLimitRequests.remove(id)
            stopOnQueue(intentional: false)
            onDisconnected?(ClientError.writeFailed(error.localizedDescription).localizedDescription)
            return
        }

        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.pendingRateLimitRequests.remove(id) != nil else { return }
            self.stopOnQueue(intentional: false)
            self.onDisconnected?("读取 Codex 额度超时")
        }
    }

    private func consumeOnQueue(_ data: Data) {
        for line in framer.append(data) {
            switch AppServerMessageParser.parse(line) {
            case .initialized:
                onConnected?()
            case let .rateLimitsResponse(id, result):
                pendingRateLimitRequests.remove(id)
                onSnapshot?(RateLimitSnapshot(result: result))
            case let .rateLimitsUpdated(bucket):
                onBucketUpdate?(bucket)
            case let .error(id, message):
                if let id { pendingRateLimitRequests.remove(id) }
                onDisconnected?(message)
            case .ignored:
                break
            }
        }
    }

    private func sendOnQueue(_ object: [String: Any]) throws {
        guard let input else { throw ClientError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func stopOnQueue(intentional: Bool) {
        intentionallyStopping = intentional
        guard let process else {
            cleanupHandlesOnQueue()
            return
        }
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        if process.isRunning {
            process.terminate()
        }
        cleanupHandlesOnQueue()
    }

    private func cleanupHandlesOnQueue() {
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        input = nil
        output = nil
        errorOutput = nil
        process = nil
        pendingRateLimitRequests.removeAll()
    }
}
