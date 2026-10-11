import Foundation

/// File ▸ Export: the library list as CSV, JSON or a one-sheet Excel workbook.
public enum LibraryExport {
    public static let headers = ["Title", "Author", "Narrator", "Length (min)", "Purchased", "Released", "Rating", "Genre", "Publisher", "ASIN"]

    /// One row per book; numbers stay numbers so spreadsheets can sort them.
    public enum Cell: Equatable, Sendable { case text(String), number(Double) }

    public static func rows(_ books: [Book]) -> [[Cell]] {
        books.map { b in
            [.text(b.title), .text(b.author), .text(b.narratedBy), .number(Double(b.seconds / 60)),
             .text(b.purchaseDate.map(Book.day.string(from:)) ?? ""), .text(b.releaseDate.map(Book.day.string(from:)) ?? ""),
             b.rating.map(Cell.number) ?? .text(""), .text(b.genre.replacingOccurrences(of: ":", with: " / ")),
             .text(b.publisher), .text(b.asin)]
        }
    }

    private static func string(_ c: Cell) -> String {
        switch c {
        case .text(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        }
    }

    /// RFC 4180: CRLF line ends; fields with commas, quotes or newlines are quoted.
    public static func csv(_ books: [Book]) -> Data {
        func field(_ s: String) -> String {
            s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let lines = [headers] + rows(books).map { $0.map(string) }
        return Data(lines.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n").appending("\r\n").utf8)
    }

    /// Array of objects keyed by the header names.
    public static func json(_ books: [Book]) throws -> Data {
        let objects: [[String: JSONValue]] = rows(books).map { row in
            Dictionary(uniqueKeysWithValues: zip(headers, row).map { key, cell in
                switch cell {
                case .text(let s): (key, .text(s))
                case .number(let n): (key, .number(n))
                }
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(objects)
    }

    private enum JSONValue: Encodable {
        case text(String), number(Double)
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .number(let n): if n.rounded() == n { try c.encode(Int(n)) } else { try c.encode(n) }
            }
        }
    }

    /// Minimal Office Open XML workbook: one sheet, inline strings, stored (uncompressed) ZIP.
    public static func xlsx(_ books: [Book]) -> Data {
        func escape(_ s: String) -> String {
            // XML 1.0 forbids most control characters even when escaped.
            let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" }))
            return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func column(_ i: Int) -> String {
            var n = i + 1, name = ""
            while n > 0 { n -= 1; name = String(UnicodeScalar(UInt8(65 + n % 26))) + name; n /= 26 }
            return name
        }
        let table = [headers.map(Cell.text)] + rows(books)
        var sheet = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        for (r, row) in table.enumerated() {
            sheet += #"<row r="\#(r + 1)">"#
            for (c, cell) in row.enumerated() {
                let ref = "\(column(c))\(r + 1)"
                switch cell {
                case .text(let s): sheet += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
                case .number(let n): sheet += #"<c r="\#(ref)"><v>\#(string(.number(n)))</v></c>"#
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        return Zip.stored([
            ("[Content_Types].xml", header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#),
            ("_rels/.rels", header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#),
            ("xl/workbook.xml", header + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Library" sheetId="1" r:id="rId1"/></sheets></workbook>"#),
            ("xl/_rels/workbook.xml.rels", header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#),
            ("xl/worksheets/sheet1.xml", sheet),
        ].map { ($0.0, Data($0.1.utf8)) })
    }
}

/// ZIP archive without compression (method 0), enough for XLSX. No ZIP64: entries and archive must stay under 4 GB.
enum Zip {
    static func stored(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data(), directory = Data()
        func le<T: FixedWidthInteger>(_ v: T, into d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for (name, data) in entries {
            let offset = UInt32(out.count), crc = crc32(data), size = UInt32(data.count), nameData = Data(name.utf8)
            // Local header: signature, version 2.0, flags (bit 11 = UTF-8 names), method 0, DOS time/date 1980-01-01.
            le(UInt32(0x0403_4b50), into: &out); le(UInt16(20), into: &out); le(UInt16(0x0800), into: &out); le(UInt16(0), into: &out)
            le(UInt16(0), into: &out); le(UInt16(0x21), into: &out)
            le(crc, into: &out); le(size, into: &out); le(size, into: &out)
            le(UInt16(nameData.count), into: &out); le(UInt16(0), into: &out)
            out += nameData; out += data
            le(UInt32(0x0201_4b50), into: &directory); le(UInt16(20), into: &directory); le(UInt16(20), into: &directory)
            le(UInt16(0x0800), into: &directory); le(UInt16(0), into: &directory); le(UInt16(0), into: &directory); le(UInt16(0x21), into: &directory)
            le(crc, into: &directory); le(size, into: &directory); le(size, into: &directory)
            le(UInt16(nameData.count), into: &directory); le(UInt16(0), into: &directory); le(UInt16(0), into: &directory)
            le(UInt16(0), into: &directory); le(UInt16(0), into: &directory); le(UInt32(0), into: &directory); le(offset, into: &directory)
            directory += nameData
        }
        let directoryOffset = UInt32(out.count)
        out += directory
        le(UInt32(0x0605_4b50), into: &out); le(UInt16(0), into: &out); le(UInt16(0), into: &out)
        le(UInt16(entries.count), into: &out); le(UInt16(entries.count), into: &out)
        le(UInt32(directory.count), into: &out); le(directoryOffset, into: &out); le(UInt16(0), into: &out)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
