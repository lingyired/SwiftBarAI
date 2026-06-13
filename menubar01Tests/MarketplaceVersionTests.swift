// MarketplaceVersionTests.swift
// menubar01 — PluginMarketplace (M5 update-detection follow-up)
//
// Swift Testing coverage for `MarketplaceVersion` — the small
// semver-style struct the Installed tab uses to decide whether
// the catalogue is newer than the on-disk manifest. The
// contract under test:
//
//   1. The parser accepts `"1.2.3"`, `"v1.2.3"`, `"1.2"`, and
//      `"1"` and zero-fills the missing components.
//   2. The parser is permissive on a leading `v` / `V` (the
//      v1 catalogue ships Git-style tags) and rejects
//      unparseable input with `nil`.
//   3. The Comparable conformance walks major → minor → patch
//      in order so the comparison matches the natural
//      expectation of a `1.2.3 < 1.2.4 < 1.3.0 < 2.0.0`
//      ordering.
//   4. The struct is `Equatable` + `Hashable` + `Sendable` so
//      the value can flow between actors (the
//      `MarketplaceBrowserViewModel` is `@MainActor` but the
//      parser / comparator are intentionally callable from
//      any context).
//
// Target: 6 new tests, all passing.

import Foundation
import Testing

@testable import menubar01

struct MarketplaceVersionTests {

    // 1

    @Test func testVersion_parsing_simpleString() {
        // "1.2.3" parses to (1, 2, 3). The canonical case.
        let parsed = MarketplaceVersion(parsing: "1.2.3")
        #expect(parsed == MarketplaceVersion(major: 1, minor: 2, patch: 3))
    }

    // 2

    @Test func testVersion_parsing_withVPrefix() {
        // "v1.2.3" / "V1.2.3" / " v1.2.3 " all parse to
        // (1, 2, 3). The catalogue ships Git-style tag
        // strings; the parser is permissive on the prefix.
        for raw in ["v1.2.3", "V1.2.3", " v1.2.3 "] {
            let parsed = MarketplaceVersion(parsing: raw)
            #expect(parsed == MarketplaceVersion(major: 1, minor: 2, patch: 3),
                    "expected 1.2.3, got \(String(describing: parsed)) from \(raw)")
        }
    }

    // 3

    @Test func testVersion_parsing_shortForm() {
        // "1.2" → (1, 2, 0). "1" → (1, 0, 0). The parser
        // zero-fills missing components instead of failing.
        #expect(MarketplaceVersion(parsing: "1.2") == MarketplaceVersion(major: 1, minor: 2, patch: 0))
        #expect(MarketplaceVersion(parsing: "1") == MarketplaceVersion(major: 1, minor: 0, patch: 0))
    }

    // 4

    @Test func testVersion_parsing_invalid_returnsNil() {
        // Unparseable strings return nil. The Installed
        // tab's badge logic treats nil as `.unknown` and
        // suppresses the pill, so the parser must NOT
        // crash on bad input.
        for raw in ["", "abc", "v", "1.x.3", "..."] {
            #expect(MarketplaceVersion(parsing: raw) == nil,
                    "expected nil for \(raw)")
        }
    }

    // 5

    @Test func testVersion_comparison() {
        // 1.2.3 < 1.2.4 < 1.3.0 < 2.0.0. The comparator
        // walks major → minor → patch in order. A
        // regression here would silently mislabel every
        // Installed-tab row.
        let v123 = MarketplaceVersion(major: 1, minor: 2, patch: 3)
        let v124 = MarketplaceVersion(major: 1, minor: 2, patch: 4)
        let v130 = MarketplaceVersion(major: 1, minor: 3, patch: 0)
        let v200 = MarketplaceVersion(major: 2, minor: 0, patch: 0)
        #expect(v123 < v124)
        #expect(v124 < v130)
        #expect(v130 < v200)
        // And the comparators compose — `sorted()` uses
        // them in order.
        let unsorted = [v200, v130, v124, v123]
        #expect(unsorted.sorted() == [v123, v124, v130, v200])
    }

    // 6

    @Test func testVersion_equality() {
        // `1.2.3 == 1.2.3` and the corresponding hash
        // equality. The struct is used as a Set / Dict
        // key in the Installed-tab refresh path so the
        // synthesis must be stable.
        let a = MarketplaceVersion(major: 1, minor: 2, patch: 3)
        let b = MarketplaceVersion(major: 1, minor: 2, patch: 3)
        let c = MarketplaceVersion(major: 1, minor: 2, patch: 4)
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
        // `displayString` is the canonical round-trip
        // string used in the badge / detail label.
        #expect(a.displayString == "1.2.3")
        #expect(c.displayString == "1.2.4")
    }
}
