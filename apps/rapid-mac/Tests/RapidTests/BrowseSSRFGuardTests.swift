import Foundation
import Testing
@testable import Rapid

/// Coverage for ``BrowseSSRFGuard`` / ``ParsedIP`` — the range checks that keep
/// `browse` from being an SSRF pivot into the user's private network. The IP
/// classification is pure (no DNS), so it is exhaustively unit-tested; the
/// end-to-end `validate` is exercised only on IP-literal URLs (which also skip
/// DNS) so the suite never depends on the network.
@Suite("BrowseSSRFGuard")
struct BrowseSSRFGuardTests {

    private func ip(_ s: String) -> ParsedIP {
        guard let p = ParsedIP(s) else { Issue.record("not a valid IP literal: \(s)"); return ParsedIP("0.0.0.0")! }
        return p
    }

    @Test("Loopback / private / link-local / CGNAT IPv4 are blocked")
    func blockedV4() {
        let blocked = [
            "127.0.0.1", "127.1.2.3",           // loopback /8
            "10.0.0.1", "10.255.255.255",       // private /8
            "172.16.0.1", "172.31.255.255",     // private /12
            "192.168.0.1", "192.168.255.255",   // private /16
            "169.254.169.254",                  // link-local metadata
            "100.64.0.1", "100.127.255.255",    // CGNAT /10
            "0.0.0.0", "0.1.2.3",               // this-host /8
            "192.0.0.1", "192.0.2.5",           // protocol assignments / TEST-NET-1
            "198.18.0.1", "198.19.255.255",     // benchmarking /15
            "224.0.0.1", "239.1.1.1",           // multicast
            "240.0.0.1", "255.255.255.255",     // reserved / broadcast
        ]
        for s in blocked {
            #expect(ip(s).isBlocked, "expected \(s) to be blocked")
        }
    }

    @Test("Public IPv4 addresses are allowed")
    func allowedV4() {
        let allowed = ["8.8.8.8", "1.1.1.1", "93.184.216.34", "172.15.255.255",
                       "172.32.0.1", "100.63.255.255", "100.128.0.1", "192.167.0.1",
                       "192.0.1.1", "198.17.255.255", "198.20.0.1", "223.255.255.255"]
        for s in allowed {
            #expect(!ip(s).isBlocked, "expected \(s) to be allowed")
        }
    }

    @Test("Loopback / ULA / link-local / site-local / multicast IPv6 are blocked")
    func blockedV6() {
        let blocked = ["::1", "::", "fc00::1", "fd12:3456::1", "fe80::1",
                       "febf:ffff::1",
                       "fec0::1", "feff:ffff::1",   // deprecated site-local fec0::/10 (fe00::/8)
                       "ff02::1"]
        for s in blocked {
            #expect(ip(s).isBlocked, "expected \(s) to be blocked")
        }
    }

    @Test("IPv4-mapped and NAT64 IPv6 inherit the embedded v4 verdict")
    func embeddedV4() {
        // ::ffff:127.0.0.1 and 64:ff9b::7f00:1 both carry loopback → blocked.
        #expect(ip("::ffff:127.0.0.1").isBlocked)
        #expect(ip("::ffff:169.254.169.254").isBlocked)
        #expect(ip("64:ff9b::7f00:1").isBlocked)          // WKP 64:ff9b::/96, 127.0.0.1
        // ::ffff:8.8.8.8 carries a public v4 → allowed.
        #expect(!ip("::ffff:8.8.8.8").isBlocked)
    }

    @Test("RFC 8215 NAT64 prefix 64:ff9b:1::/48 unwraps its embedded v4")
    func nat64LocalUsePrefix() {
        // RFC 6052 /48 layout: v4 = bytes 6,7,9,10 (byte 8 is the reserved 'u'
        // octet). Words are 2 bytes, so word3=bytes6-7, word4=bytes8-9,
        // word5=bytes10-11 — mind that octet 3 is word4's LOW byte and octet 4
        // is word5's HIGH byte. 127.0.0.1 → bytes 7f,00,00,01 → word3=7f00,
        // word4=0000 (u=0, octet3=00), word5=0100 (octet4=01).
        #expect(ip("64:ff9b:1:7f00:0:100::").isBlocked)    // → 127.0.0.1
        // 10.0.0.1 → bytes 0a,00,00,01 → word3=0a00, word4=0000, word5=0100.
        #expect(ip("64:ff9b:1:a00:0:100::").isBlocked)     // → 10.0.0.1
        // A public v4 stays allowed even via the prefix. 8.8.8.8 → bytes
        // 08,08,08,08 → word3=0808, word4=0008 (u=0, octet3=08), word5=0800.
        #expect(!ip("64:ff9b:1:808:8:800::").isBlocked)    // → 8.8.8.8
    }

    @Test("Global-unicast IPv6 is allowed")
    func allowedV6() {
        #expect(!ip("2606:4700:4700::1111").isBlocked)   // Cloudflare
        #expect(!ip("2001:4860:4860::8888").isBlocked)   // Google
    }

    @Test("A non-http scheme is rejected")
    func schemeRejected() async {
        for bad in ["file:///etc/passwd", "ftp://example.com/x", "gopher://x", "data:text/html,hi"] {
            await #expect(throws: BrowseSSRFGuard.Rejection.self) {
                try await BrowseSSRFGuard.validate(URL(string: bad)!)
            }
        }
    }

    @Test("A loopback IP-literal URL is rejected without DNS")
    func literalURLRejected() async {
        for bad in ["http://127.0.0.1/admin", "http://[::1]:8080/", "https://169.254.169.254/latest/meta-data/"] {
            await #expect(throws: BrowseSSRFGuard.Rejection.self) {
                try await BrowseSSRFGuard.validate(URL(string: bad)!)
            }
        }
    }

    @Test("A public IP-literal URL passes (no DNS needed)")
    func publicLiteralAllowed() async throws {
        try await BrowseSSRFGuard.validate(URL(string: "https://8.8.8.8/")!)
    }

    @Test("A URL with no host is rejected")
    func noHostRejected() async {
        await #expect(throws: BrowseSSRFGuard.Rejection.self) {
            try await BrowseSSRFGuard.validate(URL(string: "https:///path")!)
        }
    }
}
