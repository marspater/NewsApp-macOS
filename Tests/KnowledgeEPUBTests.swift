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

private final class EPUBXMLDelegate: NSObject, XMLParserDelegate {
    var error: Error?
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
}

enum KnowledgeEPUBTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("❌ EPUB: \(message)")
        }
    }
    static func run() async {
        do {
            let note = UserNote(
                articleID: "id", paragraphIndex: 0, charStart: 0, selectedText: "quoted <text>",
                prefix: "", suffix: "", noteBody: "note & comment")
            let document = KnowledgeExportDocument(
                id: "id", title: "Title <&>", publisher: "Publisher", url: "https://example.test/?x=1&y=2",
                published: Date(timeIntervalSince1970: 0), body: "Body & <script>\u{0}\n\nSecond paragraph",
                tags: ["a & b"],
                quotes: [.init(text: "A <quote>", publisher: "Source", url: "https://example.test/")], notes: [note])
            let archive = try KnowledgeEPUB.make(documents: [document], title: "Book <&>")
            func word(_ offset: Int, _ count: Int) -> UInt32 {
                (0..<count).reduce(0) { $0 | (UInt32(archive[offset + $1]) << (8 * $1)) }
            }
            func crc(_ data: Data) -> UInt32 {
                var value: UInt32 = 0xffff_ffff
                for byte in data {
                    value ^= UInt32(byte)
                    for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
                }
                return value ^ 0xffff_ffff
            }
            var offset = 0
            var members: [String: Data] = [:]
            var first = true
            while offset + 30 <= archive.count && word(offset, 4) == 0x0403_4b50 {
                let method = word(offset + 8, 2)
                let checksum = word(offset + 14, 4)
                let length = Int(word(offset + 18, 4))
                let nameLength = Int(word(offset + 26, 2))
                let extraLength = Int(word(offset + 28, 2))
                let start = offset + 30 + nameLength + extraLength
                guard start + length <= archive.count,
                    let name = String(data: archive[(offset + 30)..<(offset + 30 + nameLength)], encoding: .utf8)
                else {
                    check(false, "valid member boundaries")
                    return
                }
                let bytes = Data(archive[start..<(start + length)])
                check(method == 0 && crc(bytes) == checksum, "stored member CRC: \(name)")
                if first {
                    check(
                        name == "mimetype" && extraLength == 0
                            && String(data: bytes, encoding: .utf8) == "application/epub+zip", "EPUB first mimetype")
                    first = false
                }
                members[name] = bytes
                offset = start + length
            }
            check(
                Set(members.keys)
                    == Set([
                        "mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml",
                        "OEBPS/chapter.xhtml",
                    ]), "required members")
            check(
                word(offset, 4) == 0x0201_4b50 && word(archive.count - 22, 4) == 0x0605_4b50,
                "central directory and end record")
            for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter.xhtml"] {
                guard let data = members[name] else {
                    check(false, "missing XML \(name)")
                    continue
                }
                let parser = XMLParser(data: data)
                let delegate = EPUBXMLDelegate()
                parser.delegate = delegate
                check(parser.parse() && delegate.error == nil, "well-formed XML \(name)")
            }
            let chapter = String(data: members["OEBPS/chapter.xhtml"] ?? Data(), encoding: .utf8) ?? ""
            check(
                chapter.contains("Title &lt;&amp;&gt;") && chapter.contains("Body &amp; &lt;script&gt;")
                    && chapter.contains("note &amp; comment") && chapter.contains("A &lt;quote&gt;"),
                "content and escaping")
            check(chapter.contains("<p>Body &amp; &lt;script&gt;</p><p>Second paragraph</p>"), "body paragraphs")
            check(
                chapter.contains("<h3>Cited passages</h3>") && chapter.contains("<h3>My highlights and notes</h3>"),
                "citation and personal note headings")
            do {
                _ = try KnowledgeEPUB.make(documents: Array(repeating: document, count: 501), title: "large")
                check(false, "document limit")
            } catch KnowledgeEPUB.Error.tooLarge { check(true, "document limit") }
        } catch { check(false, "unexpected error: \(error)") }
        print("Finished \(checks) EPUB checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
