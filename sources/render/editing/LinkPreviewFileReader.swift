import Foundation

enum LinkPreviewFileReader {
    static let readLimit = 1 << 20
    static let scanLimit = 8 << 20
    static let displayLimit = 16 << 10
    private static let chunkSize = 64 << 10
    private static let selectedByteLimit = 64 << 10

    enum Result: Sendable {
        case text(String)
        case tooLarge
        case notUTF8
        case linesUnavailable
    }

    nonisolated static func read(_ url: URL, lines: LinkPreviewLineRange?) throws -> Result {
        if lines == nil {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= readLimit else { return .tooLarge }
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: readLimit) ?? Data()
            try Task.checkCancellation()
            guard !data.prefix(4 << 10).contains(0), let text = String(data: data, encoding: .utf8) else { return .notUTF8 }
            return .text(String(text.prefix(displayLimit)))
        }

        let lines = lines!
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var scanned = 0
        var line = 1
        var skipFollowingLF = false
        var foundStart = false
        var selectedBytes = Data()
        var selectedLineWasTruncated = false
        var output = ""

        func finishLine(partial: Bool = false) -> Result? {
            guard line >= lines.start, line <= lines.end else { return nil }
            foundStart = true
            let truncated = partial || selectedLineWasTruncated
            let text: String
            if truncated {
                guard let decoded = LinkPreviewText.decodeUTF8(selectedBytes) else { return .notUTF8 }
                text = decoded
            } else {
                guard let decoded = String(data: selectedBytes, encoding: .utf8) else { return .notUTF8 }
                text = decoded
            }
            let separator = output.isEmpty ? "" : "\n"
            let marked = "\(line)  \(text)"
            let piece = separator + marked
            let remaining = displayLimit - output.count
            output += String(piece.prefix(max(0, remaining)))
            if truncated || piece.count >= remaining { return .text(output) }
            return nil
        }

        func nextLine() {
            line += 1
            selectedBytes.removeAll(keepingCapacity: true)
            selectedLineWasTruncated = false
        }

        while scanned < scanLimit {
            try Task.checkCancellation()
            let count = min(chunkSize, scanLimit - scanned)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                if let result = finishLine() { return result }
                return foundStart ? .text(output) : .linesUnavailable
            }
            scanned += chunk.count
            for byte in chunk {
                if skipFollowingLF {
                    skipFollowingLF = false
                    if byte == 0x0A { continue }
                }
                if byte == 0x0A || byte == 0x0D {
                    if let result = finishLine() { return result }
                    if line >= lines.end { return .text(output) }
                    nextLine()
                    skipFollowingLF = byte == 0x0D
                    continue
                }
                guard line >= lines.start, line <= lines.end else { continue }
                if selectedBytes.count == selectedByteLimit {
                    selectedLineWasTruncated = true
                    if let result = finishLine() { return result }
                } else {
                    selectedBytes.append(byte)
                }
            }
            try Task.checkCancellation()
        }

        if line >= lines.start, line <= lines.end, let result = finishLine(partial: true) { return result }
        return foundStart ? .text(output) : .linesUnavailable
    }
}
