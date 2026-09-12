import XCTest

/// The catalog's source language is English. A missing translation in any
/// other language must fall back to that English, not fail the suite — the
/// app's language is English, and a half-finished locale must not block CI.
final class CatalogCoverageTests: XCTestCase {
    func testSourceLanguageIsEnglish() throws {
        XCTAssertEqual(try loadCatalog().json.sourceLanguage, "en")
    }

    func testTheCatalogHasKeys() throws {
        XCTAssertFalse(try loadCatalog().json.strings.isEmpty, "catalog has no strings")
    }

    func testCatalogHasNoMergeConflictMarkers() throws {
        XCTAssertFalse(
            try loadCatalog().raw.contains("<<<<<<"),
            "Localizable.xcstrings still has a leftover conflict marker"
        )
    }

    func testRussianCoreCopyIsTranslated() throws {
        let catalog = try loadCatalog().json
        let expected = [
            "just now": "только что",
            "Resets in %lld min": "Сброс через %lld мин",
            "%lld%% Used · %lld%% left": "Использовано %lld%% · осталось %lld%%",
            "Always show": "Всегда показывать",
            "Settings…": "Настройки…",
            "Sign in to %@": "Войти в %@",
            "%lld%% of its %@ limit used.": "Использовано %lld%% от лимита «%@»."
        ]

        for (key, value) in expected {
            XCTAssertEqual(
                catalog.strings[key]?.localizations?["ru"]?.stringUnit?.value,
                value,
                "missing Russian translation for \(key)"
            )
        }
    }


    /// There is deliberately no "language X covers every key" test.
    ///
    /// The rule at the top of this file is that a missing translation falls
    /// back to English rather than failing the suite, and no locale here is
    /// complete: French and Portuguese cover 350 of 470 keys, Japanese 428.
    /// #141 added one for Russian, which passed only while Russian happened to
    /// be complete — the next pull request to add a string broke it, and that
    /// is exactly the CI block the rule exists to prevent.

    // MARK: - Loading

    /// Repo `Tests/`, so the catalog is `../Sources/Localizable.xcstrings`.
    private func catalogURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Localizable.xcstrings")
            .standardizedFileURL
    }

    private func loadCatalog() throws -> (raw: String, json: CatalogFile) {
        let url = catalogURL()
        do {
            let data = try Data(contentsOf: url)
            return (String(decoding: data, as: UTF8.self), try JSONDecoder().decode(CatalogFile.self, from: data))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
            throw XCTSkip("macOS privacy restricts reading the source catalog at \(url.path)")
        }
    }
}

private struct CatalogFile: Decodable {
    var sourceLanguage: String
    var strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    var localizations: [String: CatalogLocalization]?
}

private struct CatalogLocalization: Decodable {
    var stringUnit: CatalogStringUnit?
}

private struct CatalogStringUnit: Decodable {
    var state: String?
    var value: String?
}
