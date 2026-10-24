import Foundation

/// Drives the owner's logged-in Safari session via osascript "do JavaScript",
/// fully in the background. Each instance owns one worker tab identified by a
/// &fbw=<n> URL marker so several drivers can load pages in parallel.
/// All JS payloads go through temp files to avoid AppleScript escaping.
final class SafariDriver: @unchecked Sendable {
    let worker: Int
    let marker: String
    let jsDir: URL

    init(worker: Int = 0) {
        self.worker = worker
        self.marker = "fbw=\(worker)"
        jsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fbnear-js-w\(worker)-\(UUID().uuidString.prefix(6))")
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

    private static func appleScript(for path: String, marker: String, timeout: Int) -> String {
        """
        with timeout of \(timeout) seconds
        tell application "Safari"
        set t to missing value
        repeat with w in windows
        repeat with tb in tabs of w
        if URL of tb starts with "https://www.facebook.com/events/" and URL of tb contains "\(marker)" then
        set t to tb
        exit repeat
        end if
        end repeat
        if t is not missing value then exit repeat
        end repeat
        if t is missing value then
        try
        tell window 1
        set t to make new tab at end with properties {URL:"https://www.facebook.com/events/?\(marker)"}
        end tell
        on error
        activate
        set t to make new document at end of windows
        set URL of t to "https://www.facebook.com/events/?\(marker)"
        end try
        delay 4
        end if
        return do JavaScript (read POSIX file "\(path)") in t
        end tell
        end timeout
        """
    }

    /// Runs JS in this worker's tab. JS may return encodeURIComponent(...) or plain text.
    func eval(_ js: String, timeout seconds: Int = 25) throws -> String {
        let f = jsDir.appendingPathComponent("\(UUID().uuidString.prefix(12)).js")
        try js.write(to: f, atomically: true, encoding: .utf8)
        let raw = try osa(Self.appleScript(for: f.path, marker: marker, timeout: seconds * 10))
        try? FileManager.default.removeItem(at: f)
        if raw.isEmpty { return "" }
        if raw != raw.removingPercentEncoding ?? raw, let dec = raw.removingPercentEncoding {
            return dec
        }
        return raw
    }

    func evalJSON(_ js: String, timeout seconds: Int = 25) throws -> Data {
        let raw = try eval(js, timeout: seconds)
        guard let data = raw.data(using: .utf8), !data.isEmpty else { return Data("null".utf8) }
        return data
    }

    static let blockProbe = "(document.body&&document.body.innerText&&document.body.innerText.indexOf('Temporarily Blocked')>=0)?'1':'0'"

    /// Navigates this worker's tab and waits until `readyJS` returns "1".
    /// Detects Facebook's rate-limit interstitial and aborts with a clear error.
    func go(_ url: String, readyJS: String, timeout seconds: Int = 30) throws {
        let marked = url + (url.contains("?") ? "&" : "?") + marker
        _ = try eval("location.href=\(Self.jsStr(marked))")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let r = (try? eval(readyJS)) ?? ""
            if r == "1" { Thread.sleep(forTimeInterval: 0.3); return }
            if (try? eval(Self.blockProbe)) ?? "0" == "1" {
                throw FbnearError.blocked
            }
        }
        throw FbnearError.pageTimeout(url)
    }

    func closeOurTab() {
        _ = try? osa("""
        tell application "Safari"
        set toClose to {}
        repeat with w in windows
        repeat with tb in tabs of w
        if URL of tb starts with "https://www.facebook.com/events/" and URL of tb contains "\(marker)" then set end of toClose to tb
        end repeat
        end repeat
        repeat with tb in toClose
        close tb
        end repeat
        end tell
        """)
    }

    static func jsStr(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(esc)'"
    }
}

enum FbnearError: Error, CustomStringConvertible {
    case safariScript(String)
    case pageTimeout(String)
    case blocked

    var description: String {
        switch self {
        case .safariScript(let s): return "Safari/osascript error: \(s.prefix(300))"
        case .pageTimeout(let u): return "Page never became ready: \(u.prefix(120))"
        case .blocked: return "Facebook temporarily blocked this feature (too fast). Wait, then re-run with --tabs 1 and fewer queries."
        }
    }
}

/// Lock-protected mutable box shared across worker threads.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ body: (inout T) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
