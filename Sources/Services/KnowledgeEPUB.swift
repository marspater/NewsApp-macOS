// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Offline EPUB 3 with fixed internal paths and stored ZIP members.
enum KnowledgeEPUB {
    enum Error: LocalizedError {
        case tooLarge, storyMissing

        var errorDescription: String? {
            switch self {
            case .tooLarge: "This export is too large. Select fewer stories or remove some notes, then try again."
            case .storyMissing: "A selected story is no longer in your library. Select it again, then try again."
            }
        }
    }
    private static let maxBytes = 32 * 1024 * 1024
    private static let maxDocuments = 500

    static func validate(documents: [KnowledgeExportDocument], title: String) throws {
        guard documents.count <= maxDocuments, title.utf8.count <= maxBytes else { throw Error.tooLarge }
        var size = title.utf8.count
        for document in documents {
            for text in [document.id, document.title, document.publisher, document.url, document.body] + document.tags
                + document.quotes.flatMap({ [$0.text, $0.publisher, $0.url] })
                + document.notes.flatMap({ [$0.selectedText, $0.noteBody] })
            {
                guard text.utf8.count <= maxBytes - size else { throw Error.tooLarge }
                size += text.utf8.count
            }
        }
    }

    static func make(documents: [KnowledgeExportDocument], title: String) throws -> Data {
        try validate(documents: documents, title: title)
        let safeTitle = xml(title)
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let modified = formatter.string(from: Date())
        let container = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">\(identifier)</dc:identifier><dc:title>\(safeTitle)</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">\(modified)</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>
            """
        let nav = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en"><head><title>\(safeTitle)</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol><li><a href="chapter.xhtml">\(safeTitle)</a></li></ol></nav></body></html>
            """
        let sections = documents.map { section($0, formatter: formatter) }.joined()
        let chapter = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en"><head><title>\(safeTitle)</title></head><body><h1>\(safeTitle)</h1>\(sections)</body></html>
            """
        return try zip([
            ("mimetype", "application/epub+zip"), ("META-INF/container.xml", container),
            ("OEBPS/content.opf", opf), ("OEBPS/nav.xhtml", nav), ("OEBPS/chapter.xhtml", chapter),
        ])
    }

    private static func section(_ document: KnowledgeExportDocument, formatter: ISO8601DateFormatter) -> String {
        var result = ""
        result += "<section><h2>\(xml(document.title))</h2><p>\(xml(document.publisher))</p>"
        if let date = document.published, date.timeIntervalSince1970.isFinite {
            result += "<p>\(xml(formatter.string(from: date)))</p>"
        }
        result += "<p>\(xml(document.url))</p>"
        for paragraph in document.body.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            result += "<p>\(xml(paragraph))</p>"
        }
        if !document.tags.isEmpty { result += "<p>Tags: \(xml(document.tags.joined(separator: ", ")))</p>" }
        if !document.quotes.isEmpty { result += "<h3>Cited passages</h3>" }
        for quote in document.quotes {
            result +=
                "<blockquote><p>\(xml(quote.text))</p><p>\(xml(quote.publisher)) — \(xml(quote.url))</p></blockquote>"
        }
        if !document.notes.isEmpty {
            let sortedNotes = document.notes.sortedInReadingOrder()
            result += "<h3>My highlights and notes</h3>"
            if sortedNotes.count > 1 {
                result += "<div class=\"story-notes-group\">"
                for (i, note) in sortedNotes.enumerated() {
                    result += "<h4>Passage \(i + 1)</h4><blockquote><p>\(xml(note.selectedText))</p></blockquote>"
                    if !note.noteBody.isEmpty { result += "<p>\(xml(note.noteBody))</p>" }
                }
                result += "</div>"
            } else if let note = sortedNotes.first {
                result += "<blockquote><p>\(xml(note.selectedText))</p></blockquote>"
                if !note.noteBody.isEmpty { result += "<p>\(xml(note.noteBody))</p>" }
            }
        }
        result += "</section>"
        return result
    }

    private static func xml(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x26: result += "&amp;"
            case 0x3C: result += "&lt;"
            case 0x3E: result += "&gt;"
            case 0x22: result += "&quot;"
            case 0x27: result += "&apos;"
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                result.unicodeScalars.append(scalar)
            default: break
            }
        }
        return result
    }

    private static func zip(_ files: [(String, String)]) throws -> Data {
        var output = Data()
        var directory = Data()
        for (name, text) in files {
            let filename = Data(name.utf8)
            let content = Data(text.utf8)
            guard content.count <= maxBytes, output.count <= maxBytes,
                let length = UInt32(exactly: content.count), let offset = UInt32(exactly: output.count),
                let nameLength = UInt16(exactly: filename.count)
            else { throw Error.tooLarge }
            let checksum = crc32(content)
            output.le(UInt32(0x0403_4b50))
            output.le(UInt16(20))
            output.zipEntryFields(checksum: checksum, length: length, nameLength: nameLength)
            output.append(filename)
            output.append(content)
            directory.le(UInt32(0x0201_4b50))
            directory.le(UInt16(20))
            directory.le(UInt16(20))
            directory.zipEntryFields(checksum: checksum, length: length, nameLength: nameLength)
            directory.le(UInt16(0))
            directory.le(UInt16(0))
            directory.le(UInt16(0))
            directory.le(UInt32(0))
            directory.le(offset)
            directory.append(filename)
        }
        guard let offset = UInt32(exactly: output.count), let length = UInt32(exactly: directory.count),
            let count = UInt16(exactly: files.count), output.count + directory.count + 22 <= maxBytes
        else { throw Error.tooLarge }
        output.append(directory)
        output.le(UInt32(0x0605_4b50))
        output.le(UInt16(0))
        output.le(UInt16(0))
        output.le(count)
        output.le(count)
        output.le(length)
        output.le(offset)
        output.le(UInt16(0))
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return crc ^ 0xffff_ffff
    }
}

extension Data {
    fileprivate mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    /// The fields a ZIP local header and central directory entry share: a stored member with a fixed DOS date.
    fileprivate mutating func zipEntryFields(checksum: UInt32, length: UInt32, nameLength: UInt16) {
        le(UInt16(0))
        le(UInt16(0))
        le(UInt16(0))
        le(UInt16(0x21))
        le(checksum)
        le(length)
        le(length)
        le(nameLength)
        le(UInt16(0))
    }
}
