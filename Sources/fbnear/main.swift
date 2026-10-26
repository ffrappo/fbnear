import Foundation
import MapKit

// fbnear — minimal pipeline: day-feed + town LOCAL harvest, cookieless details,
// MKDirections drive filter, publish to the webapp. One Safari tab, sequential.

let fm = FileManager.default
let configDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/fbnear")

struct Config: Codable { var originLat = 45.5071219, originLng = 10.897683, maxDriveMin = 45 }
let config: Config = {
    if let c = try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configDir.appendingPathComponent("config.json"))) { return c }
    return Config()
}()

let args = Array(CommandLine.arguments.dropFirst())
func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let publish = args.contains("--publish")
let dateArg = arg("--date") ?? "today"
let cal = Calendar.current
let targetDay: Date = dateArg == "tomorrow" ? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
    : dateArg == "yesterday" ? cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
    : cal.startOfDay(for: Date())
let dayDF = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Europe/Rome"); return f }()
let dateISO = dayDF.string(from: targetDay)

// Facebook city codes (stable entity ids, resolved once via typeahead)
let towns: [(name: String, code: String)] = [
    ("San Pietro in Cariano", "112924008721269"), ("Pescantina", "107895299233216"),
    ("Negrar", "109549845738528"), ("Marano di Valpolicella", "113022425379043"),
    ("Bussolengo", "116111211735720"), ("Pastrengo", "107855569238025"),
    ("Fumane", "112509062094618"), ("Verona", "115367971811113"),
    ("Grezzana", "105628989470115"), ("Sona", "108075639220587"),
    ("San Giovanni Lupatoto", "107597025936207"), ("Caprino Veronese", "106148689416778"),
]

struct Ev: Codable {
    var id: String, title: String = "", whenText: String = ""
    var start: Date?, end: Date?, lat: Double?, lng: Double?, address: String?
    var driveSeconds: Double?, driveMeters: Double?, drop: String? = nil
    var townsSeenIn: [String] = []
}

// MARK: harvest (one tab, sequential pages)

let dayMidnightUTC = { () -> String in
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let midRome = cal.date(bySettingHour: 0, minute: 0, second: 0, of: targetDay)!
    return f.string(from: midRome).replacingOccurrences(of: ":", with: "%3A")
}()
final class EventMap { var map: [String: Ev] = [:] }
let events = EventMap()

final class Flag { var on = false }
let blocked = Flag()
@MainActor
func harvestPage(url: String, name: String) {
    guard !blocked.on else { return }
    guard let _ = Safari.go(url) else { print("  [harvest] failed: \(name)"); return }
    if let body = Safari.eval("encodeURIComponent(document.body.innerText.slice(0,150))"),
       body.contains("Temporarily Blocked") {
        print("  [harvest] BLOCKED (rate limit); stopping harvest, keeping what we have")
        blocked.on = true
        return
    }
    Thread.sleep(forTimeInterval: 2.5)
    guard let links = Safari.eval(FBJS.links) else { return }
    var fresh = 0
    if let data = links.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        for (id, text) in dict where events.map[id] == nil {
            events.map[id] = Ev(id: id, title: text, whenText: text, townsSeenIn: [name])
            fresh += 1
        }
    }
    print("  \(name.padding(toLength: 28, withPad: " ", startingAt: 0)) +\(fresh)")
}

@MainActor
func harvest() {
    let feed = "https://www.facebook.com/events/?date_filter_option=TODAY&discover_tab=CUSTOM&end_date=\(dayMidnightUTC)&start_date=\(dayMidnightUTC)"
    var pages: [(String, String)] = [("https://www.facebook.com/events/", "Dashboard")]
    for t in towns.prefix(4) { pages.append(("https://www.facebook.com/events/?discover_tab=LOCAL&location_id=\(t.code)", t.name)) }
    // interleave 2 day-feed loads between the other pages, human pace
    var seq: [(String, String)] = []
    for (i, p) in pages.enumerated() {
        seq.append(p)
        if i == 1 || i == 3 { seq.append((feed, "Day feed #\(i / 2)")) }
    }
    for (url, name) in seq {
        harvestPage(url: url, name: name)
        if blocked.on { break }
        Thread.sleep(forTimeInterval: 11 + Double.random(in: 0...7))
    }
}

