import Foundation

/// The real transport: newline-delimited JSON on a pair of file descriptors.
///
/// Writes go to a descriptor the caller hands in rather than to `FileHandle.standardOutput`,
/// because `MCPCommand` duplicates the real stdout and then points fd 1 at stderr — after that
/// the only way to reach the client is the duplicate (#89: stdout *is* the protocol).
///
/// `@unchecked Sendable`: the buffer is touched only from the single read loop in
/// `MCPServer.serve`, which is the one caller.
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    /// Enough for one MCP request; the reader grows past it by looping, this is only the
    /// per-`read` chunk.
    private static let chunkSize = 64 * 1024

    private let input: Int32
    private let output: Int32
    private var buffer = Data()
    private var reachedEnd = false

    public init(input: Int32 = STDIN_FILENO, output: Int32) {
        self.input = input
        self.output = output
    }

    public func readLine() throws -> String? {
        while true {
            if let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                return String(decoding: line, as: UTF8.self)
            }
            if reachedEnd {
                // A last line with no trailing newline is still a request — `printf` without \n
                // is exactly how the acceptance check in #89 is run by hand.
                guard !buffer.isEmpty else { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return line
            }
            try fill()
        }
    }

    public func write(_ line: String) throws {
        var data = Data(line.utf8)
        data.append(UInt8(ascii: "\n"))
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw MCPTransportError.write(String(cString: strerror(errno)))
            }
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, Self.chunkSize) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                return
            }
            if count == 0 {
                reachedEnd = true
                return
            }
            if errno == EINTR { continue }
            throw MCPTransportError.read(String(cString: strerror(errno)))
        }
    }
}

public enum MCPTransportError: Error, CustomStringConvertible {
    case read(String)
    case write(String)

    public var description: String {
        switch self {
        case let .read(detail): "reading stdin failed: \(detail)"
        case let .write(detail): "writing stdout failed: \(detail)"
        }
    }
}
