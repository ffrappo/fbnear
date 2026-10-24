import Foundation

/// Final event record plus JSON and flat-color HTML reports.
struct TopLevel: Codable {
    var info: [String: String]
    var events: [EventRecord]
}
struct EventRecord: Codable {
    var id: String
    var url: String
    var title: String
    var start: Date?
    var end: Date?
    var endIsFallback: Bool
    var isPast: Bool?
    var address: String?
    var place: String?
    var lat: Double?
    var lng: Double?
    var driveSeconds: Double?
    var driveMeters: Double?
    var townsSeenIn: [String]
    var whenText: String?
    var keep: Bool
    var dropReason: String?
}

enum Report {
    static func write(records: [EventRecord], runInfo: [String: String], outDir: URL) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try enc.encode(TopLevel(info: runInfo, events: records))
        try json.write(to: outDir.appendingPathComponent("report.json"), options: .atomic)

        var rows = ""
        let df = DateFormatter()
        df.timeZone = Geo.rome
        df.dateFormat = "HH:mm"
        for r in records {
            let time = r.start.map { df.string(from: $0) } ?? "--:--"
            let drive = r.driveSeconds.map { "\(Int(($0 / 60).rounded())) min" } ?? "?"
            let km = r.driveMeters.map { String(format: "%.1f km", $0 / 1000) } ?? ""
            let town = r.address ?? r.place ?? ""
            let titleEsc = escape(r.title)
            let venueEsc = escape(r.place ?? town)
            let addrEsc = escape(town)
            rows += """
            <tr>
              <td class="drive">\(drive)<span>\(km)</span></td>
              <td class="time">\(time)</td>
              <td><a href="\(r.url)">\(titleEsc)</a><span class="venue">\(venueEsc)</span></td>
              <td class="addr">\(addrEsc)</td>
            </tr>
            """
        }
        let meta = runInfo.map { "<span>\(escape($0.key)): \(escape($0.value))</span>" }.joined(separator: "\n")
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>fbnear \(escape(runInfo["date"] ?? ""))</title>
        <style>
          body{font:15px -apple-system,system-ui,sans-serif;color:#111;margin:24px;background:#fff}
          h1{font-size:19px;margin:0 0 4px}
          .meta{color:#555;font-size:12px;margin-bottom:16px;display:flex;gap:16px;flex-wrap:wrap}
          table{border-collapse:collapse;width:100%;max-width:960px}
          td{border-top:1px solid #ddd;padding:9px 10px;vertical-align:top}
          td.drive{font-weight:600;white-space:nowrap;width:86px}
          td.drive span{display:block;font-weight:400;color:#777;font-size:12px}
          td.time{white-space:nowrap;color:#555;width:52px}
          td.addr{color:#555;font-size:13px;width:240px}
          .venue{display:block;color:#555;font-size:13px;margin-top:2px}
          a{color:#0047b3;text-decoration:none}
          a:hover{text-decoration:underline}
        </style></head>
        <body>
        <h1>Events \(escape(runInfo["date"] ?? ""))</h1>
        <div class="meta">\(meta)</div>
        <table>\(rows)</table>
        </body></html>
        """
        try Data(html.utf8).write(to: outDir.appendingPathComponent("report.html"), options: .atomic)
    }

    static func consoleSummary(records: [EventRecord]) -> String {
        let df = DateFormatter()
        df.timeZone = Geo.rome
        df.dateFormat = "HH:mm"
        var lines: [String] = []
        for r in records.prefix(40) {
            let time = r.start.map { df.string(from: $0) } ?? "--:--"
            let drive = r.driveSeconds.map { "\(Int(($0 / 60).rounded()))min" } ?? "?"
            lines.append("\(drive)\t\(time)\t\(r.title.prefix(70))\t\((r.place ?? r.address ?? "").prefix(40))")
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
