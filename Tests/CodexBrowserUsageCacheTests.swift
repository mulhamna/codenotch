import XCTest
@testable import Codenotch

final class CodexBrowserUsageCacheTests: XCTestCase {

    // MARK: - Fixtures

    /// Valid JSON response from ChatGPT `/backend-api/wham/usage`.
    static let validUsageJSON = """
    {
        "plan_type": "plus",
        "rate_limit": {
            "primary_window": {
                "used_percent": 34.0,
                "limit_window_seconds": 18000,
                "reset_at": 1757434328
            },
            "secondary_window": {
                "used_percent": 12.0,
                "limit_window_seconds": 604800,
                "reset_at": 1757900000
            }
        }
    }
    """.data(using: .utf8)!

    struct Entry {
        var magic: UInt64 = 0xfcfb_6d1b_a772_5c30
        var version: UInt32 = 5
        var declaredKeyLength: UInt32?
        var key = "1/0/https://chatgpt.com/backend-api/wham/usage"
        var body: Data = CodexBrowserUsageCacheTests.validUsageJSON
        var responseDate: String? = "Wed, 09 Sep 2026 16:12:08 GMT"

        func data() -> Data {
            var out = Data()
            withUnsafeBytes(of: magic.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: version.littleEndian) { out.append(contentsOf: $0) }
            let keyBytes = Data(key.utf8)
            withUnsafeBytes(of: (declaredKeyLength ?? UInt32(keyBytes.count)).littleEndian) {
                out.append(contentsOf: $0)
            }
            withUnsafeBytes(of: UInt32(0xdead_beef).littleEndian) { out.append(contentsOf: $0) }
            out.append(Data(repeating: 0, count: 4))
            out.append(keyBytes)
            out.append(body)
            out.append(trailer())
            return out
        }

        private func trailer() -> Data {
            var out = Data([0x01, 0x00, 0x00, 0x00])
            out.append(Data("HTTP/1.1 200".utf8))
            out.append(0)
            if let responseDate {
                out.append(Data("date:\(responseDate)".utf8))
                out.append(0)
            }
            out.append(contentsOf: [0, 0])
            return out
        }
    }

    static let fixtureDate: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 9
        components.hour = 16; components.minute = 12; components.second = 8
        components.timeZone = TimeZone(identifier: "GMT")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    // MARK: - Key parsing

    func testTheUsageKeyIsRecognised() {
        XCTAssertTrue(CodexBrowserUsageCache.isUsageKey("1/0/https://chatgpt.com/backend-api/wham/usage"))
        XCTAssertTrue(CodexBrowserUsageCache.isUsageKey("0/0/https://chatgpt.com/backend-api/wham/usage?include_extras=1"))
        XCTAssertTrue(CodexBrowserUsageCache.isUsageKey("https://openai.com/backend-api/wham/usage"))
        XCTAssertFalse(CodexBrowserUsageCache.isUsageKey("https://chatgpt.com/backend-api/conversations"))
        XCTAssertFalse(CodexBrowserUsageCache.isUsageKey("https://example.com/backend-api/wham/usage"))
    }

    // MARK: - Entry parsing

    func testAValidEntryYieldsTheSessionAndWeeklyWindows() throws {
        let parsed = try XCTUnwrap(CodexBrowserUsageCache.parse(entry: Entry().data()))
        let windows = try CodexUsage.windows(from: parsed.body)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.first?.id, "primary")
        XCTAssertEqual(windows.first?.usedFraction, 0.34)
        XCTAssertEqual(windows.last?.id, "secondary")
        XCTAssertEqual(windows.last?.usedFraction, 0.12)
        XCTAssertEqual(parsed.date, Self.fixtureDate)
    }

    func testKeysThatAreNotTheUsageEndpointAreIgnored() {
        var entry = Entry()
        entry.key = "1/0/https://chatgpt.com/backend-api/models"
        XCTAssertNil(CodexBrowserUsageCache.parse(entry: entry.data()))
    }

    func testFilesThatAreNotCacheEntriesAreIgnored() {
        var entry = Entry()
        entry.magic = 0x0102_0304_0506_0708
        XCTAssertNil(CodexBrowserUsageCache.parse(entry: entry.data()))
    }

    // MARK: - Directory scan

    func testTheMostRecentOfSeveralUsageEntriesWins() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let older = temp.appendingPathComponent("entry_older_0")
        let newer = temp.appendingPathComponent("entry_newer_0")

        var olderEntry = Entry()
        olderEntry.responseDate = "Wed, 09 Sep 2026 15:00:00 GMT"
        try olderEntry.data().write(to: older)

        var newerEntry = Entry()
        newerEntry.responseDate = "Wed, 09 Sep 2026 16:00:00 GMT"
        try newerEntry.data().write(to: newer)

        let cache = CodexBrowserUsageCache(directory: temp)
        let reading = try XCTUnwrap(cache.read())
        XCTAssertEqual(reading.windows.count, 2)
    }

    // MARK: - Freshness

    func testARecentSnapshotIsFresh() {
        let now = Date()
        let reading = CodexBrowserUsageCache.Reading(
            windows: [],
            plan: "plus",
            capturedAt: now.addingTimeInterval(-300),
            entry: URL(fileURLWithPath: "/tmp/test")
        )
        XCTAssertTrue(reading.isFresh(at: now, within: 1800))
    }

    func testASnapshotOlderThanTheWindowIsNotFresh() {
        let now = Date()
        let reading = CodexBrowserUsageCache.Reading(
            windows: [],
            plan: "plus",
            capturedAt: now.addingTimeInterval(-2000),
            entry: URL(fileURLWithPath: "/tmp/test")
        )
        XCTAssertFalse(reading.isFresh(at: now, within: 1800))
    }
}
