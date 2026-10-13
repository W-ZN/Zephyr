import Foundation
import CoreFoundation

enum LinkPreviewHTTP {
    static func failureDescription(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet:
            return String(localized: "No network connection. Local files can still be previewed.")
        case .networkConnectionLost:
            return String(localized: "The network connection was lost. Local files can still be previewed.")
        case .timedOut:
            return String(localized: "The website took too long to respond. Open the link to try again.")
        default:
            return String(localized: "The website could not be reached.")
        }
    }

    static func accepts(_ contentType: String?) -> Bool {
        guard let type = mediaType(contentType) else { return true }
        return type.hasPrefix("text/") || ["application/xhtml+xml", "application/json", "application/xml", "application/javascript", "application/x-yaml", "application/toml"].contains(type) || type.hasSuffix("+json") || type.hasSuffix("+xml")
    }

    static func isMarkdown(_ contentType: String?, url: URL) -> Bool {
        let type = mediaType(contentType)
        return type == "text/markdown" || type == "text/x-markdown" ||
            (["md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "mdx"].contains(url.pathExtension.lowercased()) && type != "text/html")
    }

    static func isHTML(_ contentType: String?, prefix: String) -> Bool {
        if let type = mediaType(contentType) { return type == "text/html" || type == "application/xhtml+xml" }
        return prefix.prefix(512).range(of: #"(?is)^\s*(?:<!doctype\s+html|<html\b|<head\b|<body\b)"#, options: .regularExpression) != nil
    }

    static func decode(_ data: Data, contentType: String?) -> String? {
        let header = contentType ?? ""
        let prelude = String(decoding: data.prefix(8 << 10), as: UTF8.self)
        let charset = LinkPreviewHTML.capture(#"(?i)charset\s*=\s*["']?([^\s;"'/>]+)"#, in: header)
            ?? LinkPreviewHTML.capture(#"(?i)<meta\b[^>]*charset\s*=\s*["']?([^\s;"'/>]+)"#, in: prelude)
        guard let charset, !["utf-8", "utf8"].contains(charset.lowercased()) else { return LinkPreviewText.decodeUTF8(data) }
        let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
    }

    private static func mediaType(_ contentType: String?) -> String? {
        contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// Extract bounded readable text without constructing a browser, executing scripts or fetching
/// related resources. Empty client-rendered shells can still provide a clearly labelled summary.
enum LinkPreviewHTML {
    static func content(_ html: String, fallbackTitle: String, isHTML: Bool = true) -> (title: String, body: String, isSummary: Bool) {
        guard isHTML else { return (fallbackTitle, plainResponse(html, lines: nil, limit: 8 << 10) ?? "", false) }
        let metadata = metadata(html)
        let title = metadata["og:title"] ?? metadata["twitter:title"] ?? capture(#"(?is)<title\b[^>]*>(.*?)</title>"#, in: html).map { plainText($0) } ?? fallbackTitle
        let withoutScripts = html.replacingOccurrences(of: #"(?is)<(script|style|noscript|svg|template)\b[^>]*>.*?(?:</\1\s*>|$)"#, with: " ", options: .regularExpression)
        let withoutHead = withoutScripts.replacingOccurrences(of: #"(?is)<head\b[^>]*>.*?(?:</head\s*>|$)"#, with: " ", options: .regularExpression)
        let withoutChrome = withoutHead.replacingOccurrences(of: #"(?is)<(nav|header|footer|aside)\b[^>]*>.*?</\1\s*>"#, with: " ", options: .regularExpression)
        for tag in ["main", "article"] {
            let candidate = matches("(?is)<\(tag)\\b[^>]*>(.*?)(?:</\(tag)\\s*>|$)", in: withoutChrome).joined(separator: "\n")
            let body = readableText(candidate, limit: 8 << 10)
            if !body.isEmpty { return (title, body, false) }
        }
        if let article = structuredArticle(html), !article.isEmpty { return (title, article, false) }
        let body = readableText(capture(#"(?is)<body\b[^>]*>(.*?)(?:</body\s*>|$)"#, in: withoutChrome) ?? withoutChrome, limit: 8 << 10)
        if !body.isEmpty { return (title, body, false) }
        let summary = metadata["og:description"] ?? metadata["twitter:description"] ?? metadata["description"] ?? ""
        return (title, String(summary.prefix(1_800)), !summary.isEmpty)
    }

    static func plainText(_ source: String, limit: Int = 1_800) -> String {
        readableText(source, limit: limit).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func metadata(_ html: String) -> [String: String] {
        var result: [String: String] = [:]
        for tag in matches(#"(?is)(<meta\b[^>]*>)"#, in: html) {
            let attributes = attributes(tag)
            guard let name = attributes["property"] ?? attributes["name"], let content = attributes["content"] else { continue }
            let text = plainText(content)
            if !text.isEmpty { result[name.lowercased()] = text }
        }
        return result
    }

    private static let attributePattern = try! NSRegularExpression(pattern: #"(?i)([a-z][a-z0-9:_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>`=]+))"#)
    private static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let key = Range(match.range(at: 1), in: tag), let value = (2...4).compactMap({ Range(match.range(at: $0), in: tag) }).first else { continue }
            result[String(tag[key]).lowercased()] = decodeEntities(String(tag[value]))
        }
        return result
    }

    private static func structuredArticle(_ html: String) -> String? {
        for script in matches(#"(?is)(<script\b[^>]*>.*?</script\s*>)"#, in: html) {
            guard let opening = script.firstIndex(of: ">"), attributes(String(script[...opening]))["type"]?.lowercased() == "application/ld+json",
                  let closing = script.range(of: "</script", options: [.caseInsensitive, .backwards]),
                  let data = script[script.index(after: opening)..<closing.lowerBound].data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data), let article = articleBody(json, depth: 0) else { continue }
            let text = readableText(article, limit: 8 << 10)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func articleBody(_ json: Any, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        if let object = json as? [String: Any] {
            if let body = object["articleBody"] as? String, !body.isEmpty { return body }
            for value in object.values { if let body = articleBody(value, depth: depth + 1) { return body } }
        } else if let array = json as? [Any] {
            for value in array { if let body = articleBody(value, depth: depth + 1) { return body } }
        }
        return nil
    }

    private static func readableText(_ source: String, limit: Int) -> String {
        let blocks = source.replacingOccurrences(of: #"(?is)</(?:p|h[1-6]|li|blockquote|pre|div|section|article|main)\s*>|<br\b[^>]*>"#, with: "\n", options: .regularExpression)
        let stripped = blocks.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        let decoded = decodeEntities(stripped)
        var result = ""
        for line in decoded.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if text.isEmpty {
                if !result.isEmpty && !result.hasSuffix("\n") { result.append("\n") }
            } else {
                if !result.isEmpty && !result.hasSuffix("\n") { result.append("\n") }
                result.append(contentsOf: text.prefix(max(0, limit - result.count)))
            }
            if result.count >= limit { break }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ source: String) -> String {
        var decoded = source.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        for (entity, character) in [("apos", "'"), ("lsquo", "‘"), ("rsquo", "’"), ("ldquo", "“"), ("rdquo", "”"), ("ndash", "–"), ("mdash", "—"), ("hellip", "…"), ("copy", "©"), ("reg", "®"), ("bull", "•")] {
            decoded = decoded.replacingOccurrences(of: "&\(entity);", with: character)
        }
        let regex = try! NSRegularExpression(pattern: #"&#(?:([0-9]+)|x([0-9A-Fa-f]+));"#)
        for match in regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)).reversed() {
            let decimal = Range(match.range(at: 1), in: decoded).map { String(decoded[$0]) }
            let hexadecimal = Range(match.range(at: 2), in: decoded).map { String(decoded[$0]) }
            let value = decimal.flatMap { UInt32($0) } ?? hexadecimal.flatMap { UInt32($0, radix: 16) }
            guard let value, let scalar = UnicodeScalar(value), let range = Range(match.range, in: decoded) else { continue }
            decoded.replaceSubrange(range, with: String(scalar))
        }
        return decoded
    }

    static func plainResponse(_ source: String, lines: LinkPreviewLineRange?, limit: Int) -> String? {
        LinkPreviewText.excerpt(from: source, lines: lines, limit: limit)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let match = try! NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }
}
