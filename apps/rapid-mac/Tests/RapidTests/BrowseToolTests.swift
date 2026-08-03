import Foundation
import Testing
@testable import Rapid

/// Coverage for ``BrowseTool`` focused on the paths that don't require the
/// network: argument + URL validation, the approval gate, cache-served
/// pagination (which skips both approval and any fetch), and the pure
/// slice / content-type / decode / render helpers. The live fetch path is
/// intentionally not exercised here (it would depend on the network); its
/// security-critical host checks are covered by ``BrowseSSRFGuardTests``.
@MainActor
@Suite("browse tool")
struct BrowseToolTests {

    // MARK: - helpers

    private func argsJSON(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(decoding: data, as: UTF8.self)
    }

    private func payload(_ result: ToolCallResult) -> [String: Any] {
        guard let data = result.content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func askStore() -> BrowseApprovalStore {
        let suite = UserDefaults(suiteName: "rapid.test.browse.\(UUID().uuidString)")!
        return BrowseApprovalStore(defaults: suite)
    }

    private func entry(_ md: String) -> BrowseContentCache.Entry {
        BrowseContentCache.Entry(title: "T", markdown: md, finalURL: "https://example.com/x")
    }

    @Test("Tool definition explains approval is only required for network fetches")
    func definitionDescribesCacheApprovalSemantics() {
        let description = BrowseTool.definition.function.description
        #expect(description.contains("Fetching from the network requires user approval"))
        #expect(description.contains("cached pages are returned without prompting"))
        #expect(description.contains("refresh=true"))
    }

    // MARK: - argument / URL validation (no network, no prompt)

    @Test("Unparseable arguments return an error")
    func badArgs() async {
        let r = await BrowseTool.run(arguments: "{ not json", approval: askStore())
        #expect(r.isError)
    }

    @Test("Empty url is rejected")
    func emptyURL() async {
        let r = await BrowseTool.run(arguments: argsJSON(["url": "   "]), approval: askStore())
        #expect(r.isError)
    }

    @Test("A non-http scheme is rejected before any prompt")
    func schemeRejected() async {
        let store = askStore()
        let r = await BrowseTool.run(arguments: argsJSON(["url": "file:///etc/passwd"]), approval: store)
        #expect(r.isError)
        #expect(r.content.contains("scheme"))
        #expect(store.pendingRequest == nil)   // never prompted
    }

    @Test("A loopback IP-literal URL is rejected without a prompt")
    func loopbackLiteralRejected() async {
        let store = askStore()
        let r = await BrowseTool.run(arguments: argsJSON(["url": "http://127.0.0.1/admin"]), approval: store)
        #expect(r.isError)
        #expect(store.pendingRequest == nil)
    }

    @Test("A URL with no host is rejected")
    func noHost() async {
        let r = await BrowseTool.run(arguments: argsJSON(["url": "https://"]), approval: askStore())
        #expect(r.isError)
    }

    @Test("Denying the approval returns an error and never fetches")
    func approvalDenied() async {
        let store = askStore()
        let task = Task { @MainActor in
            await BrowseTool.run(arguments: argsJSON(["url": "https://example.com/page"]), approval: store)
        }
        while store.pendingRequest == nil { await Task.yield() }
        #expect(store.pendingRequest?.host == "example.com")
        store.answer(.deny)
        let r = await task.value
        #expect(r.isError)
        #expect(r.content.contains("did not approve"))
    }

    // MARK: - cache-served pagination (skips approval + network)

    @Test("Paging an already-cached URL serves from cache without a prompt")
    func pagingSkipsApproval() async {
        let cache = BrowseContentCache(diskDirectory: nil)   // memory-only: don't touch Application Support
        let url = "https://example.com/doc"
        cache.put(url, entry: entry(String(repeating: "x", count: 30_000)))
        let store = askStore()   // would suspend if consulted
        let r = await BrowseTool.run(
            arguments: argsJSON(["url": url, "offset": 15_000]),
            approval: store,
            cache: cache
        )
        #expect(!r.isError)
        #expect(store.pendingRequest == nil)   // paging did NOT prompt
        let p = payload(r)
        #expect((p["offset"] as? Int) == 15_000)
        #expect((p["has_more"] as? Bool) == false)   // 30k total, page 2 finishes it
    }

    @Test("Re-reading a cached URL (offset 0) serves from cache with no prompt and no fetch")
    func firstPageCacheHitSkipsApprovalAndFetch() async {
        // Pre-fill the cache to mimic a page persisted from a previous launch,
        // then re-read it at offset 0. The cache is consulted BEFORE the
        // approval gate, so a hit returns the body immediately — no prompt, no
        // network. If it prompted, ``store.pendingRequest`` would be set; if it
        // fell through to fetchFollowingRedirects, the run would hit the network.
        let cache = BrowseContentCache(diskDirectory: nil)
        let url = "https://example.com/cached"
        cache.put(url, entry: entry("CACHED BODY"))
        let store = askStore()   // would suspend if consulted
        let r = await BrowseTool.run(
            arguments: argsJSON(["url": url, "offset": 0]),
            approval: store,
            cache: cache
        )
        #expect(!r.isError)
        #expect(store.pendingRequest == nil)   // cache hit did NOT prompt
        let p = payload(r)
        #expect((p["content"] as? String) == "CACHED BODY")   // served from cache, not the network
        #expect((p["cache_hit"] as? Bool) == true)
        #expect(p["fetched_at"] is String)
        #expect(p["cache_expires_at"] is String)
    }

    @Test("refresh=true bypasses a cached page and requests network approval")
    func refreshBypassesCache() async {
        let cache = BrowseContentCache(diskDirectory: nil)
        let url = "https://example.com/cached"
        cache.put(url, entry: entry("CACHED BODY"))
        let store = askStore()
        let task = Task { @MainActor in
            await BrowseTool.run(
                arguments: argsJSON(["url": url, "offset": 0, "refresh": true]),
                approval: store,
                cache: cache
            )
        }
        for _ in 0..<100 where store.pendingRequest == nil {
            await Task.yield()
        }
        #expect(store.pendingRequest?.host == "example.com")
        if store.pendingRequest != nil {
            store.answer(.deny)
        }
        let result = await task.value
        #expect(result.isError)
    }

    // MARK: - slice / budget math (pure)

    @Test("First page is budget-bounded and advertises the next offset")
    func firstPageBudget() {
        let md = String(repeating: "abcd\n", count: 8_000)   // 40,000 chars
        let r = BrowseTool.sliceResult(tool: "browse", rawURL: "https://x",
                                       entry: entry(md), offset: 0, bytesFetched: 100)
        let p = payload(r)
        #expect((p["offset"] as? Int) == 0)
        #expect((p["total_chars"] as? Int) == 40_000)
        #expect((p["has_more"] as? Bool) == true)
        let next = p["next_offset"] as? Int ?? -1
        #expect(next > 0 && next <= BrowseTool.charBudget)
        // Content length exactly equals the advertised cursor — no drift.
        #expect((p["content"] as? String)?.count == next)
        #expect((p["bytes_fetched"] as? Int) == 100)
        #expect((p["title"] as? String) == "T")
    }

    @Test("The cut snaps to a line boundary so a page doesn't end mid-line")
    func snapsToNewline() {
        let md = String(repeating: "abcd\n", count: 8_000)
        let r = BrowseTool.sliceResult(tool: "browse", rawURL: "https://x",
                                       entry: entry(md), offset: 0, bytesFetched: nil)
        let p = payload(r)
        // Lines are 5 chars ("abcd\n"); a boundary-snapped cursor is a multiple of 5.
        #expect((p["next_offset"] as? Int ?? -1) % 5 == 0)
    }

    @Test("The final page has no next offset")
    func lastPage() {
        let md = String(repeating: "y", count: 5_000)   // < budget
        let r = BrowseTool.sliceResult(tool: "browse", rawURL: "https://x",
                                       entry: entry(md), offset: 0, bytesFetched: nil)
        let p = payload(r)
        #expect((p["has_more"] as? Bool) == false)
        #expect(p["next_offset"] == nil)
        #expect((p["content"] as? String)?.count == 5_000)
    }

    @Test("An offset past the end yields empty content, not a crash")
    func offsetPastEnd() {
        let md = "short"
        let r = BrowseTool.sliceResult(tool: "browse", rawURL: "https://x",
                                       entry: entry(md), offset: 9_999, bytesFetched: nil)
        let p = payload(r)
        #expect((p["content"] as? String)?.isEmpty == true)
        #expect((p["has_more"] as? Bool) == false)
    }

    @Test("final_url is surfaced only when it differs from the requested URL")
    func finalURLSurfaced() {
        let e = BrowseContentCache.Entry(title: nil, markdown: "z", finalURL: "https://example.com/redirected")
        let r = BrowseTool.sliceResult(tool: "browse", rawURL: "https://example.com/start",
                                       entry: e, offset: 0, bytesFetched: nil)
        #expect((payload(r)["final_url"] as? String) == "https://example.com/redirected")
    }

    // MARK: - origin (cross-origin redirect re-approval logic)

    @Test("origin() ignores path/query but distinguishes scheme, host, and port")
    func originNormalisation() {
        func o(_ s: String) -> String { BrowseTool.origin(of: URL(string: s)!) }
        // Path/query changes are same-origin (no re-prompt on same host).
        #expect(o("https://a.com/one?x=1") == o("https://a.com/two#frag"))
        // Explicit default port equals the implicit one.
        #expect(o("https://a.com/") == o("https://a.com:443/"))
        #expect(o("http://a.com/") == o("http://a.com:80/"))
        // Host, scheme, and non-default port each make it cross-origin.
        #expect(o("https://a.com/") != o("https://b.com/"))
        #expect(o("http://a.com/") != o("https://a.com/"))
        #expect(o("https://a.com/") != o("https://a.com:8443/"))
        // Host comparison is case-insensitive.
        #expect(o("https://A.COM/") == o("https://a.com/"))
    }

    // MARK: - content-type / decode / render (pure)

    @Test("Content-Type parses mime + charset")
    func contentType() {
        let (m1, c1) = BrowseTool.parseContentType("text/html; charset=UTF-8")
        #expect(m1 == "text/html")
        #expect(c1 == "UTF-8")
        let (m2, c2) = BrowseTool.parseContentType("text/plain")
        #expect(m2 == "text/plain")
        #expect(c2 == nil)
        let (m3, _) = BrowseTool.parseContentType(nil)
        #expect(m3 == nil)
    }

    @Test("Decode honours charset, then UTF-8, then a lossy fallback")
    func decode() {
        #expect(BrowseTool.decode(Data("héllo".utf8), charset: "utf-8") == "héllo")
        #expect(BrowseTool.decode(Data([0xE9]), charset: "iso-8859-1") == "é")   // latin1 é
        // Invalid UTF-8, no charset → lossy, must not crash and must be non-nil.
        _ = BrowseTool.decode(Data([0xFF, 0xFE, 0x00]), charset: nil)
    }

    @Test("HTML renders to Markdown; text/plain passes through; binary is noted")
    func render() async {
        let html = await BrowseTool.renderMarkdown(from: .init(
            finalURL: URL(string: "https://x")!, data: Data("<h1>Hi</h1><p>Body</p>".utf8),
            mime: "text/html", charset: "utf-8"))
        #expect(html.markdown.contains("# Hi"))
        #expect(html.markdown.contains("Body"))

        let plain = await BrowseTool.renderMarkdown(from: .init(
            finalURL: URL(string: "https://x")!, data: Data("raw text".utf8),
            mime: "text/plain", charset: nil))
        #expect(plain.markdown == "raw text")

        let binary = await BrowseTool.renderMarkdown(from: .init(
            finalURL: URL(string: "https://x")!, data: Data(repeating: 0, count: 500),
            mime: "image/png", charset: nil))
        #expect(binary.markdown.contains("not text"))
    }
}
