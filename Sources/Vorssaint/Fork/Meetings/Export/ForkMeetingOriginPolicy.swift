// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Martial

import Foundation

/// **The only origins an export may talk to.**
///
/// Two failures, both silent, both paid for by the people in the meeting:
///
/// - **A redirection.** The address approved answers "send it over there"
///   with a `302`, and `URLSession` follows without asking: the audio of a
///   whole meeting lands on a host nobody approved, or in plain HTTP. A
///   custom header (the signature) survives a redirection, unlike
///   `Authorization`.
/// - **A rewritten preference.** The exporters' addresses live in the
///   preferences, where any process of the same session may write, while the
///   secret lives in the Keychain, where it cannot read. Without a check of
///   the origin, writing another address in the preference would make the
///   app read the secret itself (any Keychain alert names this app, not the
///   writer) and sign for that address. So the secret is filed under its
///   origin (`webhook@<host>`) and only read for a request whose origin is
///   exactly the one it was saved for.
///
/// Hence an origin is the host **and** the port, compared exactly: no
/// suffix, no subdomain unless a rule says so (`Rule.domain`), and a host
/// written in ASCII only, so a lookalike in another script (`аpple.com`,
/// Cyrillic `а`) cannot pass for the real one. What a host with other
/// letters becomes on the wire (its `xn--` form) is said in the refusal, to
/// be pasted back knowingly.
///
/// Ported from a policy written for one installation, with its list of
/// hosts made a parameter: nothing here names a service.
enum ForkMeetingOriginPolicy {
    /// What an address may reach.
    enum Rule: Equatable {
        /// This host and port, and nothing else.
        case exactly(Origin)
        /// This domain or any of its subdomains, on HTTPS's port: the rule
        /// is "the domain itself, or anything ending with a dot and the
        /// domain", never a bare suffix (`evilexample.org`).
        case domain(String)
    }

    /// A host and its port, as compared: lower case, without a final dot,
    /// the port written only when it is not HTTPS's.
    struct Origin: Equatable, Hashable {
        let host: String
        let port: Int

        static let httpsPort = 443

        init(host: String, port: Int = Origin.httpsPort) {
            var host = host.lowercased()
            if host.hasSuffix(".") { host.removeLast() }
            self.host = host
            self.port = port
        }

        /// `host`, or `host:port`, or `[v6]:port`: the name the Keychain
        /// files a secret under and the page shows.
        var name: String {
            let shown = host.contains(":") ? "[\(host)]" : host
            return port == Self.httpsPort ? shown : "\(shown):\(port)"
        }

        /// The inverse of `name`, for a frozen origin read back from the
        /// preferences; `nil` for anything `name` never writes.
        init?(name: String) {
            guard let url = URL(string: "https://\(name)/"), let origin = ForkMeetingOriginPolicy.origin(of: url),
                  origin.name == name.lowercased() else { return nil }
            self = origin
        }
    }

    /// Why an address is refused. Each one has its sentence in the
    /// meetings' strings (`message`): it is the only place the person
    /// learns that nothing was sent, and "invalid URL" does not say what to
    /// fix.
    enum Refusal: Error, Equatable {
        case unreadable
        case notHTTPS(scheme: String?)
        case credentialsInURL
        case fragmentInURL
        /// A host with letters outside ASCII, or percent-escaped: what it
        /// would really reach, in its `xn--` form when there is one.
        case nonASCIIHost(wire: String?)
        case unapprovedHost(String)
    }

    enum Verdict: Equatable {
        case approved(URL, Origin)
        case refused(Refusal)

        var url: URL? {
            if case let .approved(url, _) = self { return url }
            return nil
        }

        var origin: Origin? {
            if case let .approved(_, origin) = self { return origin }
            return nil
        }

        var refusal: Refusal? {
            if case let .refused(refusal) = self { return refusal }
            return nil
        }
    }

