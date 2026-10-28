import Foundation

/// Errors thrown while parsing a Depends / Pre-Depends / Conflicts field.
public enum DependencyParseError: Error, Equatable {
    /// A comma or pipe slot contained no package name at all.
    case emptyAlternative(String)
    /// The text inside parentheses did not start with a known operator.
    case invalidConstraintOperator(String)
    /// A version constraint had no version after the operator.
    case missingConstraintVersion(String)
    /// An architecture qualifier list was never closed.
    case malformedArchList(String)
    /// Unparsable trailing characters after a package name.
    case trailingJunk(String)
}

/// One concrete alternative inside a dependency slot: a package name plus
/// optional version constraints and architecture qualifiers.
public struct DependencyAlternative: Equatable, Sendable {
    public let packageName: String
    public let versionConstraints: [VersionConstraint]
    public let architectures: [String]

    public init(packageName: String,
                versionConstraints: [VersionConstraint] = [],
                architectures: [String] = []) {
        self.packageName = packageName
        self.versionConstraints = versionConstraints
        self.architectures = architectures
    }

    /// Parses one alternative such as "preferenceloader (>= 2.2.3)".
    public static func parse(_ text: String) throws -> DependencyAlternative {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))

        // The package name: letters, digits, hyphen, plus, dot, underscore.
        var name = ""
        while let c = rest.first,
              c.isLetter || c.isNumber || c == "." || c == "-" || c == "+" || c == "_" {
            name.append(c)
            rest = rest.dropFirst()
        }
        guard !name.isEmpty else { throw DependencyParseError.emptyAlternative(text) }

        var constraints: [VersionConstraint] = []
        var architectures: [String] = []

        while !rest.isEmpty {
            while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }
            guard let opener = rest.first else { break }

            if opener == "(" {
                rest = rest.dropFirst()
                guard let close = rest.firstIndex(of: ")") else {
                    throw DependencyParseError.missingConstraintVersion(String(rest))
                }
                let inside = String(rest[rest.startIndex ..< close])
                    .trimmingCharacters(in: .whitespaces)
                rest = rest[rest.index(after: close)...]

                guard let op = VersionOperator.allCases
                    .first(where: { inside.hasPrefix($0.rawValue) }) else {
                    throw DependencyParseError.invalidConstraintOperator(inside)
                }
                let version = String(inside.dropFirst(op.rawValue.count))
                    .trimmingCharacters(in: .whitespaces)
                guard !version.isEmpty else {
                    throw DependencyParseError.missingConstraintVersion(inside)
                }
                constraints.append(VersionConstraint(op: op, version: version))
            } else if opener == "[" || opener == "<" {
                let closer: Character = opener == "[" ? "]" : ">"
                rest = rest.dropFirst()
                guard let close = rest.firstIndex(of: closer) else {
                    throw DependencyParseError.malformedArchList(String(rest))
                }
                let inside = String(rest[rest.startIndex ..< close])
                rest = rest[rest.index(after: close)...]
                architectures = inside.split(separator: " ").map(String.init)
            } else {
                throw DependencyParseError.trailingJunk(String(rest))
            }
        }

        return DependencyAlternative(packageName: name,
                                     versionConstraints: constraints,
                                     architectures: architectures)
    }

    /// Canonical rendering, e.g. "preferenceloader (>= 2.2.3)".
    public var canonicalString: String {
        var text = packageName
        if !architectures.isEmpty {
            text += " [" + architectures.joined(separator: " ") + "]"
        }
        for constraint in versionConstraints {
            text += " (" + constraint.canonicalString + ")"
        }
        return text
    }
}

/// One comma slot of a relationship field: pipe-separated alternatives, any
/// one of which can satisfy the slot.
public struct DependencyGroup: Equatable, Sendable {
    public let alternatives: [DependencyAlternative]

    public init(alternatives: [DependencyAlternative]) {
        self.alternatives = alternatives
    }
}

/// A parsed Depends / Pre-Depends / Recommends / Suggests / Conflicts field.
public struct DependsExpression: Equatable, Sendable {
    public let groups: [DependencyGroup]

    public init(groups: [DependencyGroup]) {
        self.groups = groups
    }

    /// Parses a full relationship field, e.g.
    /// "mobilesubstrate (>= 0.9.6000), preferenceloader (>= 2.2.3) | ellekit".
    ///
    /// Splitting is strict: empty slots ("a |", "a,,b") throw rather than
    /// being silently dropped.
    public init(parsing text: String) throws {
        var parsed: [DependencyGroup] = []
        for groupText in text.split(separator: ",", omittingEmptySubsequences: false) {
            var alternatives: [DependencyAlternative] = []
            for alternativeText in groupText.split(separator: "|", omittingEmptySubsequences: false) {
                alternatives.append(try DependencyAlternative.parse(String(alternativeText)))
            }
            parsed.append(DependencyGroup(alternatives: alternatives))
        }
        guard !parsed.isEmpty else {
            throw DependencyParseError.emptyAlternative(text)
        }
        groups = parsed
    }

    /// Canonical rendering of the whole field.
    public var canonicalString: String {
        groups.map { group in
            group.alternatives.map(\.canonicalString).joined(separator: " | ")
        }.joined(separator: ", ")
    }
}
