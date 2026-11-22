import CoreGraphics
import Foundation

struct MarksReport: Codable, Hashable, Sendable {
    var student: MarksStudent
    /// exam events in the order the pdf lists them, that order is not chronological
    var events: [String]
    var subjects: [SubjectMarks]
    /// "Mon Apr 20 01:46:33 IST 2026" as printed
    var generated: String = ""

    init(student: MarksStudent, events: [String], subjects: [SubjectMarks], generated: String = "") {
        self.student = student
        self.events = events
        self.subjects = subjects
        self.generated = generated
    }

    enum CodingKeys: String, CodingKey { case student, events, subjects, generated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        student = try c.decodeIfPresent(MarksStudent.self, forKey: .student) ?? MarksStudent()
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? []
        subjects = try c.decodeIfPresent([SubjectMarks].self, forKey: .subjects) ?? []
        generated = try c.decodeIfPresent(String.self, forKey: .generated) ?? ""
    }

    static let empty = MarksReport(student: MarksStudent(), events: [], subjects: [])
}

struct MarksStudent: Codable, Hashable, Sendable {
    var name = ""
    var enrollmentNo = ""
    var program = ""
    var branch = ""
    var semester = ""
    var registrationCode = ""

    init(name: String = "", enrollmentNo: String = "", program: String = "", branch: String = "", semester: String = "", registrationCode: String = "") {
        self.name = name
        self.enrollmentNo = enrollmentNo
        self.program = program
        self.branch = branch
        self.semester = semester
        self.registrationCode = registrationCode
    }

    enum CodingKeys: String, CodingKey { case name, enrollmentNo, program, branch, semester, registrationCode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: k) ?? "" }
        self.init(name: try s(.name), enrollmentNo: try s(.enrollmentNo), program: try s(.program), branch: try s(.branch),
                  semester: try s(.semester), registrationCode: try s(.registrationCode))
    }
}

struct SubjectMarks: Codable, Hashable, Sendable {
    var code: String
    var name: String
    var scores: [EventScore]
}

struct EventScore: Codable, Hashable, Sendable {
    var event: String
    /// OM/FM
    var marks: Score? = nil
    /// OW/WT, what actually counts toward the total
    var weighted: Score? = nil

    init(event: String, marks: Score? = nil, weighted: Score? = nil) {
        self.event = event
        self.marks = marks
        self.weighted = weighted
    }

    enum CodingKeys: String, CodingKey { case event, marks, weighted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        marks = try c.decodeIfPresent(Score.self, forKey: .marks)
        weighted = try c.decodeIfPresent(Score.self, forKey: .weighted)
    }
}

enum Score: Hashable, Sendable {
    case value(obtained: Double, max: Double)
    case absent
    /// printed as "-": this event doesn't apply to the subject
    case notApplicable
    case other(String)

    private static let fraction = try! NSRegularExpression(pattern: #"^(-?\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)$"#)

    static func parse(_ text: String) -> Score? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t == "-" { return .notApplicable }
        let up = t.uppercased()
        if up == "A" || up == "AB" || up == "ABS" { return .absent }
        let ns = t as NSString
        if let m = fraction.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
           let a = Double(ns.substring(with: m.range(at: 1))), let b = Double(ns.substring(with: m.range(at: 2))) {
            return .value(obtained: a, max: b)
        }
        return .other(t)
    }

    var isNotApplicable: Bool { if case .notApplicable = self { return true } else { return false } }
}

extension Score: Codable {
    enum CodingKeys: String, CodingKey { case type, obtained, max, raw }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "value": self = .value(obtained: try c.decode(Double.self, forKey: .obtained), max: try c.decode(Double.self, forKey: .max))
        case "absent": self = .absent
        case "na": self = .notApplicable
        default: self = .other(try c.decodeIfPresent(String.self, forKey: .raw) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let o, let m):
            try c.encode("value", forKey: .type)
            try c.encode(o, forKey: .obtained)
            try c.encode(m, forKey: .max)
        case .absent: try c.encode("absent", forKey: .type)
        case .notApplicable: try c.encode("na", forKey: .type)
        case .other(let raw):
            try c.encode("other", forKey: .type)
            try c.encode(raw, forKey: .raw)
        }
    }
}

