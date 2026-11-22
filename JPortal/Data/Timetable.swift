import Foundation
import Observation

// planner.cbor.gz, format 1. see generate_cache.py in jiit-planner-cdn

/// just enough cbor (rfc 8949) to read the planner file
indirect enum CBOR {
    case uint(UInt64)
    case nint(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case tag(UInt64, CBOR)
    case simple(UInt8)
    case float(Double)

    struct Malformed: Error {}

    static func decode(_ data: Data) throws -> CBOR {
        var r = Reader(bytes: Array(data))
        return try r.item()
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() throws -> UInt8 {
            guard i < bytes.count else { throw Malformed() }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func uint(_ n: Int) throws -> UInt64 {
            var v: UInt64 = 0
            for _ in 0..<n { v = v << 8 | UInt64(try byte()) }
            return v
        }

        /// the argument of a head byte, nil for indefinite length
        mutating func argument(_ info: UInt8) throws -> UInt64? {
            switch info {
            case 0..<24: return UInt64(info)
            case 24: return try uint(1)
            case 25: return try uint(2)
            case 26: return try uint(4)
            case 27: return try uint(8)
            case 31: return nil
            default: throw Malformed()
            }
        }

        mutating func isBreak() -> Bool {
            if i < bytes.count && bytes[i] == 0xFF { i += 1; return true }
            return false
        }

        mutating func chunk(_ n: UInt64) throws -> [UInt8] {
            let end = i + Int(n)
            guard n <= UInt64(bytes.count), end <= bytes.count else { throw Malformed() }
            defer { i = end }
            return Array(bytes[i..<end])
        }

        mutating func item() throws -> CBOR {
            let head = try byte()
            let major = head >> 5
            let info = head & 0x1F
            switch major {
            case 0: guard let v = try argument(info) else { throw Malformed() }; return .uint(v)
            case 1: guard let v = try argument(info) else { throw Malformed() }; return .nint(v)
            case 2, 3:
                var out: [UInt8] = []
                if let n = try argument(info) {
                    out = try chunk(n)
                } else {
                    while !isBreak() {
                        let h = try byte()
                        guard let n = try argument(h & 0x1F) else { throw Malformed() }
                        out += try chunk(n)
                    }
                }
                return major == 2 ? .bytes(out) : .text(String(decoding: out, as: UTF8.self))
            case 4:
                var out: [CBOR] = []
                if let n = try argument(info) {
                    out.reserveCapacity(Int(min(n, 1 << 16)))
                    for _ in 0..<n { out.append(try item()) }
                } else {
                    while !isBreak() { out.append(try item()) }
                }
                return .array(out)
            case 5:
                var out: [(CBOR, CBOR)] = []
                if let n = try argument(info) {
                    for _ in 0..<n { out.append((try item(), try item())) }
                } else {
                    while !isBreak() { out.append((try item(), try item())) }
                }
                return .map(out)
            case 6:
                guard let t = try argument(info) else { throw Malformed() }
                return .tag(t, try item())
            default:
                switch info {
                case 25:
                    let h = Int(try uint(2))
                    let exp = (h >> 10) & 0x1F
                    let mant = Double(h & 0x3FF)
                    let mag: Double = exp == 0 ? mant * pow(2, -24) : exp == 31 ? (mant == 0 ? .infinity : .nan) : (mant + 1024) * pow(2, Double(exp - 25))
                    return .float(h & 0x8000 != 0 ? -mag : mag)
                case 26: return .float(Double(Float(bitPattern: UInt32(try uint(4)))))
                case 27: return .float(Double(bitPattern: try uint(8)))
                case 24: return .simple(try byte())
                default: return .simple(info)
                }
            }
        }
    }

    subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        for (k, v) in pairs { if case .text(let s) = k, s == key { return v } }
        return nil
    }

    var int: Int? {
        switch self {
        case .uint(let v): return Int(exactly: v)
        case .nint(let v): return Int(exactly: v).map { -1 - $0 }
        case .float(let d): return Int(exactly: d)
        case .tag(_, let inner): return inner.int
        default: return nil
        }
    }

    var string: String? { if case .text(let s) = self { return s } else { return nil } }
    var array: [CBOR] { if case .array(let a) = self { return a } else { return [] } }
}

enum Gzip {
    struct Malformed: Error {}

    /// a .gz file's contents. apple's zlib codec is raw deflate, so the gzip wrapper comes off by hand
    static func decompress(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw Malformed() }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard i + 2 <= b.count else { throw Malformed() }
            let extra = Int(b[i]) | (Int(b[i + 1]) << 8)
            i += 2 + extra
        }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 } // FNAME
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 } // FCOMMENT
        if flags & 0x02 != 0 { i += 2 } // FHCRC
        guard i < b.count - 8 else { throw Malformed() }
        let deflate = Data(b[i..<(b.count - 8)])
        return try (deflate as NSData).decompressed(using: .zlib) as Data
    }
}

struct UnknownTimetableFormat: Error {
    let format: Int
}

