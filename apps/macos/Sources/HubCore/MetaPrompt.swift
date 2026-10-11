import Foundation

/// What Meta's ovr-platform-util is asking for, read from its terminal output. The tool's
/// get-access-token prompts are "Email: ", "Password <hidden>: ", and for a code either
/// "Enter two-factor authentication code: " (authenticator / 2FA) or "Enter 6 Digit Code: "
/// (e-mailed confirmation of an unusual login). Matching is loose so wording changes still work.
public enum MetaPrompt: Equatable, Sendable {
    case email, password, code

    /// The prompt the tool is waiting on, judged from the last line of `output` (text since the
    /// last answer). Nil while the tool is mid-line/working or the line is something else.
    public static func detect(in output: String) -> MetaPrompt? {
        let lines = output.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: true)
        guard let raw = lines.last else { return nil }
        let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard line.hasSuffix(":") else { return nil }
        let codeWords = ["code", "two-factor", "two factor", "2fa", "verification", "otp", "one-time", "passcode", "pin"]
        if codeWords.contains(where: { line.contains($0) }) { return .code }
        if line.contains("password") { return .password }
        if line.contains("email") || line.contains("e-mail") { return .email }
        return nil
    }

    /// Whether `s` is a plausible code: 6–8 digits (spaces ignored).
    public static func isValidCode(_ s: String) -> Bool {
        let d = s.filter { !$0.isWhitespace }
        return (6...8).contains(d.count) && d.allSatisfy(\.isASCII) && d.allSatisfy(\.isNumber)
    }

    public static func normalizedCode(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// The last few meaningful lines of a failed run, for showing the tool's own error.
    public static func errorTail(_ output: String, lines n: Int = 3) -> String {
        output.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && detect(in: $0) == nil }
            .suffix(n).joined(separator: " ")
    }
}
