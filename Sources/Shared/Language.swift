import Foundation

/// Norwegian if the user's preferred macOS language is Norwegian, else English.
let isNorwegian: Bool = {
    let lang = Locale.preferredLanguages.first?.lowercased() ?? ""
    return ["nb", "no", "nn"].contains { lang.hasPrefix($0) }
}()

let appLocale = Locale(identifier: isNorwegian ? "nb_NO" : "en_US")

func tr(_ no: String, _ en: String) -> String { isNorwegian ? no : en }
