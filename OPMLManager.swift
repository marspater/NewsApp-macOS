import Foundation
import AppKit
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
        let parser = OPMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.items
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
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

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
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
            xml += "        <outline text=\"\(escapeXML(displayTitle))\" title=\"\(escapeXML(displayTitle))\" type=\"rss\" xmlUrl=\"\(escapedURL)\"/>\n"
        }

        xml += """
            </body>
        </opml>
        """
        return xml
    }

    private static func escapeXML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            onImport(data)
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
            try? xmlString.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
