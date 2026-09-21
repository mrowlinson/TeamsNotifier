import Foundation
import Testing
@testable import TeamsCore

@Suite("Log rotation policy")
struct LogRotationTests {
    @Test func caps() {
        #expect(LogRotation.maxBytes == 2 * 1024 * 1024)
        #expect(LogRotation.keepBytes == 500 * 1024)
    }

    @Test func needsRotationOnlyOverCap() {
        #expect(!LogRotation.needsRotation(fileSize: 0))
        #expect(!LogRotation.needsRotation(fileSize: LogRotation.maxBytes))
        #expect(LogRotation.needsRotation(fileSize: LogRotation.maxBytes + 1))
    }

    @Test func truncationOffsetKeepsTail() {
        #expect(LogRotation.truncationOffset(fileSize: 100) == 0)
        #expect(LogRotation.truncationOffset(fileSize: LogRotation.maxBytes + 1000)
            == LogRotation.maxBytes + 1000 - LogRotation.keepBytes)
    }

    @Test func rotatedTail() {
        let small = Data(repeating: 0x41, count: 100)
        #expect(LogRotation.rotatedTail(of: small) == small)
        var big = Data(repeating: 0x41, count: LogRotation.keepBytes + 10)
        big.append(Data(repeating: 0x42, count: 10))
        let tail = LogRotation.rotatedTail(of: big)
        #expect(tail.count == LogRotation.keepBytes)
        #expect(tail.suffix(10) == Data(repeating: 0x42, count: 10))
    }
}

@Suite("Status line builder")
struct StatusLineTests {
    @Test func includesNotifyAuth() {
        #expect(StatusLine.build(base: "connected", notifyRawValue: 2)
            == "connected · notify authorized")
        #expect(StatusLine.build(base: "connected", notifyRawValue: 1)
            == "connected · notify denied")
        #expect(StatusLine.build(base: "connected", notifyRawValue: 0)
            == "connected · notify undetermined")
    }

    @Test func allLabels() {
        #expect(StatusLine.shortNotifyLabel(rawValue: 3) == "provisional")
        #expect(StatusLine.shortNotifyLabel(rawValue: 4) == "ephemeral")
        #expect(StatusLine.shortNotifyLabel(rawValue: 99) == "unknown (99)")
    }

    @Test func nilAuthLeavesBase() {
        #expect(StatusLine.build(base: "starting…", notifyRawValue: nil) == "starting…")
    }

    @Test func diagnosticsText() {
        let text = StatusLine.diagnostics(
            authLabel: "authorized", trouterState: "connected",
            lastLines: ["a", "b"])
        #expect(text.contains("notify: authorized"))
        #expect(text.contains("trouter: connected"))
        #expect(text.contains("last 2 log lines"))
        #expect(text.hasSuffix("a\nb"))
    }
}
