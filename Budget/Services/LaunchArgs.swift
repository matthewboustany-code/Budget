import Foundation

/// Small helper for reading launch arguments. Used for pointing the app at a
/// local server (`-serverBaseURL`) and, in DEBUG, for scripted UI states
/// (`-resetSession`, `-autoDevSignIn <name>`, `-startTab <id>`) so the flow can
/// be screenshotted with `xcrun simctl` without tapping.
enum LaunchArgs {
    static func value(for flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func has(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }
}
