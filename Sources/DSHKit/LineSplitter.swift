import Foundation

/// Splits a byte stream into newline-delimited frames (the SDK transport framing).
/// Pure value type so the framing rules are unit-testable without a process.
public struct LineSplitter: Sendable {
    private var buffer = Data()
    /// Frames larger than this are dropped instead of growing memory without bound.
    public let maxFrameBytes: Int

    public init(maxFrameBytes: Int = 64 * 1024 * 1024) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Appends bytes and returns every complete, non-empty line (without the newline).
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }   // tolerate CRLF
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > maxFrameBytes { buffer.removeAll(keepingCapacity: false) }
        return lines
    }
}
