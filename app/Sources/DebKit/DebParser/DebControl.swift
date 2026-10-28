import Foundation

/// The control metadata of a Debian package: every modelled field of the
/// control stanza, with dependency fields parsed into expressions.
public struct DebControl: Equatable, Sendable {
    /// The package identifier, e.g. "ws.hbang.newterm3".
    public let package: String
    /// Human-readable name; common in jailbreak debs ("NewTerm 3").
    public let name: String?
    /// Raw version string, e.g. "3.0~beta1-18".
    public let version: String
    /// e.g. "iphoneos-arm64" (iOS), "arm64" (Debian Linux), "all".
    public let architecture: String?
    public let maintainer: String?
    public let section: String?
    public let priority: String?
    public let installedSize: Int?

    public let depends: DependsExpression?
    public let preDepends: DependsExpression?
    public let recommends: DependsExpression?
    public let suggests: DependsExpression?
    public let conflicts: DependsExpression?
    public let replaces: [String]
    public let provides: [String]

    /// One-line short description (first line of the Description field).
    public let summary: String?
    /// Extended description (remaining folded lines), if any.
    public let longDescription: String?
    public let homepage: String?

    /// Every field of the stanza, keyed by lowercased field name. Fields the
    /// model does not model remain accessible here.
    public let allFields: [String: String]

    /// The version parsed and validated with dpkg rules.
    public var debianVersion: DebianVersion? {
        DebianVersion(version)
    }

    /// Pre-Depends plus Depends groups, in installation order.
    public var allDependencies: [DependencyGroup] {
        (preDepends?.groups ?? []) + (depends?.groups ?? [])
    }
}
