import Foundation

enum AppReleaseMetadata {
    private static let fallbackVersion = "0.12.0"
    private static let fallbackBuild = "186"

    static var version: String {
        Bundle.main.object(
            forInfoDictionaryKey:
                "CFBundleShortVersionString"
        ) as? String ?? fallbackVersion
    }

    static var build: String {
        Bundle.main.object(
            forInfoDictionaryKey:
                "CFBundleVersion"
        ) as? String ?? fallbackBuild
    }

    static var userAgent: String {
        "AI-Access-Assistant/\(version)"
    }
}
