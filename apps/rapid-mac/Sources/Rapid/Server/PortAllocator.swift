import Foundation
import Darwin

/// Picks a free TCP port for ``rapid-mlx serve`` to bind on. The
/// historical desktop assumed :8000 was always available and crashed
/// the spawn when a user's vite / jupyter / fastapi held it (the
/// ownership-verified ``PortSweep`` correctly REFUSES to kill those
/// foreign processes, which is why "just run lsof + kill" isn't a
/// fix). v0.5.6 walks a 10-port window so a foreign collision causes
/// the child to land on :8001 / :8002 / … instead of dying.
///
/// Algorithm — for each candidate ``8000 … 8009``:
///   1. Run ``PortSweep.sweep(port:)`` so a rapid-owned orphan from a
///      previous run gets reaped first (cross-version
///      compatibility — rapid-mlx pre-0.7.3 doesn't always SIGTERM
///      cleanly on parent Force-Quit).
///   2. Open a ``SOCK_STREAM`` socket, ``setsockopt SO_REUSEADDR``
///      so lingering TIME_WAIT sockets from the previous bind don't
///      block us, then ``bind`` to ``127.0.0.1:<candidate>``.
///   3. First bind that returns success wins — close the probe
///      socket and return the port.
///
/// A bind-probe is preferred over checking ``lsof`` because it sees
/// every socket state the kernel knows about (LISTEN, TIME_WAIT,
/// CLOSE_WAIT) and surfaces kernel-level restrictions like reserved
/// ranges. ``lsof`` is fast but only sees processes the caller can
/// inspect.
///
/// Returns ``nil`` when every candidate is held by a non-rapid
/// process — the caller (``ServerManager.start``) surfaces a banner
/// and stops, giving the user an actionable error rather than a
/// silent "exited with status 1".
enum PortAllocator {
    /// 10-port window. 8000-8009 covers the dev-server collision
    /// neighbourhood (vite default 5173, jupyter 8888, fastapi 8000,
    /// flask 5000 — only fastapi overlaps, and never beyond :8000
    /// itself). Wider windows risk colliding with VPN / proxy ports
    /// users care about.
    static let defaultCandidatePorts: [Int] = Array(8000...8009)

    /// Ports the allocator probes, in order. Normally the fixed
    /// ``defaultCandidatePorts`` window; a ``RAPID_DESKTOP_PORT`` env
    /// override collapses it to a single pinned port.
    ///
    /// #455 — test-harness isolation only. When several dogfood-isolated
    /// copies of the .app run in parallel on one host they otherwise all
    /// fall back to the same 8000-8009 window, and ``PortSweep``'s
    /// bundle-id-agnostic ``isRapidOwnedCommand`` predicate lets one copy
    /// reap another's sidecar at :8001/:8002 (a respawn war). A per-copy
    /// ``RAPID_DESKTOP_PORT`` pins each to its own port so the harness is
    /// hermetic without ``pkill`` round-trips. Unset env → byte-identical
    /// production behaviour. ``RAPID_PORT`` is deliberately NOT honoured
    /// — it collides with rapid-mlx's own ``--port`` CLI semantics;
    /// ``RAPID_DESKTOP_PORT`` is the disambiguated name.
    static var candidatePorts: [Int] {
        resolveCandidatePorts(environment: ProcessInfo.processInfo.environment)
    }

    /// Test seam — resolve the candidate window from an injected
    /// environment dictionary. Production goes through the
    /// ``candidatePorts`` computed property with the live process
    /// environment. A ``RAPID_DESKTOP_PORT`` that is missing, non-numeric,
    /// or outside ``1...65535`` is ignored (falls back to the default
    /// window) rather than crashing the spawn.
    static func resolveCandidatePorts(environment: [String: String]) -> [Int] {
        if let raw = environment["RAPID_DESKTOP_PORT"],
           let port = Int(raw.trimmingCharacters(in: .whitespaces)),
           (1...65_535).contains(port) {
            return [port]
        }
        return defaultCandidatePorts
    }

    /// Returns the first port in ``candidatePorts`` that ``rapid-mlx``
    /// can bind to, or ``nil`` if every candidate is held by a
    /// foreign process.
    static func allocate() -> Int? {
        allocate(candidates: candidatePorts, host: "127.0.0.1")
    }

    /// Test-seam — accept arbitrary candidate list + host. Production
    /// callers go through ``allocate()`` above.
    static func allocate(candidates: [Int], host: String) -> Int? {
        for candidate in candidates {
            // Sweep rapid-owned orphans on THIS candidate before
            // probing. A foreign process is left untouched (the
            // ownership-verified sweep is the load-bearing guard
            // against killing user dev servers) — the bind probe
            // below will then fail and we'll walk to the next.
            PortSweep.sweep(port: candidate)
            if canBind(port: candidate, host: host) {
                return candidate
            }
        }
        return nil
    }

    /// Open a fresh socket, set ``SO_REUSEADDR``, bind to
    /// ``host:port``, close. Returns true iff bind succeeded.
    /// ``SO_REUSEADDR`` is critical — without it, a TIME_WAIT socket
    /// from the previous rapid-mlx instance (the upgrade race the
    /// user hit on v0.5.4 → v0.5.5) would return EADDRINUSE for ~60 s.
    static func canBind(port: Int, host: String) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let parsedHost = inet_addr(host)
        guard parsedHost != INADDR_NONE else { return false }

        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(
            sock, SOL_SOCKET, SO_REUSEADDR,
            &yes, socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        // 127.0.0.1 — never bind 0.0.0.0 from a desktop app; that
        // would expose rapid-mlx to the LAN without consent.
        addr.sin_addr.s_addr = parsedHost
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
