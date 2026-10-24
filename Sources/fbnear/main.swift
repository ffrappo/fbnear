import Foundation

// fbnear: Facebook events reachable by car from home, harvested from
// neighboring towns in concentric rings through the logged-in Safari session.

struct Config: Codable {
    var originLat: Double = 45.50712
    var originLng: Double = 10.89768
    var originLabel: String = "San Pietro in Cariano"
    var defaultDurationMin: Int = 180
    var graceMin: Int = 30
    var minRemainingMin: Int = 15
}

let fm = FileManager.default
let configDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/fbnear")
let configURL = configDir.appendingPathComponent("config.json")
let townsURL = configDir.appendingPathComponent("towns.json")

@MainActor
func loadConfig() -> Config {
    if let data = try? Data(contentsOf: configURL),
       let c = try? JSONDecoder().decode(Config.self, from: data) { return c }
    let c = Config()
    try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(c) { try? data.write(to: configURL) }
    return c
}

let args = CommandLine.arguments.dropFirst()
@MainActor
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
@MainActor
func hasFlag(_ name: String) -> Bool { args.contains(name) }

var cal = Calendar(identifier: .gregorian)
cal.timeZone = Geo.rome
let now = Date()

let dateArg = argValue("--date") ?? "today"
let targetDay: Date
switch dateArg {
case "today": targetDay = cal.startOfDay(for: now)
case "tomorrow": targetDay = cal.startOfDay(for: now.addingTimeInterval(86_400))
default:
    let df = DateFormatter()
    df.timeZone = Geo.rome
    df.dateFormat = "yyyy-MM-dd"
    guard let d = df.date(from: dateArg) else {
        print("Invalid --date \(dateArg). Use today, tomorrow or YYYY-MM-DD.")
        exit(2)
    }
    targetDay = cal.startOfDay(for: d)
}
let dayDF = DateFormatter()
dayDF.timeZone = Geo.rome
dayDF.dateFormat = "yyyy-MM-dd"
let dateISO = dayDF.string(from: targetDay)

