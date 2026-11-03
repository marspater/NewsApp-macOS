import AppKit
import Foundation
import UniformTypeIdentifiers

public struct OPMLItem: Equatable, Sendable {
    public let title: String
    public let url: String
    public let folder: String?

    public init(title: String, url: String, folder: String?) {
        self.title = title
        self.url = url
        self.folder = folder
    }
}

public final class OPMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    /// The feed parser's nesting bound (`FeedXMLParser.maxNestingDepth`); real exports nest two or three levels.
    static let maximumDepth = 64
    /// Well above any reader's subscription list, low enough that a hostile file cannot grow the stacks unbounded.
    static let maximumOutlines = 20_000

    private var items: [OPMLItem] = []
    private var depth = 0
    private var outlineCount = 0
    /// Why the parse was stopped by a guard, as the reader is told it.
    private var guardFailure: String?
    private var folderStack: [String] = []
    private var outlineStack: [Bool] = []
    /// Per open outline: an untyped `url` outline, imported as a feed when it ends without children. With children it
    /// is a category whose `url` is its website.
    private var urlOnlyLeaves: [OPMLItem?] = []

    public static func parse(data: Data) -> [OPMLItem] {
        (try? parseValidated(data: data)) ?? []
    }

    public static func parseValidated(data: Data) throws -> [OPMLItem] {
        guard data.count <= OPMLFileReader.maximumBytes else {
            throw NSError(
                domain: "OPML", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "OPML files must be no larger than 5 MB."])
        }
        // The feed parser's guards (#928): no entity declarations, bounded nesting and outline count.
        guard !XMLInputGuard.declaresEntities(data, scanEntireInput: true) else {
            throw rejection("It declares XML entities, which News does not import.")
        }
        // DTD defaults can be copied into every outline and retained by AppSettings during import.
        guard !XMLInputGuard.declaresAttributeLists(data, scanEntireInput: true) else {
            throw rejection("It declares XML attribute lists, which News does not import.")
        }
        let parser = OPMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldResolveExternalEntities = false
        xmlParser.delegate = parser
        let parsed = xmlParser.parse()
        if let failure = parser.guardFailure { throw rejection(failure) }
        guard parsed else {
            throw xmlParser.parserError
                ?? NSError(
                    domain: "OPML", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The OPML file is incomplete or malformed."])
        }
        return parser.items
    }

    private static func rejection(_ reason: String) -> NSError {
        NSError(domain: "OPML", code: 3, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    private func stop(_ parser: XMLParser, _ reason: String) {
        if guardFailure == nil { guardFailure = reason }
        parser.abortParsing()
    }

    public func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName _: String, value _: String?) {
        stop(parser, "It declares XML entities, which News does not import.")
    }

    public func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName _: String, publicID _: String?, systemID _: String?
    ) {
        stop(parser, "It declares XML entities, which News does not import.")
    }

    // Attribute defaults could add a feed address to every outline, and no reader exports a DTD: any other
    // declaration stops the parse too. Callbacks see decoded text, so a declared encoding cannot hide one.
    public func parser(
        _ parser: XMLParser, foundAttributeDeclarationWithName _: String, forElement _: String, type _: String?,
        defaultValue _: String?
    ) {
        stop(parser, Self.definitionsReason)
    }

    public func parser(_ parser: XMLParser, foundElementDeclarationWithName _: String, model _: String) {
        stop(parser, Self.definitionsReason)
    }

    public func parser(
        _ parser: XMLParser, foundNotationDeclarationWithName _: String, publicID _: String?, systemID _: String?
    ) {
        stop(parser, Self.definitionsReason)
    }

    public func parser(
        _ parser: XMLParser, foundUnparsedEntityDeclarationWithName _: String, publicID _: String?,
        systemID _: String?, notationName _: String?
    ) {
        stop(parser, "It declares XML entities, which News does not import.")
    }

    private static let definitionsReason = "It contains document type definitions, which News does not import."

    public func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard guardFailure == nil else { return }
        depth += 1
        guard depth <= Self.maximumDepth else {
            return stop(parser, "Its outlines nest more than \(Self.maximumDepth) levels deep.")
        }
        guard elementName.lowercased() == "outline" else { return }
        outlineCount += 1
        guard outlineCount <= Self.maximumOutlines else {
            return stop(
                parser,
                "It lists more than \(Self.maximumOutlines.formatted()) outlines.")
        }
        appendOutline(attributes: attributeDict)
    }

    private func appendOutline(attributes attributeDict: [String: String]) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict {
            attributes[key.lowercased()] = value
        }

        let title = outlineTitle(in: attributes)
        if !urlOnlyLeaves.isEmpty { urlOnlyLeaves[urlOnlyLeaves.count - 1] = nil }
        let leaf = urlOnlyLeaf(in: attributes, title: title)
        guard let feedURL = feedURL(in: attributes) else {
            appendFolderOrUntypedOutline(title: title, leaf: leaf)
            return
        }

        items.append(OPMLItem(title: title, url: feedURL, folder: folderStack.last))
        outlineStack.append(false)
        urlOnlyLeaves.append(nil)
    }

    private func appendFolderOrUntypedOutline(title: String, leaf: OPMLItem?) {
        if !title.isEmpty {
            folderStack.append(title)
            outlineStack.append(true)
        } else {
            outlineStack.append(false)
        }
        urlOnlyLeaves.append(leaf)
    }

    private func feedURL(in attributes: [String: String]) -> String? {
        if let xmlURL = nonemptyTrimmed(attributes["xmlurl"]) { return xmlURL }
        guard
            let type = nonemptyTrimmed(attributes["type"])?.lowercased(),
            type == "rss" || type == "atom"
        else { return nil }
        return nonemptyTrimmed(attributes["url"])
    }

    private func outlineTitle(in attributes: [String: String]) -> String {
        nonemptyTrimmed(attributes["title"]) ?? nonemptyTrimmed(attributes["text"]) ?? ""
    }

    private func urlOnlyLeaf(in attributes: [String: String], title: String) -> OPMLItem? {
        guard
            nonemptyTrimmed(attributes["type"]) == nil,
            let url = nonemptyTrimmed(attributes["url"])
        else { return nil }
        return OPMLItem(title: title, url: url, folder: folderStack.last)
    }

    private func nonemptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func finishOutline() {
        if outlineStack.popLast() == true { _ = folderStack.popLast() }
        if let leaf = urlOnlyLeaves.popLast() ?? nil { items.append(leaf) }
    }

    public func parser(
        _ _: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?
    ) {
        depth -= 1
        guard guardFailure == nil, elementName.lowercased() == "outline" else { return }
        finishOutline()
    }
}

