import UniformTypeIdentifiers

extension UTType {
    static let ipaPayloadLabIPA = UTType(filenameExtension: "ipa")
        ?? UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .zip)
    static let ipaPayloadLabDylib = UTType(filenameExtension: "dylib")
        ?? UTType(importedAs: "com.apple.mach-o-dylib", conformingTo: .data)
    static let ipaPayloadLabDeb = UTType(filenameExtension: "deb")
        ?? UTType(importedAs: "org.debian.deb", conformingTo: .archive)
    static let ipaPayloadLabFramework = UTType(filenameExtension: "framework")
        ?? UTType(importedAs: "com.apple.framework", conformingTo: .package)
}