struct MarksParseError: Error {
    let reason: String
}

/// reads the "Subject Marks(Event Wise)" pdf. every cell is a drawn rectangle
/// and every value is one text run inside it, so the table is rebuilt from
/// geometry instead of from text order (which is what breaks pdftotext-style
/// parsers on wrapped headers and 3 line subject names).
enum MarksParser {
    struct TextRun {
        var x: Double
        var y: Double
        var text: String
        var size: Double
    }

    /// a stroked or filled rectangle, normalized so w and h are positive
    struct Rect: Hashable {
        let x: Double, y: Double, w: Double, h: Double
        var right: Double { x + w }
        var top: Double { y + h }
        var area: Double { w * h }
        func contains(_ px: Double, _ py: Double, slack: Double = 0.5) -> Bool {
            px >= x - slack && px <= right + slack && py >= y - slack && py <= top + slack
        }
    }

    struct PageContent {
        let runs: [TextRun]
        let rects: [Rect]
    }

    private struct Cell {
        let rect: Rect
        let lines: [String]
        let text: String
    }

    private struct Column {
        let event: Int
        let weighted: Bool
        let left: Double
        let right: Double
    }

    /// dataTop: bottom edge of the header block, rows start below it
    private struct Layout {
        let anchor: Rect
        let events: [String]
        let columns: [Column]
        let dataTop: Double
    }

