/// A Debian package version, parsed and compared with dpkg's exact rules.
///
/// The grammar is [epoch:]upstream[-revision], where the epoch is a
/// non-negative integer that dominates the comparison, the upstream version
/// must start with a digit, and the revision is everything after the last
/// hyphen.
///
/// Comparison follows the algorithm in dpkg's lib/version.c:
/// - a tilde sorts before anything, including the end of the version;
/// - letters sort before non-letters;
/// - digit runs are compared as numbers, ignoring leading zeros.
public struct DebianVersion: Equatable, Sendable, Comparable {
    public let epoch: Int
    public let upstream: String
    public let revision: String

    /// Parses and validates a version string. Returns nil for any version
    /// dpkg itself would reject.
    public init?(_ string: String) {
        var text = Substring(string)

        var epoch = 0
        if let colon = text.firstIndex(of: ":") {
            let epochText = text[text.startIndex ..< colon]
            guard !epochText.isEmpty,
                  epochText.allSatisfy(\.isNumber),
                  let parsed = Int(epochText) else { return nil }
            epoch = parsed
            text = text[text.index(after: colon)...]
        }

        var revision = ""
        if let dash = text.lastIndex(of: "-") {
            revision = String(text[text.index(after: dash)...])
            text = text[text.startIndex ..< dash]
        }

        let upstream = String(text)

        // Upstream must exist, start with a digit, and contain only
        // alphanumerics plus . + ~ - ; the revision may not be empty when a
        // hyphen is present and may not contain another hyphen.
        guard !upstream.isEmpty, upstream.first?.isNumber == true else { return nil }
        guard !revision.isEmpty || !revision.isEmpty else { return nil }

        func allowedCharacters(_ s: String, hyphen: Bool) -> Bool {
            s.allSatisfy { c in
                c.isLetter || c.isNumber || c == "." || c == "+" || c == "~"
                    || (hyphen && c == "-")
            }
        }
        guard allowedCharacters(upstream, hyphen: true),
              allowedCharacters(revision, hyphen: false) else { return nil }
        guard !revision.isEmpty || text.contains("-") == false else { return nil }

        self.epoch = epoch
        self.upstream = upstream
        self.revision = revision
    }

    /// Full three-way comparison: negative when lhs sorts before rhs.
    public static func compare(_ lhs: DebianVersion, _ rhs: DebianVersion) -> Int {
        if lhs.epoch != rhs.epoch {
            return lhs.epoch < rhs.epoch ? -1 : 1
        }
        let upstreamResult = verrevcmp(lhs.upstream, rhs.upstream)
        if upstreamResult != 0 { return upstreamResult }
        return verrevcmp(lhs.revision, rhs.revision)
    }

    public static func < (lhs: DebianVersion, rhs: DebianVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    /// Whether this version satisfies a single version constraint.
    public func satisfies(_ constraint: VersionConstraint) -> Bool {
        constraint.isSatisfied(by: self)
    }

    /// The version rendered back in canonical form.
    public var canonicalString: String {
        var text = epoch > 0 ? String(epoch) + ":" : ""
        text += upstream
        if !revision.isEmpty { text += "-" + revision }
        return text
    }

    /// dpkg's character rank: tilde ranks below everything, digits are
    /// handled by the digit loop, letters keep their code points, other
    /// characters rank above all letters.
    private static func rank(_ c: UInt8) -> Int {
        if c >= 48 && c <= 57 { return 0 }
        if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) { return Int(c) }
        if c == 126 { return -1 }
        if c != 0 { return Int(c) + 256 }
        return 0
    }

    /// Character-wise upstream/revision comparison, a direct port of dpkg's
    /// verrevcmp(). Both sides are treated as if terminated by a NUL that
    /// ranks 0, so "1.0~" compares less than an exhausted "1.0".
    private static func verrevcmp(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8)
        let b = Array(b.utf8)

        func at(_ bytes: [UInt8], _ index: Int) -> UInt8 {
            index < bytes.count ? bytes[index] : 0
        }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

        var i = 0
        var j = 0

        while i < a.count || j < b.count {
            // 1. Compare the non-digit runs.
            while (i < a.count && !isDigit(at(a, i))) || (j < b.count && !isDigit(at(b, j))) {
                let left = rank(at(a, i))
                let right = rank(at(b, j))
                if left != right { return left - right }
                if i < a.count { i += 1 }
                if j < b.count { j += 1 }
            }

            // 2. Compare the digit runs numerically: strip leading zeros,
            //    remember the first differing digit, then check for a longer
            //    run on either side.
            while at(a, i) == 48 { i += 1 }
            while at(b, j) == 48 { j += 1 }

            var firstDifference = 0
            while isDigit(at(a, i)) && isDigit(at(b, j)) {
                if firstDifference == 0 {
                    firstDifference = Int(at(a, i)) - Int(at(b, j))
                }
                i += 1
                j += 1
            }

            if isDigit(at(a, i)) { return 1 }
            if isDigit(at(b, j)) { return -1 }
            if firstDifference != 0 { return firstDifference }
        }

        return 0
    }
}
