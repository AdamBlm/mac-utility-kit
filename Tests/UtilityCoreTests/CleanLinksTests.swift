import Testing
import UtilityCore

struct CleanLinksTests {
    @Test func preservesFunctionalQueryBytesAndFragment() throws {
        let input = "https://example.test/search?q=a%2fb+z&UTM_Source=news&flag&v=%2B&fbclid=gone#page%2f2"
        let result = try CleanLinks.clean(input)
        #expect(result.cleaned == "https://example.test/search?q=a%2fb+z&flag&v=%2B#page%2f2")
        #expect(result.removedParameters == ["UTM_Source", "fbclid"])
    }

    @Test func preservesInternationalizedAddressAndFunctionalQuery() throws {
        let result = try CleanLinks.clean("https://bücher.example/été?q=東京%2f+été&utm_source=x&\u{301}tag=λ#章节")
        #expect(result.cleaned == "https://bücher.example/été?q=東京%2f+été&\u{301}tag=λ#章节")
        #expect(result.removedParameters == ["utm_source"])
        let signed = "https://bücher.example/été?X-Amz-Signature=123&utm_source=keep#章节"
        #expect(try CleanLinks.clean(signed).cleaned == signed)
    }

    @Test func unwrapsOnlyRecognizedRedirectsAndPreservesSignedLinks() throws {
        let redirected = try CleanLinks.clean("https://www.google.com/url?q=https%3A%2F%2Fexample.test%2F%3Futm_source%3Dx%26id%3D4")
        #expect(redirected.redirectDestination == "https://example.test/?utm_source=x&id=4")
        #expect(redirected.cleaned == "https://example.test/?id=4")
        let lookalike = "https://google.com.example.test/url?q=https%3A%2F%2Fexample.test"
        #expect(try CleanLinks.clean(lookalike).cleaned == lookalike)
        let signed = "https://example.test/file?X-Amz-Signature=123&utm_source=included"
        #expect(try CleanLinks.clean(signed).cleaned == signed)
    }

    @Test func preservesOpaqueOctetsUnicodeLookalikesAndAlternatePorts() throws {
        let address = "https://example.test/?payload=%FF&utm_mar%E2%84%AAeting_tactic=keep&utm_campaign=remove"
        let result = try CleanLinks.clean(address)
        #expect(result.cleaned == "https://example.test/?payload=%FF&utm_mar%E2%84%AAeting_tactic=keep")
        let alternate = "https://www.google.com:8443/url?q=https%3A%2F%2Fexample.test"
        #expect(try CleanLinks.clean(alternate).redirectDestination == nil)
    }

    @Test func rejectsMalformedLinksAndAmbiguousRedirects() {
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://example.test/?q=%ZZ") }
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://bücher.example/?q=%ZZ") }
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://bücher.example/<été>") }
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://www.google.com/url?q=https://a.test&q=https://b.test") }
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://www.google.com/url?q=https://a.test&url=https://b.test") }
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://www.google.com/url?q=javascript%3Aalert%281%29") }
    }
}
