import Testing
@testable import TeamsCore

/// Rules display names: the picker shows plain English, stores ids.
@Suite("Rules display names")
struct RulesDisplayTests {
    /// Exact id -> display map (owner-visible picker text).
    let expected = [
        (NotifyRule.skipMyMessages, "Skip my own messages"),
        (NotifyRule.messageTypes, "Only these message types"),
        (NotifyRule.skipEdited, "Skip edited messages"),
        (NotifyRule.noisyChats, "Noisy chats mention only"),
        (NotifyRule.noisyChannel, "Noisy chats channel mentions"),
        (NotifyRule.nameBackup, "My name as backup"),
        (NotifyRule.keywordAllow, "Always notify keywords"),
        (NotifyRule.keywordBlock, "Never notify keywords"),
    ]

    // MARK: (a) every known kind has a non-ID display name

    @Test func knownKindsHavePlainEnglishNames() {
        #expect(NotifyRule.knownKinds.count == expected.count)
        for (id, name) in expected {
            let got = NotifyRule.displayName(for: id)
            #expect(got == name)
            #expect(got != id)
            #expect(!got.contains("-"), "display name must not look like an id: \(got)")
            #expect(got.contains(" "), "display name must be words: \(got)")
        }
    }

    @Test func displayNamesUnique() {
        let names = NotifyRule.knownDisplayNames
        #expect(names.count == NotifyRule.knownKinds.count)
        #expect(Set(names).count == names.count)
    }

    // MARK: (b) round-trip both directions + legacy + custom

    @Test func displayRoundTripsBothDirections() {
        for (id, name) in expected {
            #expect(NotifyRule.kind(fromDisplayName: name) == id)
            #expect(NotifyRule.displayName(for: NotifyRule.kind(fromDisplayName: name)) == name)
        }
        // Pasted ids still resolve (tolerant input).
        for (id, _) in expected {
            #expect(NotifyRule.kind(fromDisplayName: id) == id)
        }
        // Case-insensitive display match.
        #expect(NotifyRule.kind(fromDisplayName: "skip my own messages") == NotifyRule.skipMyMessages)
    }

    @Test func legacyIDsResolveThroughDisplay() {
        for (legacy, id) in NotifyRule.legacyKinds {
            #expect(NotifyRule.displayName(for: legacy) == NotifyRule.displayName(for: id))
            #expect(NotifyRule.kind(fromDisplayName: legacy) == id)
        }
    }

    @Test func customKindsPassThrough() {
        #expect(NotifyRule.displayName(for: "my-future-rule") == "my-future-rule")
        #expect(NotifyRule.kind(fromDisplayName: "my-future-rule") == "my-future-rule")
        #expect(NotifyRule.displayName(for: "Some Custom Text") == "Some Custom Text")
        #expect(NotifyRule.kind(fromDisplayName: "Some Custom Text") == "Some Custom Text")
    }
}
