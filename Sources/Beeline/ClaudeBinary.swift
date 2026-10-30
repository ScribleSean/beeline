import Foundation
import Security

/// macOS charges a child's permission checks to the app that launched it, so Beeline only runs a claude
/// that Anthropic signed.
/// The team is checked, not the identifier, so a rename on Anthropic's side doesn't break the planner.
enum ClaudeBinary {
    static let anthropic = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""

    static func verified(_ url: URL, requirement: String = anthropic) -> URL? {
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        let path = URL(fileURLWithPath: String(cString: real))
        var code: SecStaticCode?
        var required: SecRequirement?
        guard FileManager.default.isExecutableFile(atPath: path.path),
              SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess, let required
        else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, required) == errSecSuccess ? path : nil
    }

    static func refusal(_ url: URL) -> String {
        "The claude at \((url.path as NSString).abbreviatingWithTildeInPath) isn't signed by Anthropic, so Beeline won't run it."
    }
}

extension Planner {
    static func launchable(_ found: URL?, requirement: String = ClaudeBinary.anthropic) -> Result<URL, Failure> {
        guard let found else { return .failure(.message(notFoundMessage)) }
        guard let real = ClaudeBinary.verified(found, requirement: requirement) else {
            Log.append("refused unsigned claude at \(found.path)")
            return .failure(.message(ClaudeBinary.refusal(found)))
        }
        return .success(real)
    }
}
