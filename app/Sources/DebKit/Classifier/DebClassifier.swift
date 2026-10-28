import Foundation
import SWCompression

/// Classifies a deb by inspecting its data.tar payload.
///
/// The decision is content-based and source-agnostic: jailbreak-repo apps,
/// GitHub-release debs, and direct downloads are judged identically, and
/// the control Architecture field is advisory. A package is convertible
/// exactly when a .app bundle somewhere in the payload holds an arm64
/// Mach-O main executable - that is what "actually runs" means.
public enum DebClassifier {

    /// Parses and classifies a deb in one call.
    public static func classify(debData: Data) throws -> DebClassification {
        let archive = try DebArchive(debData: debData)
        guard let dataTar = archive.dataTarData,
              let compression = archive.dataCompression else {
            return DebClassification(
                class: .themePack,
                isConvertible: false,
                appBundlePaths: [],
                arm64Executables: [],
                elfBinaries: [],
                substrateDylibs: [],
                reasons: [
                    "The package has no readable data.tar member, so there is no app content to convert.",
                ])
        }
        let tarData = try ControlExtractor.decompress(dataTar, compression: compression)
        let entries = try ControlExtractor.entries(in: tarData)
        return classify(entries: entries)
    }

    /// Classifies an already-extracted data.tar entry list.
    public static func classify(entries: [TarEntry]) -> DebClassification {
        var appBundlePaths: [String] = []
        var arm64Executables: [String] = []
        var elfBinaries: [String] = []
        var substrateDylibs: [String] = []
        var otherMachO: [String] = []
        var substratePaths: [String] = []
        var regularFileCount = 0

        for entry in entries {
            let name = normalize(entry.info.name)
            guard let data = entry.data else { continue }
            // Directories carry no bytes; links point elsewhere. Everything
            // else is treated as a file and gets sniffed.
            let type = entry.info.type
            guard type != .directory, type != .symbolicLink, type != .hardLink else {
                continue
            }
            regularFileCount += 1

            if isSubstratePath(name) {
                substratePaths.append(name)
            }

            let binary = BinarySniffer.sniff(data)
            switch binary.flavor {
            case .machOArm64, .machOFatArm64:
                if binary.isExecutable {
                    arm64Executables.append(name)
                } else if isSubstratePath(name) {
                    substrateDylibs.append(name)
                }
            case .machOOther:
                otherMachO.append(name)
            case .elf:
                elfBinaries.append(name)
            case .unknown:
                break
            }

            if let bundle = appBundleRoot(of: name), !appBundlePaths.contains(bundle) {
                appBundlePaths.append(bundle)
            }
        }

        appBundlePaths.sort()
        arm64Executables.sort()
        elfBinaries.sort()
        substrateDylibs.sort()
        otherMachO.sort()
        substratePaths.sort()

        // An arm64 executable counts for convertibility only when it sits
        // inside one of the discovered .app bundles.
        let bundleExecutables = arm64Executables.filter { exec in
            appBundlePaths.contains { bundle in exec.hasPrefix(bundle + "/") }
        }

        // 1. An app bundle exists: convertible exactly when it holds an
        //    arm64 main executable, wherever the deb came from.
        if !appBundlePaths.isEmpty {
            var reasons = appBundlePaths.map { "Found app bundle at \($0)." }
            if let exec = bundleExecutables.first {
                reasons.append("Found arm64 executable at \(exec).")
                if !substratePaths.isEmpty {
                    reasons.append(
                        "Warning: the package also installs \(substratePaths.count) MobileSubstrate/TweakInject file(s); those only function on a jailbroken device.")
                }
                reasons.append(
                    "Convertible: the app bundle contains an arm64 Mach-O executable and can become a runnable ipa.")
                return DebClassification(
                    class: .app, isConvertible: true,
                    appBundlePaths: appBundlePaths, arm64Executables: arm64Executables,
                    elfBinaries: elfBinaries, substrateDylibs: substrateDylibs,
                    reasons: reasons)
            }
            if !elfBinaries.isEmpty {
                reasons.append("Only ELF (desktop) binaries were found inside the bundle.")
            } else if !otherMachO.isEmpty {
                reasons.append("Only non-arm64 Mach-O binaries were found inside the bundle.")
            } else {
                reasons.append("No arm64 Mach-O executable was found inside the app bundle, so the bundle cannot launch.")
            }
            reasons.append("Not convertible: there is no arm64 executable to run.")
            return DebClassification(
                class: .app, isConvertible: false,
                appBundlePaths: appBundlePaths, arm64Executables: arm64Executables,
                elfBinaries: elfBinaries, substrateDylibs: substrateDylibs,
                reasons: reasons)
        }

        // 2. Substrate components without a bundle: a tweak.
        if !substratePaths.isEmpty {
            var reasons = ["No .app bundle found."]
            reasons.append("Installs \(substratePaths.count) MobileSubstrate/TweakInject/PreferenceBundles file(s).")
            reasons.append("Tweaks inject into other apps and cannot run standalone, so no ipa can be produced.")
            return DebClassification(
                class: .tweak, isConvertible: false,
                appBundlePaths: [], arm64Executables: arm64Executables,
                elfBinaries: elfBinaries, substrateDylibs: substrateDylibs,
                reasons: reasons)
        }

        // 3. ELF binaries: a desktop package.
        if !elfBinaries.isEmpty {
            var reasons = elfBinaries.prefix(5).map { "Found ELF binary at \($0)." }
            if elfBinaries.count > 5 {
                reasons.append("(\(elfBinaries.count - 5) more ELF binaries omitted)")
            }
            reasons.append("ELF binaries target Linux/desktop platforms and cannot run on iOS.")
            return DebClassification(
                class: .nonIOS, isConvertible: false,
                appBundlePaths: [], arm64Executables: [],
                elfBinaries: elfBinaries, substrateDylibs: substrateDylibs,
                reasons: reasons)
        }

        // 4. Bare arm64 binaries with no bundle: iOS CLI tools / daemons.
        if !arm64Executables.isEmpty {
            var reasons = arm64Executables.prefix(5).map { "Found arm64 binary at \($0)." }
            reasons.append("No .app bundle found: command-line tools and daemons have no home-screen app to launch.")
            return DebClassification(
                class: .iosTools, isConvertible: false,
                appBundlePaths: [], arm64Executables: arm64Executables,
                elfBinaries: [], substrateDylibs: [],
                reasons: reasons)
        }

        // 5. Non-arm64 Mach-O: desktop/macOS content.
        if !otherMachO.isEmpty {
            var reasons = otherMachO.prefix(5).map { "Found non-arm64 Mach-O binary at \($0)." }
            reasons.append("Mach-O binaries built for other architectures cannot run on iOS.")
            return DebClassification(
                class: .nonIOS, isConvertible: false,
                appBundlePaths: [], arm64Executables: [],
                elfBinaries: [], substrateDylibs: [],
                reasons: reasons)
        }

        // 6. Nothing executable at all.
        var reasons: [String] = []
        if regularFileCount == 0 {
            reasons.append("The data.tar contains no regular files.")
        } else {
            reasons.append("Scanned \(regularFileCount) file(s) and found no executable content.")
        }
        reasons.append("Data-only packages (themes, icon packs, configuration) cannot become runnable apps.")
        return DebClassification(
            class: .themePack, isConvertible: false,
            appBundlePaths: [], arm64Executables: [],
            elfBinaries: [], substrateDylibs: substrateDylibs,
            reasons: reasons)
    }

    // MARK: - Path helpers

    /// Strips tar naming decorations: "./Applications/X" and
    /// "/Applications/X" both become "Applications/X".
    private static func normalize(_ raw: String) -> String {
        var name = raw
        while name.hasPrefix("./") { name.removeFirst(2) }
        if name.hasPrefix("/") { name.removeFirst() }
        return name
    }

    /// The outermost .app bundle containing this path, or nil when the path
    /// does not sit inside one: "Applications/Foo.app/Foo" becomes
    /// "Applications/Foo.app". With nested bundles the outermost wins.
    private static func appBundleRoot(of name: String) -> String? {
        let components = name.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[0...index].joined(separator: "/")
    }

    /// MobileSubstrate, TweakInject (rootless/ElleKit era) and
    /// PreferenceBundles paths are the fingerprints of tweak packages.
    private static func isSubstratePath(_ name: String) -> Bool {
        name.contains("/MobileSubstrate/")
            || name.contains("/TweakInject/")
            || name.contains("/PreferenceBundles/")
    }
}