// MARK: pool (runs accumulate; feeds rotate slots)

let poolURL = configDir.appendingPathComponent("pool-\(dateISO).json")
struct OldEv: Codable { var id: String = "", title: String = "", whenText: String = ""; var start: Date?, end: Date?, lat: Double?, lng: Double?, address: String?; var driveSeconds: Double?, driveMeters: Double?, drop: String? = nil; var townsSeenIn: [String]? = nil; var townsSeen: [String]? = nil }
let poolData = try? Data(contentsOf: poolURL)
var poolLoaded: [String: Ev] = [:]
if let pd = poolData, let old = try? JSONDecoder().decode([String: OldEv].self, from: pd) {
    for (k, v) in old { poolLoaded[k] = Ev(id: v.id, title: v.title, whenText: v.whenText, start: v.start, end: v.end, lat: v.lat, lng: v.lng, address: v.address, driveSeconds: nil, driveMeters: nil, drop: nil, townsSeenIn: v.townsSeenIn ?? v.townsSeen ?? []) }
} else if let p2 = (try? JSONDecoder().decode([String: Ev].self, from: poolData ?? Data())) { poolLoaded = p2 }
if !poolLoaded.isEmpty {
    let pooled = poolLoaded.filter { events.map[$0.key] == nil }.count
    for (id, e) in poolLoaded where events.map[id] == nil { events.map[id] = e }
    if pooled > 0 { print("[pool] +\(pooled) from earlier runs today") }
}

harvest()

// MARK: details (cookieless crawler fetch, 12h cache)

typealias Detail = DetailHTTP.Detail
struct CacheEntry: Codable { var detail: Detail; var fetchedAt: Date }
let cacheURL = configDir.appendingPathComponent("details.json")
var cache: [String: CacheEntry] = (try? JSONDecoder().decode([String: CacheEntry].self, from: Data(contentsOf: cacheURL))) ?? [:]

for (id, e) in events.map where e.start == nil {
    if let c = cache[id], c.fetchedAt > Date().addingTimeInterval(-43200) {
        let d = c.detail
        events.map[id]?.start = d.start.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        events.map[id]?.end = d.end.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        events.map[id]?.lat = d.lat; events.map[id]?.lng = d.lng
        events.map[id]?.address = d.address
        if let t = d.title, t.count > 3 { events.map[id]?.title = t }
        continue
    }
    if let d = DetailHTTP.fetch(eventID: id) {
        cache[id] = CacheEntry(detail: d, fetchedAt: Date())
        events.map[id]?.start = d.start.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        events.map[id]?.end = d.end.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        events.map[id]?.lat = d.lat; events.map[id]?.lng = d.lng; events.map[id]?.address = d.address
        if let t = d.title, t.count > 3 { events.map[id]?.title = t }
        Thread.sleep(forTimeInterval: 0.6)
    }
}
if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL) }

// MARK: geo + drive ETA

let origin = CLLocationCoordinate2D(latitude: config.originLat, longitude: config.originLng)

var geocodeTargets: [(String, String)] = []
for (id, e) in events.map where e.start != nil && e.lat == nil {
    var q = e.address ?? ""
    if q.isEmpty { q = "\(e.title.split(separator: "@").last.map(String.init) ?? e.title), Verona" }
    if q.count > 2 { geocodeTargets.append((id, q)) }
}
let geoGroup = DispatchGroup()
for (id, q) in geocodeTargets {
    let req = MKLocalSearch.Request(); req.naturalLanguageQuery = q
    req.region = MKCoordinateRegion(center: origin, latitudinalMeters: 80000, longitudinalMeters: 80000)
    geoGroup.enter()
    MKLocalSearch(request: req).start { resp, _ in
        if let c = resp?.mapItems.first?.placemark.location?.coordinate { events.map[id]?.lat = c.latitude; events.map[id]?.lng = c.longitude }
        geoGroup.leave()
    }
    Thread.sleep(forTimeInterval: 0.3)
}
while geoGroup.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

