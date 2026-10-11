import Foundation

/// Two-language strings: Spanish when the system's first preferred language is Spanish,
/// English otherwise. Deliberately tiny — this is a personal tool, not a localized product.
public enum Lang {
    public static var isSpanish: Bool = {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("es")
    }()
}

public func L(_ es: String, _ en: String) -> String { Lang.isSpanish ? es : en }
