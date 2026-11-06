import Foundation

struct CommandResponse {
    let status: Int32
    let output: String
    let launchError: String?

    var succeeded: Bool { status == 0 && launchError == nil }
}

enum CommandRunner {
    // No shell, no interpolation: arguments are passed directly to the system process.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 45) -> CommandResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LANG"] = "C"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResponse(status: -1, output: "", launchError: error.localizedDescription)
        }

        let timeoutTask = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()
        let output = String(decoding: data.prefix(48_000), as: UTF8.self)
        return CommandResponse(status: process.terminationStatus, output: output, launchError: nil)
    }
}

// An explicitly supplied checksum is never accepted as proof of origin by itself.
enum Checksum {
    static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64, trimmed.unicodeScalars.allSatisfy({
            ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
        }) else { return nil }
        return trimmed
    }

    static func sha256(of url: URL) -> String? {
        let result = CommandRunner.run("/usr/bin/shasum", ["-a", "256", "--", url.path], timeout: 180)
        guard result.succeeded, let token = result.output.split(separator: " ").first else { return nil }
        return normalize(String(token))
    }
}

// This validates input syntax only. It does NOT confirm domain ownership or authenticity.
enum SourceURLValidator {
    static func isHTTPS(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}

/// Runs a single command as root through the standard macOS administrator password prompt.
/// Arguments are passed as argv to osascript and quoted with `quoted form of`, so no
/// path can be interpreted as shell syntax.
enum PrivilegedRunner {
    private static let script = """
    on run argv
        set cmd to ""
        repeat with a in argv
            set cmd to cmd & quoted form of (a as text) & " "
        end repeat
        return do shell script cmd with administrator privileges
    end run
    """

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 900) -> CommandResponse {
        CommandRunner.run("/usr/bin/osascript", ["-e", script, path] + arguments, timeout: timeout)
    }

    static func userCancelled(_ response: CommandResponse) -> Bool {
        response.output.contains("-128") || response.output.lowercased().contains("user canceled")
    }
}
