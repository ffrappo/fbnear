import Foundation

/// Cookieless event-detail fetch: Googlebot UA gets the full SSR preload
/// (exact timestamps, venue coordinates) from any IP, no account.
enum DetailHTTP {
    struct Detail: Codable {
        var title: String?, start: Int?, end: Int?, lat: Double?, lng: Double?, address: String?, isPast: Bool?
    }

    static func fetch(eventID: String, timeout: TimeInterval = 25) -> Detail? {
        var req = URLRequest(url: URL(string: "https://www.facebook.com/events/\(eventID)/")!)
        req.setValue("Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        guard let data = try? URLSession.synch(request: req), let html = String(data: data, encoding: .utf8) else { return nil }
        return parse(html: html, eventId: eventID)
    }

    static func parse(html: String, eventId: String) -> Detail {
        var d = Detail()
        if let m = html.range(of: #"<title[^>]*>([^<]{1,200})</title>"#, options: .regularExpression) {
            let seg = String(html[m])
            if let a = seg.range(of: ">"), let b = seg.range(of: "</title>", range: a.upperBound..<seg.endIndex) {
                d.title = decodeEntities(String(seg[a.upperBound..<b.lowerBound]))
                    .replacingOccurrences(of: " | Facebook", with: "")
            }
        }
        if let m = html.range(of: #""start_timestamp":(\d{9,})"#, options: .regularExpression) {
            d.start = Int(html[m].split(separator: ":")[1])
        }
        if let m = html.range(of: #""end_timestamp":(\d{9,})"#, options: .regularExpression) {
            d.end = Int(html[m].split(separator: ":")[1])
        }
        if let m = html.range(of: #""is_past":(true|false)"#, options: .regularExpression) {
            d.isPast = html[m].hasSuffix("true")
        }
        // venue bound to THIS event: event_place co-located with the event's own id
        var place: Range<String.Index>? = nil
        var cursor = html.startIndex
        while let m = html.range(of: #""event_place":\{"#, options: .regularExpression, range: cursor..<html.endIndex) {
            cursor = m.upperBound
            let segEnd = html.index(m.upperBound, offsetBy: 900, limitedBy: html.endIndex) ?? html.endIndex
            let seg = html[m.lowerBound..<segEnd]
            guard seg.range(of: #""latitude":"#, options: .regularExpression) != nil else { continue }
            if place == nil { place = m }
            let lo = html.index(m.lowerBound, offsetBy: -8000, limitedBy: html.startIndex) ?? html.startIndex
            let hi = html.index(m.upperBound, offsetBy: 12000, limitedBy: html.endIndex) ?? html.endIndex
            if html[lo..<hi].contains(#""id":"\#(eventId)""#) { place = m; break }
        }
        if let pr = place {
            let segEnd = html.index(pr.upperBound, offsetBy: 900, limitedBy: html.endIndex) ?? html.endIndex
            let seg = String(html[pr.lowerBound..<segEnd])
            if let m = seg.range(of: #""latitude":(-?\d+\.\d+)"#, options: .regularExpression) {
                d.lat = Double(seg[m].split(separator: ":")[1].replacingOccurrences(of: "\"", with: ""))
                if let m2 = seg.range(of: #""longitude":(-?\d+\.\d+)"#, options: .regularExpression) {
                    d.lng = Double(seg[m2].split(separator: ":")[1].replacingOccurrences(of: "\"", with: ""))
                }
            }
            if let m = seg.range(of: #""contextual_name":"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
                let raw = String(seg[m]).split(separator: ":", maxSplits: 1)[1]
                d.address = decodeEntities(String(raw.dropFirst().dropLast()))
            }
        }
        return d
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&#064;", with: "@")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

extension URLSession {
    static func synch(request: URLRequest) throws -> Data {
        var data: Data?; var err: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { d, _, e in data = d; err = e; sem.signal() }.resume()
        sem.wait()
        if let e = err { throw e }
        return data ?? Data()
    }
}
