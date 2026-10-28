/// A Debian version comparison operator as it appears inside the
/// parentheses of a dependency, e.g. "pkg (>= 1.0)".
public enum VersionOperator: String, Equatable, Sendable, CaseIterable {
    case earlierStrict = "<<"
    case earlierOrEqual = "<="
    case exact = "="
    case laterOrEqual = ">="
    case laterStrict = ">>"

    /// Whether a three-way comparison result satisfies this operator.
    public func isSatisfied(by comparison: Int) -> Bool {
        switch self {
        case .earlierStrict: return comparison < 0
        case .earlierOrEqual: return comparison <= 0
        case .exact: return comparison == 0
        case .laterOrEqual: return comparison >= 0
        case .laterStrict: return comparison > 0
        }
    }
}

/// One version requirement attached to a dependency, e.g. (>= 1.0).
public struct VersionConstraint: Equatable, Sendable {
    public let op: VersionOperator
    public let version: String

    public init(op: VersionOperator, version: String) {
        self.op = op
        self.version = version
    }

    /// Whether the given version satisfies this constraint. A constraint
    /// whose version string dpkg would reject can never be satisfied.
    public func isSatisfied(by candidate: DebianVersion) -> Bool {
        guard let required = DebianVersion(version) else { return false }
        return op.isSatisfied(by: DebianVersion.compare(candidate, required))
    }

    /// Rendering used in canonical dependency strings, e.g. ">= 1.0".
    public var canonicalString: String {
        op.rawValue + " " + version
    }
}
