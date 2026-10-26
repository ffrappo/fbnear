import Foundation
import AppKit

/// Minimal Safari driver: one reusable tab, never steals focus.
enum Safari {

    static let booted: Bool = {
        _ = osa("tell application \"Safari\"\nrepeat with w in windows\nrepeat with t in tabs of w\nif URL of t starts with \"https://www.facebook.com/events\" then return \"found\"\nend repeat\nend repeat\nmake new tab at end of window 1 with properties {URL:\"https://www.facebook.com/events/\"}\ndelay 6\nreturn \"new\"\nend tell")
        return true
    }()

    @discardableResult
    static func osa(_ src: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", src]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Navigate to url, wait for the events surface, return page HTML.
    static func go(_ url: String) -> String? {
        _ = booted
        guard let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        _ = osa("tell application \"Safari\" to do JavaScript \"location.href=decodeURIComponent(\\\"\(enc)\\\")\" in (first tab of first window whose URL starts with \"https://www.facebook.com/events\")")
        Thread.sleep(forTimeInterval: 6)
        for _ in 0..<8 {
            if let n = eval("document.querySelectorAll('a[href*=\"/events/\"]').length") , let c = Int(n), c > 0 { break }
            Thread.sleep(forTimeInterval: 1.5)
        }
        return eval("document.documentElement.innerHTML.length")
    }

    /// Evaluate JS in the events tab, plain string result (already percent-decoded when JSON).
    static func eval(_ js: String) -> String? {
        let file = NSTemporaryDirectory() + "fbnear-js.txt"
        try? js.write(toFile: file, atomically: true, encoding: .utf8)
        let r = osa("tell application \"Safari\" to do JavaScript (read POSIX file \"\(file)\") in (first tab of first window whose URL starts with \"https://www.facebook.com/events\")")
        if let r = r, let d = r.removingPercentEncoding { return d }
        return r
    }
}

enum FBJS {
    /// Event links with their nearest card text: {id: [text...]} JSON.
    static let links = """
    (function(){
      var seen={}, out={};
      document.querySelectorAll('a[href*="/events/"]').forEach(function(a){
        var m=a.href.match(/\\/events\\/(\\d{10,})/);
        if(!m||seen[m[1]])return;
        seen[m[1]]=1;
        var t=(a.innerText||'').replace(/\\s+/g,' ').trim();
        out[m[1]]=t.slice(0,180);
      });
      return encodeURIComponent(JSON.stringify(out));
    })()
    """
}
