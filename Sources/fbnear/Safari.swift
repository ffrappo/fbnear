import Foundation

/// Drives the owner's logged-in Safari session via osascript "do JavaScript".
/// All JS payloads go through temp files to avoid AppleScript string escaping.
struct SafariDriver {
    let jsDir: URL

    init() {
        jsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbnear-js-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: jsDir, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: jsDir) }

    @discardableResult
    private func osa(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let input = Pipe()
        let out = Pipe()
        let err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus != 0 {
            throw FbnearError.safariScript(String(data: errData, encoding: .utf8) ?? s)
        }
        return s
    }

    /// Runs JS in the first tab showing facebook.com/events (creates one if absent).
    /// JS must return encodeURIComponent(...) or a plain string.
    func eval(_ js: String, timeout seconds: Int = 20) throws -> String {
        let f = jsDir.appendingPathComponent("\(UUID().uuidString.prefix(12)).js")
        try js.write(to: f, atomically: true, encoding: .utf8)
        let script = """
        with timeout of \(seconds * 10) seconds
        tell application "Safari"
        set t to missing value
        repeat with w in windows
        repeat with tb in tabs of w
        if URL of tb starts with "https://www.facebook.com/events/" then
        set t to tb
        exit repeat
        end if
        end repeat
        if t is not missing value then exit repeat
        end repeat
        if t is missing value then
        try
        tell window 1
        set t to make new tab at end with properties {URL:"https://www.facebook.com/events/"}
        end tell
        on error
        activate
        set t to make new document at end of windows
        set URL of t to "https://www.facebook.com/events/"
        end try
        delay 4
        end if
        return do JavaScript (read POSIX file "\(f.path)") in t
        end tell
        end timeout
        """
        let raw = try osa(script)
        try? FileManager.default.removeItem(at: f)
        if raw.isEmpty { return "" }
        // JS side returns encodeURIComponent(JSON) when structured; decode transparently.
        if raw != raw.removingPercentEncoding ?? raw, let dec = raw.removingPercentEncoding {
            return dec
        }
        return raw
    }

    func evalJSON(_ js: String, timeout seconds: Int = 20) throws -> Data {
        let raw = try eval(js, timeout: seconds)
        guard let data = raw.data(using: .utf8), !data.isEmpty else { return Data("null".utf8) }
        return data
    }

    /// Navigates our tab and waits until `readyJS` returns "1".
    func go(_ url: String, readyJS: String, timeout seconds: Int = 20) throws {
        _ = try eval("location.href=\(jsStr(url))")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.7)
            let r = (try? eval(readyJS)) ?? ""
            if r == "1" { Thread.sleep(forTimeInterval: 0.6); return }
        }
        throw FbnearError.pageTimeout(url)
    }

    func closeOurTab() {
        _ = try? osa("""
        tell application "Safari"
        repeat with w in windows
        repeat with tb in tabs of w
        if URL of tb starts with "https://www.facebook.com/events/" then
        close tb
        exit repeat
        end if
        end repeat
        end repeat
        end tell
        """)
    }

    private func jsStr(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(esc)'"
    }
}

enum FbnearError: Error, CustomStringConvertible {
    case safariScript(String)
    case pageTimeout(String)

    var description: String {
        switch self {
        case .safariScript(let s): return "Safari/osascript error: \(s.prefix(300))"
        case .pageTimeout(let u): return "Page never became ready: \(u.prefix(120))"
        }
    }
}
