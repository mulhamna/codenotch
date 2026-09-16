import Foundation

/// Codex limits read out of Chromium browser and ChatGPT desktop caches.
///
/// A fallback source for Codex usage when local CLI credentials (`~/.codex/auth.json`)
/// are missing or expired. When a user uses ChatGPT on the web (Google Chrome, Brave,
/// Arc, Edge, Chromium) or in the ChatGPT desktop application, the response from
/// `GET https://chatgpt.com/backend-api/wham/usage` is stored in a Chromium Simple Cache
/// entry on disk. This reads that entry without requiring CLI login, keychain tokens,
/// or subprocesses.
struct CodexBrowserUsageCache: Sendable {
    /// One reading, and where it came from.
    struct Reading: Equatable, Sendable {
        let windows: [LimitWindow]
        let plan: String?
        let capturedAt: Date
        let entry: URL

        /// Whether these numbers may still be presented as live.
        func isFresh(at now: Date = Date(), within window: TimeInterval = 30 * 60) -> Bool {
            let age = now.timeIntervalSince(capturedAt)
            return age < window && age > -window
        }
    }

    /// Where Chromium browsers and ChatGPT desktop keep HTTP caches.
    let directories: [URL]

    static func candidateDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var dirs: [URL] = []

        // ChatGPT Desktop application cache
        let desktopApp = home.appendingPathComponent("Library/Application Support/ChatGPT/Cache/Cache_Data", isDirectory: true)
        if FileManager.default.fileExists(atPath: desktopApp.path) {
            dirs.append(desktopApp)
        }
        let desktopCaches = home.appendingPathComponent("Library/Caches/com.openai.chat/Cache/Cache_Data", isDirectory: true)
        if FileManager.default.fileExists(atPath: desktopCaches.path) {
            dirs.append(desktopCaches)
        }

