import Foundation

/// One dependency group rendered as a row: the primary alternative shown
/// prominently, remaining alternatives shown as " | " options.
public struct DependencyRow: Equatable, Sendable {
    /// The first alternative, with any version constraints, e.g.
    /// "mobilesubstrate (>= 0.9.6000)".
    public let primary: String
    /// Remaining alternatives in the same OR group, e.g. "ellekit".
    public let alternatives: [String]
    /// True when the primary alternative carries version constraints.
    public let hasVersionConstraints: Bool

    /// The complete group as dpkg would print it: "a (>= 1) | b".
    public var canonicalString: String {
        ([primary] + alternatives).joined(separator: " | ")
    }
}

/// One labeled relationship field (Depends, Pre-Depends, ...) rendered as
/// a section of rows.
public struct DependencySection: Equatable, Sendable {
    public let title: String
    public let rows: [DependencyRow]

    public init(title: String, rows: [DependencyRow]) {
        self.title = title
        self.rows = rows
    }
}

/// Builds the Import screen's dependency tree from a parsed control stanza.
/// Pure logic - no UI framework - so it runs and is tested on Linux CI.
public enum DependencyDisplay {

    /// The display sections for a control stanza, in Debian reading order,
    /// omitting fields the stanza does not carry.
    public static func sections(for control: DebControl) -> [DependencySection] {
        var sections: [DependencySection] = []
        if let depends = control.depends {
            sections.append(DependencySection(title: "Depends",
                                              rows: rows(for: depends)))
        }
        if let preDepends = control.preDepends {
            sections.append(DependencySection(title: "Pre-Depends",
                                              rows: rows(for: preDepends)))
        }
        if let recommends = control.recommends {
            sections.append(DependencySection(title: "Recommends",
                                              rows: rows(for: recommends)))
        }
        if let suggests = control.suggests {
            sections.append(DependencySection(title: "Suggests",
                                              rows: rows(for: suggests)))
        }
        return sections
    }

    /// Converts one parsed relationship expression into display rows,
    /// preserving the OR-group structure.
    public static func rows(for expression: DependsExpression) -> [DependencyRow] {
        expression.groups.map { group in
            let names = group.alternatives.map { $0.canonicalString }
            guard let first = names.first else {
                return DependencyRow(primary: "", alternatives: [],
                                     hasVersionConstraints: false)
            }
            let rest = Array(names.dropFirst())
            let constrained = group.alternatives.first?.versionConstraints.isEmpty == false
            return DependencyRow(primary: first, alternatives: rest,
                                 hasVersionConstraints: constrained)
        }
    }

    /// A one-line count summary for the header, e.g.
    /// "3 dependencies (1 alternative group)".
    public static func summary(for sections: [DependencySection]) -> String {
        let rowCount = sections.reduce(0) { $0 + $1.rows.count }
        let altCount = sections.reduce(0) {
            $0 + $1.rows.filter { !$0.alternatives.isEmpty }.count
        }
        guard rowCount > 0 else { return "No dependencies" }
        var text = "\(rowCount) dependenc\(rowCount == 1 ? "y" : "ies")"
        if altCount > 0 {
            text += ", \(altCount) with alternativ\(altCount == 1 ? "e" : "es")"
        }
        return text
    }
}
