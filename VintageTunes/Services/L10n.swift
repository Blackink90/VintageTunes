import Foundation

/// Preferenza lingua app (indipendente da macOS, con opzione «Sistema»).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case italian = "it"

    var id: String { rawValue }

    /// Nome nella propria lingua (sempre leggibile nel selettore).
    var displayName: String {
        switch self {
        case .system: return L10n.t("language.system")
        case .english: return "English"
        case .italian: return "Italiano"
        }
    }
}

/// Bundle di localizzazione con override runtime (scelta in Impostazioni).
enum L10n {
    private static let table = "Localizable"
    private static var overrideBundle: Bundle?
    private static var languageCode: String = "en"

    static var locale: Locale { Locale(identifier: languageCode) }

    static var bundle: Bundle { overrideBundle ?? resolvedSystemBundle() ?? .main }

    static func apply(_ language: AppLanguage) {
        switch language {
        case .system:
            overrideBundle = nil
            languageCode = preferredSystemCode()
        case .english, .italian:
            languageCode = language.rawValue
            if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
               let b = Bundle(path: path) {
                overrideBundle = b
            } else {
                overrideBundle = nil
            }
        }
    }

    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: table, bundle: bundle, value: key, comment: "")
    }

    static func tf(_ key: String, _ arguments: CVarArg...) -> String {
        let format = t(key)
        return String(format: format, locale: locale, arguments: arguments)
    }

    private static func preferredSystemCode() -> String {
        for pref in Locale.preferredLanguages {
            let code = String(pref.prefix(2)).lowercased()
            if code == "it" || code == "en" { return code }
        }
        return "en"
    }

    private static func resolvedSystemBundle() -> Bundle? {
        let code = preferredSystemCode()
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj") {
            return Bundle(path: path)
        }
        return nil
    }
}
