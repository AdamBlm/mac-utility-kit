import Testing
import UtilityCore

struct CleanLinksTests {
    @Test func batchKeepsOrderAndReportsMalformedLinesIndividually() throws {
        let link = "https://example.test/search?q=one&q=two&utm_source=x&UTM_SOURCE=y#section"
        let clean = "https://example.test/search?q=one&q=two#section"
        let signed = "https://example.test/?signature=123&utm_source=keep"
        let invalid = "https://example.test/?x=%ZZ"
        let input = ["", "  \(link) ", invalid, signed, " ", link].joined(separator: "\r\n")
        let batch = try CleanLinks.cleanBatch(input, unwrapRedirects: true)
        #expect(batch.map(\.input) == [link, invalid, signed, link])
        #expect(batch.map(\.id) == [0, 1, 2, 3])
        #expect(batch.compactMap { try? $0.result.get().cleaned } == [clean, signed, clean])
        #expect(try batch[0].result.get().removedParameters == ["utm_source", "UTM_SOURCE"])
        #expect(throws: ToolError.self) { try batch[1].result.get() }
        #expect(try batch[2].result.get().keptSignedQuery)
        #expect(throws: ToolError.self) {
            try CleanLinks.cleanBatch(Array(repeating: link, count: 501).joined(separator: "\n"), unwrapRedirects: true)
        }
    }

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

    @Test func validatesExplicitPortsForHostsAndRedirects() throws {
        #expect(try CleanLinks.clean("https://bücher.example:65535/?utm_source=x").cleaned == "https://bücher.example:65535/")
        #expect(try CleanLinks.clean("https://[::1]:8080/?utm_source=x").cleaned == "https://[::1]:8080/")
        #expect(try CleanLinks.clean("https://[::1]/?utm_source=x").cleaned == "https://[::1]/")
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://example.test:65536/") }
        #expect(throws: ToolError.self) { try CleanLinks.clean("https://bücher.example:999999999999999999999/") }
        #expect(throws: ToolError.self) {
            try CleanLinks.clean("https://www.google.com/url?q=https%3A%2F%2Fexample.test%3A65536%2F")
        }
    }

    @Test func previewsKnownRedirectWithoutRewritingWhenRequested() throws {
        let input = "https://www.google.com/url?q=https%3a%2f%2fexample.test%2f%3fUTM_Source%3Dx%26id%3D42&gclid=leave#original"
        let kept = try CleanLinks.clean(input, unwrapRedirects: false)
        #expect(kept.cleaned.utf8.elementsEqual(input.utf8))
        #expect(kept.redirectDestination == "https://example.test/?UTM_Source=x&id=42")
        #expect(kept.removedParameters.isEmpty && !kept.keptSignedQuery)
        #expect(try CleanLinks.clean(input).cleaned == "https://example.test/?id=42")
        #expect(try CleanLinks.clean("https://example.test/?utm_source=x&keep=%2f", unwrapRedirects: false).cleaned
                == "https://example.test/?keep=%2f")
    }

    @Test func preservesSignaturesOnRedirectWrapperAndDestination() throws {
        let signedWrapper = "https://www.google.com/url?q=https%3a%2f%2fexample.test%2f&%73ig=abc&utm_source=x"
        let preserved = try CleanLinks.clean(signedWrapper)
        #expect(preserved.cleaned.utf8.elementsEqual(signedWrapper.utf8))
        #expect(preserved.redirectDestination == "https://example.test/")
        #expect(preserved.keptSignedQuery && preserved.removedParameters.isEmpty)
        let wrapper = "https://www.google.com/url?q=https%3a%2f%2fexample.test%2f%3fX-Amz-Signature%3Dfoo%26utm_source%3Dx"
        let destination = try CleanLinks.clean(wrapper)
        #expect(destination.keptSignedQuery)
        #expect(destination.cleaned == "https://example.test/?X-Amz-Signature=foo&utm_source=x")
    }
}
