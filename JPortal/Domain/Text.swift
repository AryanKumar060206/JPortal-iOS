import Foundation

private let romanPattern = try! NSRegularExpression(pattern: #"(?i)^(i{1,3}|iv|v|vi{0,3}|ix|x)(-\w+)?$"#)
// no vowel means an acronym (DSP, DBMS). ones with vowels have to be listed
private let consonantsPattern = try! NSRegularExpression(pattern: #"^[B-DF-HJ-NP-TV-XZ]{3,}$"#)
// ones the consonant rule can't catch because they have a vowel
private let acronyms: Set<String> = [
    "IOT", "IIOT", "AI", "FPGA", "VLSI", "ASIC", "CAD", "CPU", "GPU", "API", "UI", "UX", "OOP", "OOPS", "MEMS", "ECE", "CSE", "IOS",
]
private let small: Set<String> = ["And", "Of", "The", "For", "In", "To", "Using", "A", "An", "Or", "Nor", "But", "Yet", "So"]

private final class Memo: @unchecked Sendable {
    let lock = NSLock()
    var titled: [String: String] = [:]
    var named: [String: String] = [:]
}
private let memo = Memo()

private func full(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
}

extension String {
    /// "DATA STRUCTURES LAB" -> "Data Structures Lab", keeps roman numerals and acronyms
    var titleCase: String {
        if let hit = memo.lock.withLock({ memo.titled[self] }) { return hit }
        func part(_ w: String, small allowSmall: Bool) -> String {
            let core = w.trimmingCharacters(in: CharacterSet.letters.inverted)
            if w.isEmpty { return w }
            if full(romanPattern, w) { return w.uppercased() }
            if w.contains(where: \.isLowercase) { return w }
            if acronyms.contains(core) || full(consonantsPattern, core) { return w }
            let cased = w.lowercased().capitalizedFirst
            return allowSmall && small.contains(cased) ? cased.lowercased() : cased
        }
        let words = split(separator: " ", omittingEmptySubsequences: false).map { sub -> String in
            let w = String(sub)
            if full(romanPattern, w) { return w.uppercased() }
            // "TRAINING-II", "SELF-STUDY": each side of a hyphen is cased on its own
            let pieces = w.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if pieces.count > 1 { return pieces.map { part($0, small: false) }.joined(separator: "-") }
            return part(w, small: true)
        }
        let out = words.joined(separator: " ").capitalizedFirst
        memo.lock.withLock { memo.titled[self] = out }
        return out
    }

    /// "DR. A.K.  RAO" -> "Dr. A.K. Rao". names have no acronyms, so short surnames stay words
    var nameCase: String {
        if let hit = memo.lock.withLock({ memo.named[self] }) { return hit }
        let s = Array(trimmingCharacters(in: .whitespaces))
        var out = ""
        for i in s.indices {
            let c = s[i]
            if c.isWhitespace {
                if !s[i - 1].isWhitespace { out.append(" ") }
            } else {
                out += (i == 0 || !s[i - 1].isLetter) ? c.uppercased() : c.lowercased()
            }
        }
        memo.lock.withLock { memo.named[self] = out }
        return out
    }

    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}

private let semesterPattern = try! NSRegularExpression(pattern: #"(\d{4})(ODD|EVE|EVEN|SUM|SUMMER)SEM"#, options: [.caseInsensitive])

private let summerFirstPattern = try! NSRegularExpression(pattern: #"^\s*(?:SUMMER|SUM)\s*-?\s*(\d{4})"#, options: [.caseInsensitive])

/// "2026ODDSEM" -> "Odd 2026", "SUMMER2026" -> "Summer 2026"
func prettySemester(_ code: String) -> String {
    let ns = code as NSString
    if let m = summerFirstPattern.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) {
        return "Summer \(ns.substring(with: m.range(at: 1)))"
    }
    guard let m = semesterPattern.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return code }
    let kind: String
    switch ns.substring(with: m.range(at: 2)).uppercased() {
    case "ODD": kind = "Odd"
    case "EVE", "EVEN": kind = "Even"
    default: kind = "Summer"
    }
    return "\(kind) \(ns.substring(with: m.range(at: 1)))"
}

private let termPattern = try! NSRegularExpression(pattern: #"(\d{4})(ODD|EVE|EVEN)SEM"#)

/// where a regular term sits in time: 2025EVESEM (january) comes right before 2025ODDSEM (july). summer terms get no number
func term(_ code: String) -> Int? {
    let up = code.uppercased()
    let ns = up as NSString
    guard let m = termPattern.firstMatch(in: up, range: NSRange(location: 0, length: ns.length)), let y = Int(ns.substring(with: m.range(at: 1))) else { return nil }
    return y * 2 + (ns.substring(with: m.range(at: 2)) == "ODD" ? 1 : 0)
}

/// the term a date falls in, numbered like term(): january to june is the even term, july on the odd one
func term(of date: Date) -> Int {
    let d = Day(date)
    return d.year * 2 + (d.month >= 7 ? 1 : 0)
}

/// the semester going on now. the portal puts next term's registration at the top of
/// its lists as soon as it opens (2027EVENSEM in november), so the head of a list isn't
/// "current": the newest regular term that has already started is
func currentSemester(_ list: [Semester], now: Date = AppClock.now()) -> Semester? {
    let today = term(of: now)
    let started = list.compactMap { s in term(s.code).flatMap { $0 <= today ? (s, $0) : nil } }
    return started.max { $0.1 < $1.1 }?.0 ?? list.first
}

/// how many semesters a programme runs. the portal's stymax is the highest semester
/// registered so far, not the length of the course, so it only ever raises this
func courseLength(_ p: StudentProgram?) -> Int {
    let code = (p?.programCode ?? "").uppercased()
    let name = (p?.program ?? "").uppercased()
    let known: Int
    if name.contains("INTEGRATED") || name.contains("DUAL DEGREE") { known = 10 }
    else if code.hasPrefix("B.T") || code.hasPrefix("BTECH") || name.contains("BACHELOR OF TECHNOLOGY") { known = 8 }
    else if code.contains("BCA") || (name.contains("BACHELOR") && name.contains("COMPUTER APPLICATION")) { known = 6 }
    else if code.hasPrefix("M.T") || code.contains("MBA") || code.contains("MCA") || name.contains("MASTER") { known = 4 }
    else { known = 8 }
    return max(known, p?.maxSemesters ?? 0)
}

/// 4 or 4.5, never 4.0
func fmt(_ d: Double) -> String {
    d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(format: "%.1f", d)
}

func ago(_ date: Date?, now: Date = AppClock.now()) -> String {
    guard let date else { return "never" }
    let m = Int(now.timeIntervalSince(date) / 60)
    if m < 1 { return "just now" }
    if m < 60 { return "\(m)m ago" }
    if m < 24 * 60 { return "\(m / 60)h ago" }
    return "\(m / (24 * 60))d ago"
}

func rupees(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_IN")
    f.maximumFractionDigits = 0
    return "₹" + (f.string(from: NSNumber(value: v)) ?? String(Int(v)))
}

func ordinal(_ n: Int) -> String {
    let suffix: String
    if (11...13).contains(n % 100) { suffix = "th" }
    else {
        switch n % 10 {
        case 1: suffix = "st"
        case 2: suffix = "nd"
        case 3: suffix = "rd"
        default: suffix = "th"
        }
    }
    return "\(n)\(suffix)"
}

let componentName = ["L": "Lecture", "T": "Tutorial", "P": "Practical"]

func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    n == 1 ? "1 \(one)" : "\(n) \(many ?? one + "s")"
}