@MainActor
func run() throws {
    let config = loadConfig()
    let maxDriveMin = Int(argValue("--max-drive") ?? "") ?? 45
    let radiusKm = Double(argValue("--radius") ?? "") ?? 30
    let rings = argValue("--rings").map { $0.split(separator: ",").compactMap { Double($0) } } ?? [5, 10, 15, 20, 30]
    let maxDetails = Int(argValue("--max-details") ?? "") ?? 200
    let fbDateFilter = hasFlag("--fb-date-filter")
    let noPrefilter = hasFlag("--no-prefilter")
    let queries = (argValue("--query") ?? "events").split(separator: ",").map(String.init)
    let refreshTowns = hasFlag("--refresh-towns")
    let keepTab = hasFlag("--keep-tab")
    let categories = (argValue("--categories") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }

    let outDir = URL(fileURLWithPath: argValue("--out")
        ?? fm.homeDirectoryForCurrentUser.path + "/works/artifacts/fbnear/\(dateISO)-\(Int(now.timeIntervalSince1970))")

    let origin = (config.originLat, config.originLng)
    print("fbnear | date \(dateISO) | max drive \(maxDriveMin) min | radius \(Int(radiusKm)) km | origin \(config.originLabel)")

    // MARK: Stage 1: towns

    var towns: [Town]
    if !refreshTowns,
       let data = try? Data(contentsOf: townsURL),
       let cache = try? JSONDecoder().decode(TownsCache.self, from: data),
       abs(cache.originLat - origin.0) < 0.01,
       abs(cache.originLng - origin.1) < 0.01,
       cache.radiusKm >= radiusKm {
        towns = cache.towns
        print("[towns] cached \(towns.count) municipalities (radius \(Int(cache.radiusKm)) km)")
    } else {
        let stageStart = Date()
        let raw = try Towns.fetchOverpass(origin: origin, radiusKm: radiusKm)
        towns = Towns.bucket(raw, origin: origin, rings: rings)
        print("[towns] overpass: \(raw.count) municipalities, \(towns.count) within \(Int(radiusKm)) km (\(Int(Date().timeIntervalSince(stageStart)))s)")
    }

    // Straight-line drive gate: road distance approx 1.5x straight line at >=45 km/h.
    func driveGateOk(_ km: Double) -> Bool {
        (km * 1.5) / 0.75 <= Double(maxDriveMin) + 10
    }
    var gatedTowns = towns.filter { driveGateOk($0.km) }
    let gatedOut = towns.count - gatedTowns.count
    if gatedOut > 0 { print("[towns] drive gate skips \(gatedOut) towns beyond ~\(maxDriveMin + 10) min") }

    let driver = SafariDriver()
    defer {
        if !keepTab { driver.closeOurTab() }
        driver.cleanup()
    }

    // MARK: Stage 2: resolve FB town codes

    let missing = gatedTowns.filter { $0.fbCode == nil }
    if !missing.isEmpty {
        print("[codes] resolving \(missing.count) town codes via typeahead...")
        _ = try driver.go("https://www.facebook.com/events/search/?q=x", readyJS: FB.searchReady)
        Thread.sleep(forTimeInterval: 1.5)
        var resolved = 0
        for var t in missing {
            var result: (code: String, canonical: String)? = nil
            for _ in 0..<2 {
                result = try? Towns.resolveCode(driver: driver, name: t.name)
                if result != nil { break }
                _ = try? driver.go("https://www.facebook.com/events/search/?q=x", readyJS: FB.searchReady)
                Thread.sleep(forTimeInterval: 1.5)
            }
            var townName = t.name
            if result == nil {
                // FB sometimes lists short names (Negrar, Rivoli) or unaccented forms
                let alt = t.name
                    .replacingOccurrences(of: " di Valpolicella", with: "")
                    .replacingOccurrences(of: " Veronese", with: "")
                    .replacingOccurrences(of: "è", with: "e")
                    .replacingOccurrences(of: "à", with: "a")
                    .replacingOccurrences(of: "ù", with: "u")
                if alt != t.name {
                    townName = alt
                    result = try? Towns.resolveCode(driver: driver, name: alt)
                }
            }
            if let r = result {
                t.fbCode = r.code
                t.fbName = r.canonical
                resolved += 1
                print("  ok \(t.name) -> \(r.code) (\(r.canonical))")
            } else {
                t.unresolvedReason = "no typeahead match"
                print("  MISS \(t.name)")
            }
            _ = townName
            if let i = gatedTowns.firstIndex(where: { $0.name == t.name }) { gatedTowns[i] = t }
            Thread.sleep(forTimeInterval: 0.4)
        }
        print("[codes] resolved \(resolved)/\(missing.count)")
    }

    let cache = TownsCache(originLat: origin.0, originLng: origin.1, radiusKm: radiusKm, updatedAt: Date(), towns: gatedTowns)
    if let data = try? JSONEncoder().encode(cache) {
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? data.write(to: townsURL)
    }

    let searchable = gatedTowns.filter { $0.fbCode != nil }
    print("[codes] \(searchable.count) towns searchable")

    // MARK: Stage 3: harvest cards per town

    var events: [String: EventRecord] = [:]
    var stageStart = Date()
    var loadedPages = 0
    harvest: for town in searchable {
        for q in queries {
            let url = FB.searchURL(townCode: town.fbCode!, dateISO: fbDateFilter ? dateISO : nil, categoryCode: categories.first, query: q)
            do {
                try driver.go(url, readyJS: FB.searchReady)
            } catch {
                print("  [harvest] page failed \(town.name): \(error)")
                continue
            }
            loadedPages += 1
            if let data = try? driver.evalJSON(FB.extractCards),
               let cards = try? JSONDecoder().decode([FB.Card].self, from: data) {
                var fresh = 0
                for c in cards {
                    if events[c.id] == nil {
                        events[c.id] = EventRecord(
                            id: c.id, url: "https://www.facebook.com/events/\(c.id)/",
                            title: c.text, start: nil, end: nil, endIsFallback: false,
                            isPast: nil, address: nil, place: nil, lat: nil, lng: nil,
                            driveSeconds: nil, driveMeters: nil,
                            townsSeenIn: [town.name], whenText: c.text, keep: false)
                        fresh += 1
                    } else if !events[c.id]!.townsSeenIn.contains(town.name) {
                        events[c.id]!.townsSeenIn.append(town.name)
                    }
                }
                print("  [\(String(format: "%4.1f", town.km)) km] \(town.name.padding(toLength: 30, withPad: " ", startingAt: 0)) +\(fresh)")
            }
            Thread.sleep(forTimeInterval: 0.5)
            if events.count >= maxDetails * 3 { print("[harvest] early stop: enough candidates"); break harvest }
        }
    }
    print("[harvest] \(loadedPages) pages -> \(events.count) unique events (\(Int(Date().timeIntervalSince(stageStart)))s)")

    // MARK: Stage 4a: card-date prefilter (details carry exact timestamps)

    if !noPrefilter {
        let wdName = cal.weekdaySymbols[cal.component(.weekday, from: targetDay) - 1]
        var qs: [String: Jev.Question] = [:]
        var idMap: [String: String] = [:]
        for (id, r) in events {
            guard let wt = r.whenText else { continue }
            let qid = "q\(idMap.count)"
            idMap[qid] = id
            qs[qid] = Jev.Question(
                instructions: "Card text: \(wt). The target day is \(wdName) \(dateISO) in Italy. Does the card text state the event happens on the target day?",
                criteria: [
                    "yes": "Stated date(s) include \(dateISO)",
                    "no": "Stated dates exclude the target day",
                    "unknown": "No parseable date statement",
                ])
        }
        do {
            let answers = try Jev.choice(state: "Facebook event card date classification for reachability filtering", questions: qs)
            var dropped = 0
            for (qid, ans) in answers {
                guard let id = idMap[qid] else { continue }
                if ans == "no" {
                    events[id]?.dropReason = "card date mismatch (jev)"
                    dropped += 1
                }
            }
            events = events.filter { $0.value.dropReason != "card date mismatch (jev)" }
            print("[prefilter] jev kept \(events.count) of \(events.count + dropped) cards")
        } catch {
            print("[prefilter] WARNING jev failed, keeping all cards and continuing: \(error)")
        }
    }

    // MARK: Stage 4b: event details

    stageStart = Date()
    let ids = events.keys.sorted { events[$0]!.townsSeenIn.count > events[$1]!.townsSeenIn.count }
    var detailCount = 0
    for id in ids.prefix(maxDetails) {
        guard let rec = events[id] else { continue }
        do {
            try driver.go(rec.url, readyJS: FB.eventReady)
            if let data = try? driver.evalJSON(FB.extractDetail),
               let d = try? JSONDecoder().decode(FB.Detail.self, from: data) {
                var r = rec
                if let t = d.title, t.count > 3 { r.title = t }
                r.start = d.start.map { Geo.localDate($0) }
                r.end = d.end.map { Geo.localDate($0) }
                r.isPast = d.isPast
                r.address = d.address
                r.place = d.place
                r.lat = d.lat
                r.lng = d.lng
                events[id] = r
                detailCount += 1
            }
        } catch {
            print("  [detail] failed \(id): \(error)")
        }
        Thread.sleep(forTimeInterval: 0.4)
    }
    print("[details] \(detailCount)/\(min(ids.count, maxDetails)) pages read (\(Int(Date().timeIntervalSince(stageStart)))s)")

    // MARK: Stage 5: geocode gaps + drive ETAs

    stageStart = Date()
    var asyncDone = false
    var coords: [String: (Double, Double)] = [:]
    for (id, r) in events where r.start != nil {
        if let la = r.lat, let lo = r.lng { coords[id] = (la, lo) }
    }
    let needGeocode = events.filter { $0.value.start != nil && $0.value.lat == nil && ($0.value.address != nil || $0.value.place != nil) }
    if !needGeocode.isEmpty {
        print("[geo] geocoding \(needGeocode.count) events without coordinates...")
        Task {
            for (id, r) in needGeocode {
                if let c = await Geo.geocode(r.address ?? r.place ?? "", near: origin) {
                    events[id]?.lat = c.0
                    events[id]?.lng = c.1
                    coords[id] = c
                }
            }
            asyncDone = true
        }
        while !asyncDone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    let withCoords = events.keys.filter { events[$0]!.start != nil && coords[$0] != nil }
    var etas: [String: (Double, Double)] = [:]
    if !withCoords.isEmpty {
        print("[geo] MKDirections ETAs for \(withCoords.count) venues...")
        asyncDone = false
        Task {
            let batch = await Geo.etaBatch(origin: origin, dests: withCoords.compactMap { coords[$0] })
            for (i, id) in withCoords.enumerated() {
                if let e = batch[i] { etas[id] = e }
            }
            asyncDone = true
        }
        while !asyncDone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    print("[geo] \(etas.count) ETAs (\(Int(Date().timeIntervalSince(stageStart)))s)")

    // MARK: Stage 6: filter + sort

    let dayEnd = targetDay.addingTimeInterval(86_400)
    var kept: [EventRecord] = []
    for (id, rIn) in events {
        var r = rIn
        guard let start = r.start else { r.dropReason = "no start timestamp"; events[id] = r; continue }
        let end = r.end ?? start.addingTimeInterval(TimeInterval(config.defaultDurationMin * 60))
        r.endIsFallback = r.end == nil
        if !(start < dayEnd && end > targetDay) { r.dropReason = "not on \(dateISO)"; events[id] = r; continue }
        if end <= now || r.isPast == true { r.dropReason = "finished"; events[id] = r; continue }
        guard let eta = etas[id] else { r.dropReason = "no ETA"; events[id] = r; continue }
        r.driveSeconds = eta.0
        r.driveMeters = eta.1
        if eta.0 > Double(maxDriveMin * 60) { r.dropReason = "drive \(Int(eta.0 / 60)) min > \(maxDriveMin)"; events[id] = r; continue }
        let arrival = now.addingTimeInterval(eta.0)
        if start > now {
            if arrival > start.addingTimeInterval(TimeInterval(config.graceMin * 60)) {
                r.dropReason = "cannot arrive in time"; events[id] = r; continue
            }
        } else if end.timeIntervalSince(arrival) < TimeInterval(config.minRemainingMin * 60) {
            r.dropReason = "too late into ongoing event"; events[id] = r; continue
        }
        r.keep = true
        r.dropReason = nil
        events[id] = r
        kept.append(r)
    }
    kept.sort {
        let da = $0.driveSeconds ?? .infinity, db = $1.driveSeconds ?? .infinity
        if da != db { return da < db }
        return ($0.start ?? now) < ($1.start ?? now)
    }
    print("[filter] kept \(kept.count), dropped \(events.count - kept.count)")

    // MARK: Stage 7: report

    let timeDF = DateFormatter()
    timeDF.timeZone = Geo.rome
    timeDF.dateFormat = "HH:mm"
    let runInfo: [String: String] = [
        "date": dateISO,
        "origin": config.originLabel,
        "maxDrive": "\(maxDriveMin) min by car",
        "towns": "\(searchable.count) searched",
        "events": "\(events.count) seen, \(kept.count) reachable",
        "generated": timeDF.string(from: now),
    ]
    let fullEnc = JSONEncoder()
    fullEnc.dateEncodingStrategy = .iso8601
    fullEnc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let full = try? fullEnc.encode(events.values.sorted { ($0.driveSeconds ?? .infinity) < ($1.driveSeconds ?? .infinity) }) {
        try? full.write(to: outDir.appendingPathComponent("report-full.json"), options: .atomic)
    }
    try Report.write(records: kept, runInfo: runInfo, outDir: outDir)
    print("[report] \(outDir.path)/report.html")
    print()
    print(Report.consoleSummary(records: kept))
}

setbuf(stdout, nil)

do {
    try run()
} catch {
    print("fbnear failed: \(error)")
    exit(1)
}