public enum OPMLExporter: Sendable {
    public static func generateOPML(feedURLs: [String], title: String = "News Subscriptions") -> String {
        let dateStr = ISO8601DateFormatter().string(from: Date())
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
                <head>
                    <title>\(escapeXML(title))</title>
                    <dateCreated>\(dateStr)</dateCreated>
                </head>
                <body>

            """
        for url in feedURLs {
            let escapedURL = escapeXML(url)
            let displayTitle: String
            if let host = URL(string: url)?.host {
                displayTitle = host.replacingOccurrences(of: "feeds.", with: "")
                    .replacingOccurrences(of: "rss.", with: "")
                    .replacingOccurrences(of: "www.", with: "")
            } else {
                displayTitle = url
            }
            xml +=
                "        <outline text=\"\(escapeXML(displayTitle))\" title=\"\(escapeXML(displayTitle))\" type=\"rss\" xmlUrl=\"\(escapedURL)\"/>\n"
        }

        xml += """
                </body>
            </opml>
            """
        return xml
    }

    internal static func escapeXML(_ string: String) -> String {
        return
            string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Reads off the UI actor, with a bound even if the file grows after selection.
enum OPMLFileReader {
    static let maximumBytes = 5 * 1024 * 1024

    static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw NSError(
                    domain: "OPML", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "OPML files must be no larger than 5 MB."])
            }
            return data
        }.value
    }
}

@MainActor
public enum OPMLDialogs {
    public static func importOPML(onImport: @escaping (Data) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import OPML Subscriptions"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let opmlType = UTType(filenameExtension: "opml") {
            panel.allowedContentTypes = [opmlType, .xml]
        } else {
            panel.allowedContentTypes = [.xml]
        }
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { onImport(try await OPMLFileReader.read(url)) } catch { NSAlert(error: error).runModal() }
            }
        }
    }

    /// File › Export Saved Stories and Export History (#565): writes the stories as JSON or Markdown.
    static func exportStories(_ entries: [StoryExportEntry], title: String, markdown: Bool) {
        let panel = NSSavePanel()
        panel.title = "Export \(title)"
        panel.prompt = "Export"
        let fileExtension = markdown ? "md" : "json"
        panel.nameFieldStringValue = title + "." + fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = markdown ? StoryExport.markdown(entries, title: title) : try StoryExport.json(entries)
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    public static func exportOPML(xmlString: String) {
        let panel = NSSavePanel()
        panel.title = "Export OPML Subscriptions"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "subscriptions.opml"
        if let opmlType = UTType(filenameExtension: "opml") {
            panel.allowedContentTypes = [opmlType, .xml]
        } else {
            panel.allowedContentTypes = [.xml]
        }
        if panel.runModal() == .OK, let url = panel.url {
            do { try xmlString.write(to: url, atomically: true, encoding: .utf8) } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// One story in File › Export Saved Stories or Export History (#565). `savedAt` or `readAt` is filled, as exported.
struct StoryExportEntry: Codable, Equatable, Sendable {
    let title: String
    let publisher: String
    let url: String
    /// Absent when the feed gave no usable date.
    let published: Date?
    var savedAt: Date? = nil
    var readAt: Date? = nil
}

/// Both formats are UTF-8 without a byte order mark; an empty list stays an empty list.
enum StoryExport {
    static func json(_ entries: [StoryExportEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entries)
    }

    static func markdown(_ entries: [StoryExportEntry], title: String) -> Data {
        var lines = ["# \(title)", ""]
        for entry in entries {
            // Brackets would end the link text early; an angle-bracketed destination keeps any URL whole.
            // A line break would end the list item; CR, LF and CRLF all become one space.
            let name = entry.title.split(whereSeparator: \.isNewline).joined(separator: " ")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            var details = [entry.publisher]
            if let published = entry.published { details.append("published " + published.formatted(.iso8601)) }
            if let saved = entry.savedAt { details.append("saved " + saved.formatted(.iso8601)) }
            if let read = entry.readAt { details.append("read " + read.formatted(.iso8601)) }
            lines.append("- [\(name)](<\(entry.url)>) · " + details.joined(separator: " · "))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
