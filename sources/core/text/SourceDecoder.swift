import Foundation

/// Line-ending style detected in the original bytes.
public enum LineEnding: String, Sendable {
    case lf, crlf, cr, mixed, none
}

/// Everything about the original bytes that the decoded text does not carry.
public struct SourceEncoding: Sendable, Equatable {
    public var hasBOM: Bool
    /// Invalid UTF-8 is decoded lossily for display and must stay read-only (design §5).
    public var isValidUTF8: Bool
    public var lineEnding: LineEnding
    /// What a newly typed line break inserts, so edits keep the file's dominant style.
    public var newline: String

    public init(hasBOM: Bool, isValidUTF8: Bool, lineEnding: LineEnding, newline: String = "\n") {
        self.hasBOM = hasBOM
        self.isValidUTF8 = isValidUTF8
        self.lineEnding = lineEnding
        self.newline = newline
    }
}

public enum SourceDecoder {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Decode file bytes. For valid UTF-8 the result round-trips byte-exactly through `encode`.
    public static func decode(_ data: Data) -> (text: String, encoding: SourceEncoding) {
        let hasBOM = data.starts(with: bom)
        let body = hasBOM ? data.dropFirst(3) : data[...]
        let (lineEnding, newline) = detectLineEnding(body)
        if let text = String(validating: body, as: UTF8.self) {
            return (text, SourceEncoding(hasBOM: hasBOM, isValidUTF8: true, lineEnding: lineEnding, newline: newline))
        }
        let lossy = String(decoding: body, as: UTF8.self)
        return (lossy, SourceEncoding(hasBOM: hasBOM, isValidUTF8: false, lineEnding: lineEnding, newline: newline))
    }

    public static func encode(_ text: String, encoding: SourceEncoding) -> Data {
        var data = Data(capacity: text.utf8.count + 3)
        if encoding.hasBOM { data.append(contentsOf: bom) }
        data.append(contentsOf: text.utf8)
        return data
    }

    static func detectLineEnding(_ bytes: Data.SubSequence) -> (LineEnding, String) {
        var lf = 0, crlf = 0, cr = 0
        bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = p.count
            while i < n {
                let b = p[i]
                if b == 0x0A {
                    lf += 1
                } else if b == 0x0D {
                    if i + 1 < n, p[i + 1] == 0x0A { crlf += 1; i += 1 } else { cr += 1 }
                }
                i += 1
            }
        }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        let newline = crlf >= lf && crlf >= cr && crlf > 0 ? "\r\n" : (cr > lf ? "\r" : "\n")
        if kinds == 0 { return (.none, "\n") }
        if kinds > 1 { return (.mixed, newline) }
        return (crlf > 0 ? .crlf : (cr > 0 ? .cr : .lf), newline)
    }
}
