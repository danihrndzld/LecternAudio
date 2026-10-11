import Testing
@testable import AudibleCore

@Test func convertsSummaryHTMLToMarkdown() {
    let html = "<p><i>What if</i> one collection&#39;s <b>Plato</b> &amp; more?</p><p>Second<br/>line</p><ul><li>One</li><li>Two</li></ul>"
    #expect(HTMLText.markdown(html) == "*What if* one collection's **Plato** & more?\n\nSecond\nline\n\n- One\n- Two")
}

@Test func decodesSpanishEntities() {
    #expect(HTMLText.markdown("Consagraci&oacute;n a San Jos&eacute;") == "Consagración a San José")
}
