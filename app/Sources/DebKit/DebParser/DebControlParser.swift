import Foundation

/// Errors thrown while parsing the control stanza.
public enum DebControlError: Error, Equatable {
    /// The stanza contained no fields at all.
    case emptyControl
    /// A line that was neither a "Field: value" pair nor a continuation.
    case malformedFieldLine(String)
    /// The stanza lacks Package or Version.
    case missingRequiredField(String)
    /// A relationship field could not be parsed.
    case malformedDependency(String)
}

extension DebControlError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyControl:
            return "The control stanza is empty."
        case .malformedFieldLine(let line):
            return "Malformed control line: " + line
        case .missingRequiredField(let field):
            return "The control stanza is missing required field: " + field
        case .malformedDependency(let detail):
            return "Malformed dependency field: " + detail
        }
    }
}

/// Parses the RFC 822-style control stanza of a deb into a DebControl.
///
/// Grammar (Debian Policy 5.1): one "Field: value" pair per line; lines that
/// begin with a space or tab are continuations folded into the previous
/// field's value; field names are case-insensitive.
public enum DebControlParser {

    public static func parse(_ data: Data) throws -> DebControl {
        try parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) throws -> DebControl {
        // 1. Unfold the stanza into (name, value) pairs.
        var fields: [(String, String)] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let line = String(line)
            if line.isEmpty { continue }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !fields.isEmpty else {
                    throw DebControlError.malformedFieldLine(line)
                }
                let index = fields.count - 1
                fields[index].1 = fields[index].1 + "\n" + String(line.dropFirst())
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw DebControlError.malformedFieldLine(line)
            }
            let namePart = line[line.startIndex ..< colon]
            guard !namePart.isEmpty,
                  namePart.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw DebControlError.malformedFieldLine(line)
            }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            fields.append((String(namePart), value))
        }

        guard !fields.isEmpty else { throw DebControlError.emptyControl }

        // 2. Index fields case-insensitively, keeping the last occurrence.
        var raw: [String: String] = [:]
        for (name, value) in fields {
            raw[name.lowercased()] = value
        }

        func field(_ name: String) -> String? {
            guard let value = raw[name.lowercased()], !value.isEmpty else { return nil }
            return value
        }

        func dependencyField(_ name: String) throws -> DependsExpression? {
            guard let value = field(name) else { return nil }
            do { return try DependsExpression(parsing: value) }
            catch { throw DebControlError.malformedDependency(name + ": " + value) }
        }

        func nameList(_ name: String) -> [String] {
            guard let value = field(name) else { return [] }
            return value.split(separator: ",").map { item in
                String(item.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
            }.filter { !$0.isEmpty }
        }

        guard let package = field("Package") else {
            throw DebControlError.missingRequiredField("Package")
        }
        guard let version = field("Version") else {
            throw DebControlError.missingRequiredField("Version")
        }

        // 3. Description: the first line is the summary, the folded rest is
        //    the extended description.
        var summary: String? = nil
        var longDescription: String? = nil
        if let description = field("Description") {
            let parts = description.split(separator: "\n", maxSplits: 1,
                                            omittingEmptySubsequences: false)
            summary = String(parts[0])
            longDescription = parts.count > 1 ? String(parts[1]) : nil
        }

        return DebControl(
            package: package,
            name: field("Name"),
            version: version,
            architecture: field("Architecture"),
            maintainer: field("Maintainer"),
            section: field("Section"),
            priority: field("Priority"),
            installedSize: field("Installed-Size").flatMap(Int.init),
            depends: try dependencyField("Depends"),
            preDepends: try dependencyField("Pre-Depends"),
            recommends: try dependencyField("Recommends"),
            suggests: try dependencyField("Suggests"),
            conflicts: try dependencyField("Conflicts"),
            replaces: nameList("Replaces"),
            provides: nameList("Provides"),
            summary: summary,
            longDescription: longDescription,
            homepage: field("Homepage"),
            allFields: raw
        )
    }
}
