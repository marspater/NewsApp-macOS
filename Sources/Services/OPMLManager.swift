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
    private var items: [OPMLItem] = []
    private var folderStack: [String] = []
    private var outlineStack: [Bool] = []

    public static func parse(data: Data) -> [OPMLItem] {
        (try? parseValidated(data: data)) ?? []
    }

    public static func parseValidated(data: Data) throws -> [OPMLItem] {
        guard data.count <= OPMLFileReader.maximumBytes else {
            throw NSError(
                domain: "OPML", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "OPML files must be no larger than 5 MB."])
        }
        let parser = OPMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldResolveExternalEntities = false
        xmlParser.delegate = parser
        guard xmlParser.parse() else {
            throw xmlParser.parserError
                ?? NSError(
                    domain: "OPML", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The OPML file is incomplete or malformed."])
        }
        return parser.items
    }

    public func parser(
        _ _: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        var xmlUrl: String?
        for (key, val) in attributeDict {
            let lowerKey = key.lowercased()
            if lowerKey == "xmlurl" || lowerKey == "url" {
                xmlUrl = val.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        let title = attributeDict["title"] ?? attributeDict["text"] ?? ""

        if let feedUrl = xmlUrl, !feedUrl.isEmpty {
            items.append(OPMLItem(title: title, url: feedUrl, folder: folderStack.last))
            outlineStack.append(false)
        } else if !title.isEmpty {
            folderStack.append(title)
            outlineStack.append(true)
        } else {
            outlineStack.append(false)
        }
    }

    public func parser(
        _ _: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?
    ) {
        guard elementName.lowercased() == "outline" else { return }
        if let isFolder = outlineStack.popLast(), isFolder {
            _ = folderStack.popLast()
        }
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
            let name = entry.title.replacingOccurrences(of: "\\", with: "\\\\")
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
