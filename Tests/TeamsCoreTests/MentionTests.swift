import Testing
@testable import TeamsCore

@Suite("Mentions")
struct MentionTests {
    let ownerMRI = "8:orgid:11111111-2222-3333-4444-555555555555"
    let ownerName = "Alex Rivera"

    // MARK: properties-array shapes

    @Test func propertiesArray() {
        let props: [String: Any] = ["mentions": [
            ["itemid": "0", "mri": ownerMRI, "mentionType": "person", "displayName": ownerName],
        ]]
        let ms = Mentions.parse(properties: props, content: "")
        #expect(ms.count == 1)
        #expect(ms[0].mri == ownerMRI)
        #expect(Mentions.mentionsOwner(ms, ownerMRI: ownerMRI, ownerDisplayName: ownerName))
    }

    @Test func propertiesJSONString() {
        let props = #"{"mentions":[{"itemid":"0","mri":"8:orgid:aaa","displayName":"Alice"}]}"#
        let ms = Mentions.parse(properties: props, content: "")
        #expect(ms == [Mention(id: "0", mri: "8:orgid:aaa", displayName: "Alice")])
    }

    @Test func mentionsJSONStringInsideDict() {
        let props: [String: Any] = ["mentions": #"[{"itemid":0,"mri":"8:orgid:aaa","displayName":"Alice"}]"#]
        let ms = Mentions.parse(properties: props, content: "")
        #expect(ms.count == 1 && ms[0].id == "0")
    }

    @Test func intItemID() {
        let props: [String: Any] = ["mentions": [["itemid": 3, "displayName": "X"]]]
        #expect(Mentions.parse(properties: props, content: "").first?.id == "3")
    }

    @Test func skipsEntriesWithoutItemID() {
        let props: [String: Any] = ["mentions": [
            ["mri": "8:orgid:aaa", "displayName": "Alice"],
            ["itemid": "1", "displayName": "Bob"],
        ]]
        let ms = Mentions.parse(properties: props, content: "")
        #expect(ms.count == 1 && ms[0].id == "1")
    }

    @Test func tagMentionKept() {
        let props: [String: Any] = ["mentions": [["itemid": "0", "mri": "tag:eng", "mentionType": "tag", "displayName": "Engineering"]]]
        let ms = Mentions.parse(properties: props, content: "")
        #expect(ms.count == 1 && ms[0].mri == "tag:eng")
        #expect(!Mentions.mentionsOwner(ms, ownerMRI: ownerMRI, ownerDisplayName: ownerName))
        #expect(!Mentions.mentionsChannelOrEveryone(ms))
    }

    @Test func malformedYieldsEmpty() {
        #expect(Mentions.parse(properties: "not-json", content: "") == [])
        #expect(Mentions.parse(properties: ["mentions": "not-json"], content: "") == [])
        #expect(Mentions.parse(properties: nil, content: "plain text") == [])
    }

    // MARK: content-span fallback

    @Test func spanFallback() {
        let content = #"<span itemtype="http://schema.skype.com/Mention" itemscope itemid="0">Alice</span> hi"#
        let ms = Mentions.parse(properties: nil, content: content)
        #expect(ms == [Mention(id: "0", mri: nil, displayName: "Alice")])
    }

    @Test func spanFallbackAttributeOrder() {
        // itemid before itemtype, single quotes
        let content = #"<span itemid='2' class="x" itemtype='http://schema.skype.com/Mention'>Bob</span>"#
        let ms = Mentions.parse(properties: nil, content: content)
        #expect(ms.count == 1 && ms[0].id == "2" && ms[0].displayName == "Bob")
    }

    @Test func spanWithoutItemIDSkipped() {
        let content = #"<span itemtype="http://schema.skype.com/Mention">Nobody</span>"#
        #expect(Mentions.parse(properties: nil, content: content) == [])
    }

    @Test func propertiesPreferredOverSpans() {
        let props: [String: Any] = ["mentions": [["itemid": "0", "mri": "8:orgid:aaa", "displayName": "Alice"]]]
        let content = #"<span itemtype="http://schema.skype.com/Mention" itemid="0">Alice</span><span itemtype="http://schema.skype.com/Mention" itemid="9">Ghost</span>"#
        #expect(Mentions.parse(properties: props, content: content).count == 1)
    }

    // MARK: owner matching

    @Test func mriMatchCaseInsensitive() {
        let ms = [Mention(id: "0", mri: ownerMRI.uppercased(), displayName: "Someone Else")]
        #expect(Mentions.mentionsOwner(ms, ownerMRI: ownerMRI, ownerDisplayName: ownerName))
    }

    @Test func mriMismatchDoesNotFallBackToName() {
        // MRI present but different: not owner even if display name matches.
        let ms = [Mention(id: "0", mri: "8:orgid:other", displayName: ownerName)]
        #expect(!Mentions.mentionsOwner(ms, ownerMRI: ownerMRI, ownerDisplayName: ownerName))
    }

    @Test func nameFallbackWhenNoMRI() {
        let ms = [Mention(id: "0", mri: nil, displayName: "  alex rivera ")]
        #expect(Mentions.mentionsOwner(ms, ownerMRI: ownerMRI, ownerDisplayName: ownerName))
        #expect(Mentions.mentionsOwner(ms, ownerMRI: nil, ownerDisplayName: ownerName))
    }

    @Test func emptyNameNeverMatches() {
        let ms = [Mention(id: "0", mri: nil, displayName: "Alice")]
        #expect(!Mentions.mentionsOwner(ms, ownerMRI: nil, ownerDisplayName: ""))
    }

    // MARK: channel / everyone

    @Test func channelMentionTypes() {
        for t in ["channel", "Channel", "CHANNEL", "everyone", "team", "channelmessage"] {
            let ms = [Mention(id: "0", mri: nil, mentionType: t, displayName: "x")]
            #expect(Mentions.mentionsChannelOrEveryone(ms), "type \(t)")
        }
    }

    @Test func channelDisplayNameFallback() {
        for n in ["channel", "Channel", " everyone ", "Team"] {
            let ms = [Mention(id: "0", mri: nil, displayName: n)]
            #expect(Mentions.mentionsChannelOrEveryone(ms), "name \(n)")
        }
    }

    @Test func personMentionIsNotChannel() {
        let ms = [Mention(id: "0", mri: ownerMRI, mentionType: "person", displayName: ownerName)]
        #expect(!Mentions.mentionsChannelOrEveryone(ms))
    }
}