let etaIds = events.map.keys.filter { events.map[$0]!.start != nil && events.map[$0]!.lat != nil }
var etas: [String: (Double, Double)] = [:]
let group = DispatchGroup()
for id in etaIds {
    guard let e = events.map[id], let la = e.lat, let lo = e.lng else { continue }
    group.enter()
    let req = MKDirections.Request()
    req.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
    req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo)))
    req.transportType = .automobile
    let dir = MKDirections(request: req)
    dir.calculate { resp, _ in
        if let s = resp?.routes.first { etas[id] = (s.expectedTravelTime, s.distance) }
        group.leave()
    }
}
while group.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

// MARK: filter + sort

let dayEnd = targetDay.addingTimeInterval(86400)
let now = Date()
var kept: [Ev] = []
for (id, e) in events.map {
    var r = e
    guard let start = r.start else { r.drop = "no timestamps"; events.map[id] = r; continue }
    let end = r.end ?? start.addingTimeInterval(3 * 3600)
    guard start < dayEnd && end > targetDay else { r.drop = "not on \(dateISO)"; events.map[id] = r; continue }
    guard end > now, r.title.contains("Online") == false else { r.drop = "finished/online"; events.map[id] = r; continue }
    guard let eta = etas[id] else { r.drop = "no ETA"; events.map[id] = r; continue }
    guard eta.0 <= Double(config.maxDriveMin * 60) else { r.drop = "drive \(Int(eta.0 / 60)) min"; events.map[id] = r; continue }
    r.driveSeconds = eta.0; r.driveMeters = eta.1
    kept.append(r)
}
kept.sort { ($0.driveSeconds ?? .infinity) < ($1.driveSeconds ?? .infinity) }

// pool only grows: merge with what is on disk so a failed harvest never shrinks it
for (id, e) in poolLoaded where events.map[id] == nil { events.map[id] = e }
if let data = try? JSONEncoder().encode(events.map), events.map.count >= poolLoaded.count {
    try? data.write(to: poolURL)
}
let timeF = { let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "Europe/Rome"); return f }()
print("\nfbnear \(dateISO) — \(kept.count) reachable (of \(events.map.count) seen)")
for e in kept { print("  \(Int((e.driveSeconds ?? 0) / 60))min\t\(e.start.map(timeF.string(from:)) ?? "?")\t\(e.title.prefix(60))") }

// MARK: publish (webapp data.json, day-merged)

if publish && !(kept.isEmpty && events.map.count < 3) {
    struct WebEvent: Codable { var title: String; var url: String; var start: Date; var end: Date; var driveSeconds: Double; var driveMeters: Double; var venue: String? }
    struct WebDay: Codable { var events: [WebEvent]; var generatedAt: String }
    struct WebData: Codable { var days: [String: WebDay] }
    let repo = "/Users/ffrappo/works/repos/fbnear"
    let dataURL = URL(fileURLWithPath: repo + "/web/data.json")
    var web = (try? JSONDecoder().decode(WebData.self, from: Data(contentsOf: dataURL))) ?? WebData(days: [:])
    web.days = web.days.filter { $0.key >= dayDF.string(from: cal.startOfDay(for: Date())) }
    web.days[dateISO] = WebDay(events: kept.map { e in
        WebEvent(title: String(e.title.prefix(90)), url: "https://www.facebook.com/events/\(e.id)/",
                 start: e.start ?? now, end: e.end ?? now,
                 driveSeconds: e.driveSeconds ?? 0, driveMeters: e.driveMeters ?? 0, venue: e.address)
    }, generatedAt: timeF.string(from: now))
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(web) {
        try? data.write(to: dataURL)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "cd \(repo) && git add web/data.json && git commit -qm 'data \(dateISO)' && git push -q origin main && git subtree split -q --prefix=web -b gh-pages-tmp && git push -q origin gh-pages-tmp:gh-pages && git branch -qD gh-pages-tmp"]
        try? p.run(); p.waitUntilExit()
        print("[publish] web/data.json updated and pushed")
    }
}