    /// An address as typed: HTTPS, readable, no user or password, no
    /// fragment, a host in ASCII. Any host passes; what it may reach is
    /// frozen from the verdict (`Verdict.origin`). Spaces around are not
    /// part of an address.
    static func destination(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return .refused(.unreadable) }
        guard url.scheme?.lowercased() == "https" else {
            // "example.com" alone has no scheme and no host: unreadable,
            // rather than read as a path.
            return .refused(url.host == nil && url.scheme == nil ? .unreadable : .notHTTPS(scheme: url.scheme?.lowercased()))
        }
        // As typed: escaped when it was not plain ASCII (`url.host` alone
        // would already be the `xn--` form, and hide what was typed).
        guard let raw = url.host(percentEncoded: true), !raw.isEmpty else { return .refused(.unreadable) }
        if url.user != nil || url.password != nil { return .refused(.credentialsInURL) }
        if url.fragment != nil { return .refused(.fragmentInURL) }
        guard isPlainHost(raw) else { return .refused(.nonASCIIHost(wire: url.host.flatMap { isPlainHost($0) ? $0 : nil })) }
        guard let origin = origin(of: url) else { return .refused(.unreadable) }
        return .approved(url, origin)
    }

    /// The same, and the address must reach one of `rules`.
    static func destination(_ text: String, within rules: [Rule]) -> Verdict {
        let verdict = destination(text)
        guard case let .approved(_, origin) = verdict else { return verdict }
        return rules.contains { allows($0, origin) } ? verdict : .refused(.unapprovedHost(origin.name))
    }

    /// The address saved for an exporter, read back at the moment of
    /// sending: approved only when it still reaches the origin frozen when
    /// it was saved. A preference rewritten behind the app's back gets a
    /// refusal, never the secret.
    static func destination(_ text: String, frozen: Origin) -> Verdict {
        destination(text, within: [.exactly(frozen)])
    }

    /// May a redirection be followed? **Not once it changes origin**, nor
    /// when it falls back to plain HTTP: otherwise every check above is
    /// undone by a `302`. It also happens without malice (a service moving
    /// to a backup domain), and must not pass either.
    static func allowsRedirection(from source: URL, to target: URL) -> Bool {
        // A user name or a password in the new address would go along with
        // the body: refused, as at the address's Save.
        guard target.user == nil, target.password == nil else { return false }
        guard target.scheme?.lowercased() == "https", source.scheme?.lowercased() == "https",
              let from = origin(of: source), let to = origin(of: target),
              let raw = target.host(percentEncoded: true), isPlainHost(raw) else { return false }
        return from == to
    }

    /// The origin an HTTPS address reaches; `nil` without a host or with a
    /// port no connection can use.
    static func origin(of url: URL) -> Origin? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let port = url.port ?? Origin.httpsPort
        guard (1...65_535).contains(port) else { return nil }
        let origin = Origin(host: host, port: port)
        return origin.host.isEmpty ? nil : origin
    }

    private static func allows(_ rule: Rule, _ origin: Origin) -> Bool {
        switch rule {
        case let .exactly(approved):
            return approved == origin
        case let .domain(domain):
            let domain = Origin(host: domain).host
            guard !domain.isEmpty, origin.port == Origin.httpsPort else { return false }
            return origin.host == domain || origin.host.hasSuffix("." + domain)
        }
    }

    /// Letters, digits, dots and hyphens; or an IPv6 literal. Nothing
    /// escaped: `example.com%2F.evil.com` is not `example.com`.
    private static func isPlainHost(_ host: String) -> Bool {
        var host = Substring(host)
        if host.hasPrefix("["), host.hasSuffix("]") { host = host.dropFirst().dropLast() }
        if host.contains(":") {
            return host.unicodeScalars.allSatisfy { ($0.isASCII && $0.properties.isASCIIHexDigit) || $0 == ":" || $0 == "." }
        }
        return !host.isEmpty && host.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
        } && !host.hasPrefix(".") && !host.contains("..")
    }
}