    private static let eps = 1.0
    private static let codePattern = try! NSRegularExpression(pattern: #"\(\s*([A-Za-z0-9./\- ]+?)\s*\)\s*$"#)
    private static let generatedPattern = try! NSRegularExpression(pattern: #"^[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2} \w+ \d{4}$"#)

    static func parse(_ pdf: Data) throws -> MarksReport {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider) else {
            throw MarksParseError(reason: "not a pdf")
        }
        guard doc.numberOfPages > 0 else { throw MarksParseError(reason: "no pages") }
        let pages = (1...doc.numberOfPages).compactMap { doc.page(at: $0) }.map(ContentScanner.scan)

        var layout: Layout?
        var order: [String] = []
        var subjects: [String: SubjectMarks] = [:]
        var student = MarksStudent()
        var generated = ""

        for page in pages {
            let cells = cells(page)
            student = mergeStudent(student, cells)
            if generated.isEmpty {
                generated = page.runs.map { $0.text.trimmingCharacters(in: .whitespaces) }.first { matches(generatedPattern, $0) } ?? ""
            }
            let found = findLayout(cells)
            guard let active = found ?? layout else { continue }
            layout = active
            let below = found?.dataTop ?? Double.greatestFiniteMagnitude
            for s in rows(cells, active, below: below) {
                // a subject split across pages keeps its first half
                if var a = subjects[s.code] {
                    a.scores += s.scores.filter { x in !a.scores.contains { $0.event == x.event } }
                    subjects[s.code] = a
                } else {
                    order.append(s.code)
                    subjects[s.code] = s
                }
            }
        }
        guard let l = layout else { return MarksReport(student: student, events: [], subjects: [], generated: generated) }
        return MarksReport(student: student, events: l.events, subjects: order.compactMap { subjects[$0] }, generated: generated)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func round2(_ y: Double) -> Int64 { Int64((y * 2 + 0.5).rounded(.down)) }

    private static func cells(_ page: PageContent) -> [Cell] {
        var seen = Set<Rect>()
        let rects = page.rects.filter { $0.w > 2 && $0.h > 2 }.filter { seen.insert($0).inserted }
        var order: [Rect] = []
        var byRect: [Rect: [TextRun]] = [:]
        for run in page.runs {
            if run.text.isBlank { continue }
            let px = run.x + 0.5
            let py = run.y + 0.5
            guard let home = rects.filter({ $0.contains(px, py) }).min(by: { $0.area < $1.area }) else { continue }
            if byRect[home] == nil { order.append(home) }
            byRect[home, default: []].append(run)
        }
        return order.map { rect in
            let runs = byRect[rect]!
            // top to bottom, then left to right, runs on one baseline glued
            let sorted = runs.enumerated().sorted { a, b in
                let ya = round2(a.element.y), yb = round2(b.element.y)
                if ya != yb { return ya > yb }
                if a.element.x != b.element.x { return a.element.x < b.element.x }
                return a.offset < b.offset
            }.map(\.element)
            var keys: [Int64] = []
            var groups: [Int64: [TextRun]] = [:]
            for r in sorted {
                let k = round2(r.y)
                if groups[k] == nil { keys.append(k) }
                groups[k, default: []].append(r)
            }
            let lines = keys.map { k in
                groups[k]!.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return Cell(rect: rect, lines: lines, text: joinLines(lines))
        }
    }

    private static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if !out.isEmpty && !out.hasSuffix("-") { out += " " }
            out += t
        }
        return out.collapsingSpaces
    }

    private static func findLayout(_ cells: [Cell]) -> Layout? {
        guard let anchor = cells.first(where: { $0.text.caseInsensitiveCompare("Subject Code") == .orderedSame })?.rect else { return nil }
        let headers = cells.filter { abs($0.rect.y - anchor.y) < eps && abs($0.rect.h - anchor.h) < eps && $0.rect.x > anchor.x + eps }
            .sorted { $0.rect.x < $1.rect.x }
        if headers.isEmpty { return nil }
        let subs = cells.filter { abs($0.rect.top - anchor.y) < eps && $0.rect.x >= anchor.right - eps }
        var columns: [Column] = []
        for s in subs {
            let cx = s.rect.x + s.rect.w / 2
            guard let ev = headers.firstIndex(where: { cx >= $0.rect.x - eps && cx <= $0.rect.right + eps }) else { continue }
            let label = s.text.replacingOccurrences(of: " ", with: "").uppercased()
            let weighted: Bool
            if label.hasPrefix("OW") || label.contains("WT") { weighted = true }
            else if label.hasPrefix("OM") || label.contains("FM") { weighted = false }
            else { continue }
            columns.append(Column(event: ev, weighted: weighted, left: s.rect.x, right: s.rect.right))
        }
        // no sub header row at all: one value per event, treat it as raw marks
        if columns.isEmpty {
            for (i, h) in headers.enumerated() { columns.append(Column(event: i, weighted: false, left: h.rect.x, right: h.rect.right)) }
        }
        let dataTop = subs.map(\.rect.y).min() ?? anchor.y
        return Layout(anchor: anchor, events: headers.map(\.text), columns: columns, dataTop: dataTop)
    }

    private static func rows(_ cells: [Cell], _ layout: Layout, below: Double) -> [SubjectMarks] {
        let a = layout.anchor
        let subjectCells = cells.filter { abs($0.rect.x - a.x) < eps && abs($0.rect.w - a.w) < eps && $0.rect.top <= below + eps }
            .sorted { $0.rect.y > $1.rect.y }
        return subjectCells.compactMap { sc in
            let ns = sc.text as NSString
            guard let m = codePattern.firstMatch(in: sc.text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let code = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
            let name = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces).ifBlank(code)
            let rowCells = cells.filter { abs($0.rect.y - sc.rect.y) < eps && $0.rect.x >= sc.rect.right - eps }
            var marks: [Int: Score] = [:]
            var weighted: [Int: Score] = [:]
            for c in rowCells {
                let cx = c.rect.x + c.rect.w / 2
                guard let col = layout.columns.first(where: { cx >= $0.left - eps && cx <= $0.right + eps }) else { continue }
                guard let score = Score.parse(c.text) else { continue }
                if col.weighted { weighted[col.event] = score } else { marks[col.event] = score }
            }
            let scores: [EventScore] = layout.events.indices.compactMap { i in
                let om = marks[i], ow = weighted[i]
                return om == nil && ow == nil ? nil : EventScore(event: layout.events[i], marks: om, weighted: ow)
            }
            return SubjectMarks(code: code, name: name, scores: scores)
        }
    }

    private static func mergeStudent(_ s: MarksStudent, _ cells: [Cell]) -> MarksStudent {
        func field(_ key: String) -> String {
            for c in cells {
                let t = c.text
                if t.count > key.count, t.lowercased().hasPrefix(key.lowercased() + ":") {
                    return String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                }
            }
            return ""
        }
        return MarksStudent(
            name: s.name.isEmpty ? field("Name") : s.name,
            enrollmentNo: s.enrollmentNo.isEmpty ? field("Enrollment No") : s.enrollmentNo,
            program: s.program.isEmpty ? field("Program") : s.program,
            branch: s.branch.isEmpty ? field("Branch") : s.branch,
            semester: s.semester.isEmpty ? field("Semester") : s.semester,
            registrationCode: s.registrationCode.isEmpty ? field("Registration Code") : s.registrationCode
        )
    }
}

/// walks a page's content stream keeping just the ctm, text matrices and rectangles.
/// fonts are all standard 14 with WinAnsi here so glyph widths never matter:
/// runs are placed by their start point and cells come from the drawn rects.
enum ContentScanner {
    struct Matrix {
        var a, b, c, d, e, f: Double