        let cacheRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let browserSubpaths = [
            "Google/Chrome",
            "BraveSoftware/Brave-Browser",
            "Microsoft Edge",
            "Arc/User Data",
            "Chromium",
        ]
        for sub in browserSubpaths {
            let base = cacheRoot.appendingPathComponent(sub, isDirectory: true)
            let defaultCache = base.appendingPathComponent("Default/Cache/Cache_Data", isDirectory: true)
            if FileManager.default.fileExists(atPath: defaultCache.path) {
                dirs.append(defaultCache)
            }
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
                for name in contents where name.hasPrefix("Profile ") {
                    let profileCache = base.appendingPathComponent("\(name)/Cache/Cache_Data", isDirectory: true)
                    if FileManager.default.fileExists(atPath: profileCache.path) {
                        dirs.append(profileCache)
                    }
                }
            }
        }
        return dirs
    }

    init(directories: [URL] = CodexBrowserUsageCache.candidateDirectories()) {
        self.directories = directories
    }

    init(directory: URL) {
        self.directories = [directory]
    }

    // MARK: - Limits

    static let maxEntryBytes = 512 * 1024
    static let maxEntriesExamined = 400
    static let maxDecompressedBytes = 256 * 1024
    static let maxKeyBytes = 8 * 1024

    // MARK: - Reading

    /// The most recent usable reading for Codex, or nil.
    func read(now: Date = Date(), includeExtras: Bool = false) -> Reading? {
        var freshest: Reading?
        for directory in directories {
            if let entry = recentEntries(in: directory)
                .lazy
                .compactMap({ reading(from: $0, now: now, includeExtras: includeExtras) })
                .first {
                if let current = freshest {
                    if entry.capturedAt > current.capturedAt {
                        freshest = entry
                    }
                } else {
                    freshest = entry
                }
            }
        }
        return freshest
    }

    private func recentEntries(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        let candidates: [(url: URL, modified: Date)] = names.compactMap { url in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > Self.headerBytes, size <= Self.maxEntryBytes,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(Self.maxEntriesExamined)
            .map(\.url)
    }

    private func reading(from entry: URL, now: Date, includeExtras: Bool) -> Reading? {
        guard let file = contents(of: entry),
              let parsed = Self.parse(entry: file.bytes)
        else { return nil }

        guard let windows = try? CodexUsage.windows(from: parsed.body, includeExtras: includeExtras),
              !windows.isEmpty
        else { return nil }

        let plan = CodexUsage.plan(from: parsed.body)
        return Reading(
            windows: windows,
            plan: plan,
            capturedAt: parsed.date ?? file.modified ?? now,
            entry: entry
        )
    }

    private func contents(of entry: URL) -> (bytes: Data, modified: Date?)? {
        guard let handle = try? FileHandle(forReadingFrom: entry) else { return nil }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: Self.headerBytes + Self.maxKeyBytes),
              let key = Self.key(in: [UInt8](head)),
              Self.isUsageKey(key)
        else { return nil }

        try? handle.seek(toOffset: 0)
        guard let bytes = try? handle.read(upToCount: Self.maxEntryBytes) else { return nil }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return (bytes, nil) }
        let modified = Date(timeIntervalSince1970:
            TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (bytes, modified)
    }

    // MARK: - The entry format

    static let headerBytes = 24
    private static let entryMagic: UInt64 = 0xfcfb_6d1b_a772_5c30
    private static let zstdMagic: [UInt8] = [0x28, 0xb5, 0x2f, 0xfd]

    struct Parsed: Equatable {
        let body: Data
        let date: Date?
    }

    static func parse(entry bytes: Data) -> Parsed? {
        let entry = [UInt8](bytes)

        guard let key = key(in: entry),
              isUsageKey(key)
        else { return nil }

        let bodyStart = headerBytes + key.utf8.count
        guard entry.count > bodyStart else { return nil }

        let payload = Array(entry[bodyStart...])

        // Check if zstd compressed
        if payload.count >= zstdMagic.count && Array(payload[0..<zstdMagic.count]) == zstdMagic {
            guard let body = decompress(frame: payload) else { return nil }
            let trailer = Array(payload[body.frameSize...])
            return Parsed(body: body.data, date: httpDate(inTrailer: trailer))
        }

        // Check if uncompressed JSON
        if let first = payload.first, first == 0x7B /* '{' */ {
            if let lastBrace = payload.lastIndex(of: 0x7D /* '}' */) {
                let jsonBytes = Array(payload[0...lastBrace])
                let data = Data(jsonBytes)
                if (try? JSONSerialization.jsonObject(with: data)) != nil {
                    let trailer = Array(payload[(lastBrace + 1)...])
                    return Parsed(body: data, date: httpDate(inTrailer: trailer))
                }
            }
        }

        return nil
    }

    static func key(in entry: [UInt8]) -> String? {
        guard entry.count > headerBytes,
              readUInt64(entry, at: 0) == entryMagic
        else { return nil }
        let keyLength = Int(readUInt32(entry, at: 12))
        guard keyLength > 0, keyLength <= maxKeyBytes,
              headerBytes + keyLength <= entry.count
        else { return nil }
        return String(bytes: entry[headerBytes..<(headerBytes + keyLength)], encoding: .utf8)
    }

    static func isUsageKey(_ key: String) -> Bool {
        guard key.contains("chatgpt.com") || key.contains("openai.com") else { return false }
        guard let usageRange = key.range(of: "/backend-api/wham/usage") else { return false }
        let after = key[usageRange.upperBound...]
        return after.isEmpty || after.hasPrefix("?") || after.hasPrefix("#")
    }

    private static func httpDate(inTrailer bytes: [UInt8]) -> Date? {
        guard !bytes.isEmpty else { return nil }

        let markers: [[UInt8]] = [
            [0x64, 0x61, 0x74, 0x65, 0x3a], // "date:"
            [0x44, 0x61, 0x74, 0x65, 0x3a]  // "Date:"
        ]
        var lineStart: Int?
        for marker in markers {
            if let index = firstIndex(of: marker, in: bytes) {
                lineStart = index + marker.count
                break
            }
        }
        guard let lineStart else { return nil }

        var lineEnd = bytes.count
        for index in lineStart..<bytes.count {
            let byte = bytes[index]
            if byte == 0x00 || byte == 0x0a || byte == 0x0d {
                lineEnd = index
                break
            }
        }
        guard lineEnd > lineStart else { return nil }

        let slice = bytes[lineStart..<lineEnd]
        guard let string = String(bytes: slice, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !string.isEmpty
        else { return nil }

        return httpDateFormatter.date(from: string)
    }

    private struct Frame {
        let data: Data
        let frameSize: Int
    }

    private static func decompress(frame bytes: [UInt8]) -> Frame? {
        guard !bytes.isEmpty else { return nil }

        return bytes.withUnsafeBytes { source -> Frame? in
            let compressed = ZSTD_findFrameCompressedSize(source.baseAddress, source.count)
            guard ZSTD_isError(compressed) == 0, compressed > 0, compressed <= source.count
            else { return nil }

            let declared = ZSTD_getFrameContentSize(source.baseAddress, source.count)
            if declared != ZSTD_CONTENTSIZE_UNKNOWN, declared != ZSTD_CONTENTSIZE_ERROR,
               declared > UInt64(maxDecompressedBytes) {
                return nil
            }

            var output = [UInt8](repeating: 0, count: maxDecompressedBytes)
            let written = output.withUnsafeMutableBytes { destination in
                ZSTD_decompress(destination.baseAddress, destination.count,
                                source.baseAddress, compressed)
            }
            guard ZSTD_isError(written) == 0, written > 0, written <= output.count else {
                return nil
            }
            return Frame(data: Data(output[0..<written]), frameSize: compressed)
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0..<4).reversed() { value = value << 8 | UInt32(bytes[offset + index]) }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
