import Foundation

/// Cookieless event-detail fetch: Facebook serves the full SSR preload
/// (exact timestamps, venue coordinates) to crawler user agents.
/// Used before the session-bound Safari paths; IP-rate-class only.
enum DetailHTTP {
    static let ua = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

    struct Result {
        var title: String?
        var start: Int?
        var end: Int?
        var lat: Double?
        var lng: Double?
        var address: String?
        var isPast: Bool?
    }

    static func fetch(eventID: String, timeout: TimeInterval = 25) throws -> Result {
        var req = URLRequest(url: URL(string: "https://www.facebook.com/events/\(eventID)/")!)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var payload: Data?
        var err: String?
        let task = URLSession.shared.dataTask(with: req) { d, resp, e in
            if let e = e { err = e.localizedDescription }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 { err = "HTTP \(http.statusCode)" }
            else { payload = d }
            sem.signal()
        }
        task.resume()
        guard sem.wait(timeout: .now() + timeout + 5) == .success, let data = payload else {
            throw FbnearError.safariScript("detail-http: \(err ?? "timeout")")
        }
        return parse(html: String(data: data, encoding: .utf8) ?? "")
    }

    static func parse(html: String) -> Result {
        var r = Result()
        if let m = html.range(of: "<title[^>]*>", options: .regularExpression) {
            let rest = String(html[m.upperBound...]).prefix(200)
            if let close = rest.range(of: "</title>") {
                let t = Self.decodeEntities(String(rest[..<close.lowerBound]))
                    .replacingOccurrences(of: " | Facebook", with: "")
                if !t.isEmpty { r.title = t }
            }
        }
        if let m = html.range(of: #""start_timestamp":(\d{9,})"#, options: .regularExpression) {
            r.start = Int(html[m].split(separator: ":")[1])
        }
        if let m = html.range(of: #""end_timestamp":(\d{9,})"#, options: .regularExpression) {
            r.end = Int(html[m].split(separator: ":")[1])
        }
        if let m = html.range(of: #""latitude":(-?\d+\.\d+)"#, options: .regularExpression) {
            r.lat = Double(html[m].split(separator: ":")[1].replacingOccurrences(of: "\"", with: ""))
            if let m2 = html.range(of: #""longitude":(-?\d+\.\d+)"#, options: .regularExpression) {
                r.lng = Double(html[m2].split(separator: ":")[1].replacingOccurrences(of: "\"", with: ""))
            }
        }
        if let m = html.range(of: #""contextual_name":"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
            let raw = String(html[m])
            let val = raw.split(separator: ":", maxSplits: 1)[1]
            let trimmed = val.dropFirst().dropLast()
            r.address = Self.decodeEntities(String(trimmed))
        }
        if let m = html.range(of: #""is_past":(true|false)"#, options: .regularExpression) {
            r.isPast = html[m].hasSuffix("true")
        }
        return r
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (e, c) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"), ("&apos;", "'"), ("&#x27;", "'")] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out
    }
}
