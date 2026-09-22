import Testing
@testable import TeamsCore

/// Rules editor UX model: descriptions, goal picker mapping, row
/// sentences, plain-words validation. GUI layout itself is
/// owner-verified; these pin the strings the GUI shows.
@Suite("Rules editor UX")
struct RulesUXTests {
    // MARK: descriptions for every kind + custom fallback

    @Test func explanationsExistForAllKnownKinds() {
        var seen = Set<String>()
        for k in NotifyRule.knownKinds {
            let e = NotifyRule.explanation(for: k)
            #expect(!e.isEmpty)
            #expect(e.contains(" "), "explanation must be words: \(e)")
            #expect(e.hasSuffix("."), "explanation must be full sentences: \(e)")
            #expect(!e.contains(k), "explanation must not show raw id: \(e)")
            #expect(e.split(separator: "\n").count <= 3, "2-3 lines max: \(e)")
            #expect(e.count <= 240, "must fit 2-3 editor lines: \(e)")
            seen.insert(e)
        }
        #expect(seen.count == NotifyRule.knownKinds.count, "each kind needs its own description")
    }

    @Test func customExplanationFallback() {
        let e = NotifyRule.explanation(for: "my-future-rule")
        #expect(!e.isEmpty)
        #expect(e.contains("stored") && e.contains("not enforced yet"))
        #expect(NotifyRule.explanation(for: "Some Custom Text").contains("not enforced yet"))
    }

    @Test func legacyIDsResolveThroughNewHelpers() {
        for (legacy, id) in NotifyRule.legacyKinds {
            #expect(NotifyRule.explanation(for: legacy) == NotifyRule.explanation(for: id))
            #expect(NotifyRule.exampleText(for: legacy) == NotifyRule.exampleText(for: id))
            #expect(NotifyRule.goalTitle(for: legacy) == NotifyRule.goalTitle(for: id))
            #expect(NotifyRule.sentence(for: NotifyRule(kind: legacy, value: "v"))
                == NotifyRule.sentence(for: NotifyRule(kind: id, value: "v")))
        }
    }

    // MARK: examples

    @Test func examplesForValueKindsOnly() {
        for k in NotifyRule.knownKinds {
            let x = NotifyRule.exampleText(for: k)
            if NotifyRule.usesValue(k) {
                #expect(!x.isEmpty, "\(k) reads a value so it needs an example")
                #expect(x.hasSuffix("."), "example must be a full sentence: \(x)")
            } else {
                #expect(x.isEmpty, "\(k) ignores its value so no example: \(x)")
            }
        }
        #expect(NotifyRule.exampleText(for: "custom").isEmpty)
    }

    // MARK: goal picker maps to the right kind

    @Test func goalOptionsMapToRightKind() {
        let opts = NotifyRule.goalOptions
        #expect(opts.count == NotifyRule.knownKinds.count)
        #expect(opts.map(\.kind) == NotifyRule.knownKinds)
        var goals = Set<String>()
        for o in opts {
            #expect(!o.goal.isEmpty)
            #expect(o.goal.contains(" "), "goal must be plain words: \(o.goal)")
            #expect(o.goal != o.kind && !o.goal.contains(o.kind), "goal must not look like an id: \(o.goal)")
            #expect(!o.does.isEmpty && o.does.hasSuffix("."))
            #expect(o.does == NotifyRule.explanation(for: o.kind))
            #expect(o.example == NotifyRule.exampleText(for: o.kind))
            goals.insert(o.goal)
        }
        #expect(goals.count == opts.count, "goal titles must be unique")
    }

    @Test func pickedRulesAreValidImmediately() {
        for o in NotifyRule.goalOptions {
            let r = NotifyRule(kind: o.kind, value: NotifyRule.defaultValue(for: o.kind))
            #expect(r.isValid, "goal pick must add a valid rule: \(o.kind)")
        }
        #expect(NotifyRule.defaultValue(for: NotifyRule.messageTypes) == "Text, RichText")
        #expect(NotifyRule.defaultValue(for: NotifyRule.noisyChats) == "Watercooler")
        #expect(NotifyRule.defaultValue(for: NotifyRule.skipEdited) == "")
    }

    // MARK: readable rows

    @Test func sentencesReadableWordsNotTuples() {
        let samples: [NotifyRule] = [
            NotifyRule(kind: NotifyRule.skipMyMessages),
            NotifyRule(kind: NotifyRule.messageTypes, value: "Text, RichText"),
            NotifyRule(kind: NotifyRule.skipEdited),
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler"),
            NotifyRule(kind: NotifyRule.noisyChannel),
            NotifyRule(kind: NotifyRule.nameBackup),
        ]
        var seen = Set<String>()
        for r in samples {
            let s = NotifyRule.sentence(for: r)
            #expect(!s.isEmpty)
            #expect(s.hasSuffix("."), "row must read as words: \(s)")
            #expect(!s.contains(r.kind), "row must not show raw id: \(s)")
            if NotifyRule.usesValue(r.kind) {
                #expect(s.contains(r.value), "row must include the value: \(s)")
            }
            seen.insert(s)
        }
        #expect(seen.count == samples.count)
    }

    @Test func customSentenceNamesKindAndValue() {
        #expect(NotifyRule.sentence(for: NotifyRule(kind: "my-future-rule", value: "x=1")).contains("my-future-rule"))
        #expect(NotifyRule.sentence(for: NotifyRule(kind: "my-future-rule", value: "x=1")).contains("x=1"))
        #expect(NotifyRule.sentence(for: NotifyRule(kind: "my-future-rule")).contains("not enforced yet"))
    }

    // MARK: blank state teaches

    @Test func blankStateTeaches() {
        let t = NotifyRule.blankStateText
        #expect(t.contains("blank") || t.contains("Blank"))
        #expect(t.contains("every message notifies"))
        #expect(t.contains("Add"))
        #expect(t.contains("skip"))
    }

    // MARK: plain-words validation, same validity

    @Test func plainIssueMatchesValidity() {
        let battery = [
            NotifyRule(kind: NotifyRule.skipMyMessages),
            NotifyRule(kind: NotifyRule.messageTypes, value: "Text"),
            NotifyRule(kind: NotifyRule.messageTypes, value: "  "),
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler"),
            NotifyRule(kind: NotifyRule.noisyChats, value: ""),
            NotifyRule(kind: NotifyRule.noisyChannel),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "  "),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch"),
            NotifyRule(kind: NotifyRule.keywordBlock, value: ""),
            NotifyRule(kind: ""),
            NotifyRule(kind: "  "),
            NotifyRule(kind: "anything-new"),
            NotifyRule(kind: "loud-chat", value: ""),
            NotifyRule(kind: "allow-types", value: "Text"),
        ]
        for r in battery {
            #expect((r.plainIssue() == nil) == (r.issue() == nil), "validity must match issue(): \(r)")
        }
    }

    @Test func plainIssueUsesDisplayNames() {
        let types = NotifyRule(kind: NotifyRule.messageTypes, value: "").plainIssue() ?? ""
        #expect(types.contains("Only these message types"))
        #expect(!types.contains("only-these-message-types"))
        #expect(types.contains("Text, RichText"))
        let noisy = NotifyRule(kind: NotifyRule.noisyChats, value: " ").plainIssue() ?? ""
        #expect(noisy.contains("Noisy chats mention only"))
        #expect(!noisy.contains("noisy-chats-mention-only"))
        #expect(noisy.contains("Watercooler"))
        let empty = NotifyRule(kind: "").plainIssue() ?? ""
        #expect(!empty.isEmpty)
    }
}
