import Testing
@testable import TeamsCore

@Suite("HTML strip")
struct HTMLTests {
    @Test func plainPassthrough() {
        #expect(HTML.strip("hello") == "hello")
    }

    @Test func dropsTags() {
        #expect(HTML.strip("<p>hi <b>there</b></p>") == "hi there")
    }

    @Test func decodesEntities() {
        #expect(HTML.strip("a &amp; b &lt;c&gt; &quot;q&quot; &#39;x&#39;") == "a & b <c> \"q\" 'x'")
    }

    @Test func decodesNumericEntities() {
        #expect(HTML.strip("&#65;&#x42;") == "AB")
    }

    @Test func preservesBreaks() {
        let html = "<p>line1</p><p>line2<br>line3</p>"
        #expect(HTML.stripPreservingBreaks(html) == "line1\nline2\nline3")
    }

    @Test func mentionSpanStripsToName() {
        let html = #"<span itemtype="http://schema.skype.com/Mention" itemscope itemid="0">Michael Rowlinson</span> hi"#
        #expect(HTML.strip(html) == "Michael Rowlinson hi")
    }

    @Test func trimsWhitespace() {
        #expect(HTML.strip("  <p>x</p>  ") == "x")
    }
}