        func times(_ m: Matrix) -> Matrix {
            Matrix(a: a * m.a + b * m.c, b: a * m.b + b * m.d,
                   c: c * m.a + d * m.c, d: c * m.b + d * m.d,
                   e: e * m.a + f * m.c + m.e, f: e * m.b + f * m.d + m.f)
        }

        func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + c * y + e, b * x + d * y + f) }

        static let identity = Matrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)
        static func translate(_ x: Double, _ y: Double) -> Matrix { Matrix(a: 1, b: 0, c: 0, d: 1, e: x, f: y) }
    }

    final class State {
        var runs: [MarksParser.TextRun] = []
        var rects: [MarksParser.Rect] = []
        var stack: [Matrix] = []
        var ctm = Matrix.identity
        var tm = Matrix.identity
        var tlm = Matrix.identity
        var leading = 0.0
        var fontSize = 0.0
        // set when a positioning op ran, so back to back Tj calls glue together
        var fresh = true

        func moveLine(_ tx: Double, _ ty: Double) {
            tlm = Matrix.translate(tx, ty).times(tlm)
            tm = tlm
            fresh = true
        }

        func show(_ bytes: [UInt8]) {
            let s = WinAnsi.decode(bytes)
            if !fresh, !runs.isEmpty {
                runs[runs.count - 1].text += s
            } else {
                let (x, y) = tm.times(ctm).apply(0, 0)
                runs.append(MarksParser.TextRun(x: x, y: y, text: s, size: fontSize * abs(tm.d)))
            }
            fresh = false
        }
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> State {
        Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func num(_ s: CGPDFScannerRef) -> Double {
        var v: CGPDFReal = 0
        return CGPDFScannerPopNumber(s, &v) ? Double(v) : 0
    }

    /// pops n numbers, returned in the order they were written
    private static func nums(_ s: CGPDFScannerRef, _ n: Int) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) { out[i] = num(s) }
        return out
    }

    private static func bytes(_ str: CGPDFStringRef) -> [UInt8] {
        guard let p = CGPDFStringGetBytePtr(str) else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(str)))
    }

    private static func popString(_ s: CGPDFScannerRef) -> [UInt8]? {
        var str: CGPDFStringRef?
        guard CGPDFScannerPopString(s, &str), let str else { return nil }
        return bytes(str)
    }

    static func scan(_ page: CGPDFPage) -> MarksParser.PageContent {
        let st = State()
        guard let table = CGPDFOperatorTableCreate() else { return MarksParser.PageContent(runs: [], rects: []) }

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = ContentScanner.state(info)
            s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = ContentScanner.state(info)
            s.ctm = s.stack.popLast() ?? .identity
        }
        CGPDFOperatorTableSetCallback(table, "cm") { sc, info in
            let s = ContentScanner.state(info)
            let n = ContentScanner.nums(sc, 6)
            s.ctm = Matrix(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5]).times(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "re") { sc, info in
            let s = ContentScanner.state(info)
            let n = ContentScanner.nums(sc, 4)
            let (x0, y0) = s.ctm.apply(n[0], n[1])
            let (x1, y1) = s.ctm.apply(n[0] + n[2], n[1] + n[3])
            s.rects.append(MarksParser.Rect(x: min(x0, x1), y: min(y0, y1), w: abs(x1 - x0), h: abs(y1 - y0)))
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            let s = ContentScanner.state(info)
            s.tm = .identity
            s.tlm = .identity
            s.fresh = true
        }
        CGPDFOperatorTableSetCallback(table, "ET") { _, info in
            ContentScanner.state(info).fresh = true
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { sc, info in
            ContentScanner.state(info).fontSize = ContentScanner.num(sc)
        }
        CGPDFOperatorTableSetCallback(table, "TL") { sc, info in
            ContentScanner.state(info).leading = ContentScanner.num(sc)
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { sc, info in
            let s = ContentScanner.state(info)
            let n = ContentScanner.nums(sc, 6)
            s.tlm = Matrix(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5])
            s.tm = s.tlm
            s.fresh = true
        }
        CGPDFOperatorTableSetCallback(table, "Td") { sc, info in
            let n = ContentScanner.nums(sc, 2)
            ContentScanner.state(info).moveLine(n[0], n[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { sc, info in
            let s = ContentScanner.state(info)
            let n = ContentScanner.nums(sc, 2)
            s.leading = -n[1]
            s.moveLine(n[0], n[1])
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            let s = ContentScanner.state(info)
            s.moveLine(0, -s.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { sc, info in
            if let b = ContentScanner.popString(sc) { ContentScanner.state(info).show(b) }
        }
        CGPDFOperatorTableSetCallback(table, "'") { sc, info in
            let s = ContentScanner.state(info)
            s.moveLine(0, -s.leading)
            if let b = ContentScanner.popString(sc) { s.show(b) }
        }
        CGPDFOperatorTableSetCallback(table, "\"") { sc, info in
            let s = ContentScanner.state(info)
            s.moveLine(0, -s.leading)
            if let b = ContentScanner.popString(sc) { s.show(b) }
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { sc, info in
            var arr: CGPDFArrayRef?
            guard CGPDFScannerPopArray(sc, &arr), let arr else { return }
            var out: [UInt8] = []
            for i in 0..<CGPDFArrayGetCount(arr) {
                var obj: CGPDFObjectRef?
                guard CGPDFArrayGetObject(arr, i, &obj), let obj else { continue }
                switch CGPDFObjectGetType(obj) {
                case .string:
                    var str: CGPDFStringRef?
                    if CGPDFObjectGetValue(obj, .string, &str), let str { out += ContentScanner.bytes(str) }
                case .real, .integer:
                    var v: CGPDFReal = 0
                    // a big negative kern is how some writers fake a space
                    if CGPDFObjectGetValue(obj, .real, &v), v < -200 { out.append(0x20) }
                default: break
                }
            }
            ContentScanner.state(info).show(out)
        }

        let stream = CGPDFContentStreamCreateWithPage(page)
        let info = Unmanaged.passUnretained(st).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return MarksParser.PageContent(runs: st.runs, rects: st.rects)
    }
}

enum WinAnsi {
    // 0x80..0x9f, the only range that differs from latin-1
    private static let high: [Character] = [
        "€", "\u{FFFD}", "‚", "ƒ", "„", "…", "†", "‡",
        "ˆ", "‰", "Š", "‹", "Œ", "\u{FFFD}", "Ž", "\u{FFFD}",
        "\u{FFFD}", "‘", "’", "“", "”", "•", "–", "—",
        "˜", "™", "š", "›", "œ", "\u{FFFD}", "ž", "Ÿ",
    ]

    static func decode(_ bytes: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(bytes.count)
        for b in bytes {
            switch b {
            case 0x80...0x9F: s.append(high[Int(b) - 0x80])
            case 0xA0: s.append(" ")
            default: s.append(Character(Unicode.Scalar(b)))
            }
        }
        return s
    }
}