/// the gzipped cbor straight off the cdn
func decodeTimetable(_ gz: Data) throws -> Timetable {
    let w = try CBOR.decode(try Gzip.decompress(gz))
    let format = w["format"]?.int ?? -1
    if format != 1 { throw UnknownTimetableFormat(format: format) }
    let strings = (w["strings"]?.array ?? []).map { $0.string ?? "" }
    func s(_ c: CBOR?) -> String {
        guard let i = c?.int, i >= 0, i < strings.count else { return "" }
        return strings[i]
    }
    func t(_ c: CBOR?) -> Clock {
        let m = c?.int ?? 0
        return Clock(hour: m / 60 % 24, minute: m % 60)
    }
    // text fields are indices into strings, -1 for none. times are minutes from midnight
    let events: [Klass] = (w["events"]?.array ?? []).map { e in
        let f = e.array
        func at(_ i: Int) -> CBOR? { i < f.count ? f[i] : nil }
        let category = s(at(8))
        return Klass(
            day: (at(0)?.int ?? 0) + 1, start: t(at(1)), end: t(at(2)), subject: s(at(3)), code: s(at(4)), teacher: s(at(5)),
            venue: s(at(6)), type: s(at(7)), category: category.isEmpty ? nil : category, elective: (at(9)?.int ?? 0) != 0,
            batches: (at(10)?.array ?? []).map { s($0) }
        )
    }
    func name(_ c: CBOR) -> (String, String) { (c["id"]?.string ?? "", c["name"]?.string ?? "") }
    let courses = (w["courses"]?.array ?? []).map { c -> Timetable.Course in
        let (cid, cname) = name(c)
        return Timetable.Course(id: cid, name: cname, semesters: (c["semesters"]?.array ?? []).map { sem in
            let (sid, sname) = name(sem)
            return Timetable.Semester(id: sid, name: sname, phases: (sem["phases"]?.array ?? []).map { p in
                let (pid, pname) = name(p)
                return Timetable.Phase(id: pid, name: pname, batches: (p["batches"]?.array ?? []).map { b in
                    let (bid, bname) = name(b)
                    let classes = (b["events"]?.array ?? []).compactMap { $0.int }.filter { events.indices.contains($0) }.map { events[$0] }
                    return Timetable.Batch(id: bid, name: bname, classes: classes)
                })
            })
        })
    }
    return Timetable(version: w["version"]?.string ?? "", courses: courses)
}

/// the planner's timetable. it's the same file for every student, so it sits in
/// its own file instead of the cache and outlives sign out. paints from disk,
/// asks github at most once a day, and only downloads when the etag moved.
/// stand stands in for the network, the demo student's made up week.
@MainActor
@Observable
final class TimetableSource {
    private(set) var state = Resource<Timetable>()

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let stand: () -> Timetable?
    // which one we painted, the demo's week or the file, so signing in or out of the demo repaints
    @ObservationIgnored private var painted: Bool?
    @ObservationIgnored private var inflight: Task<Void, Never>?

    private static let source = URL(string: "https://raw.githubusercontent.com/codelif/jiit-planner-cdn/main/planner.cbor.gz")!
    private static let day: TimeInterval = 24 * 3600

    init(stand: @escaping () -> Timetable?) {
        self.stand = stand
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("planner.cbor.gz")
    }

    private var checkedAt: Date? {
        get { defaults.object(forKey: "planner.checked") as? Date }
        set { defaults.set(newValue, forKey: "planner.checked") }
    }

    private func loadDisk() async {
        let fake = stand()
        if painted == (fake != nil) { return }
        painted = fake != nil
        if let fake {
            state = Resource(data: fake, fetchedAt: Date(), checked: true)
            return
        }
        let file = file
        let t: Timetable? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decodeTimetable(data)
        }.value
        state = Resource(data: t, fetchedAt: t != nil ? checkedAt : nil, checked: true)
    }

    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never> {
        if let t = inflight { return t }
        let t = Task { @MainActor in
            await self.run(force: force)
            self.inflight = nil
        }
        inflight = t
        return t
    }

    private func run(force: Bool) async {
        await loadDisk()
        if painted == true { return }
        let have = state.data != nil
        if !force, have, let c = checkedAt, Date().timeIntervalSince(c) < TimetableSource.day { return }
        state.refreshing = true
        do {
            let fresh = try await fetch(have: have)
            let now = Date()
            checkedAt = now
            state = Resource(data: fresh ?? state.data, fetchedAt: now, refreshing: false, error: nil, checked: true)
        } catch is CancellationError {
            state.refreshing = false
        } catch {
            DebugLog.record("planner", error)
            state.refreshing = false
            state.error = error
        }
    }

    /// nil when the etag still matches
    private func fetch(have: Bool) async throws -> Timetable? {
        var req = URLRequest(url: TimetableSource.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("JPortal-iOS/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")", forHTTPHeaderField: "User-Agent")
        // an etag with no file behind it would get a 304 and nothing to draw
        if have, let etag = defaults.string(forKey: "planner.etag") { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            // so the notice says offline and shows the right icon
            throw PortalError.network(e.localizedDescription, timedOut: e.code == .timedOut)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 304 { return nil }
        if code != 200 { throw PortalError.serverUnavailable(code: code, shape: "github") }
        // decoded before it's saved, a broken download never replaces a good file
        let t = try await Task.detached(priority: .userInitiated) { try decodeTimetable(data) }.value
        try data.write(to: file, options: .atomic)
        defaults.set((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), forKey: "planner.etag")
        return t
    }

    /// signing in or out of the demo swaps which week is drawn
    func repaint() {
        painted = nil
        refresh()
    }
}
