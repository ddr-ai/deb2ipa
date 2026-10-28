import Foundation

/// The payload classes the classifier distinguishes. Origin, source repo,
/// and the control Architecture field are advisory: class and
/// convertibility are decided by what data.tar actually contains.
public enum DebClass: String, Equatable, Sendable, Codable {
    /// A .app bundle is present. Convertible when the bundle contains an
    /// arm64 Mach-O main executable - no matter where the deb came from.
    case app
    /// MobileSubstrate / TweakInject / PreferenceBundles components with no
    /// .app bundle: they inject into other processes and cannot run
    /// standalone.
    case tweak
    /// arm64 Mach-O binaries with no .app bundle: iOS command-line tools
    /// and daemons. Genuine iOS code, but nothing that launches from the
    /// home screen.
    case iosTools
    /// ELF binaries or non-arm64 Mach-O: built for Linux or desktop
    /// platforms.
    case nonIOS
    /// No executable content at all: themes, icon packs, plain data files.
    case themePack
}

/// Classification verdict for one deb, including the evidence behind it.
/// Codable-ready so the same structure can be embedded into the build
/// report the Actions workflow produces.
public struct DebClassification: Equatable, Sendable, Codable {
    /// The payload class.
    public let `class`: DebClass
    /// True when an ipa can be produced that actually runs: an arm64
    /// Mach-O main executable exists inside a .app bundle.
    public let isConvertible: Bool
    /// Bundle roots (paths ending in .app) found anywhere in the payload.
    public let appBundlePaths: [String]
    /// Every arm64 main executable found (thin or fat), sorted by path.
    public let arm64Executables: [String]
    /// Every ELF binary found, sorted by path.
    public let elfBinaries: [String]
    /// MobileSubstrate / TweakInject / PreferenceBundles dylibs found.
    public let substrateDylibs: [String]
    /// Human-readable explanation of the verdict, in display order.
    public let reasons: [String]
}
