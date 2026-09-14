import Foundation

struct JSONLFramer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newlineIndex]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(...newlineIndex)
        }
        return lines
    }

    mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll(keepingCapacity: false) }
        return buffer
    }
}
