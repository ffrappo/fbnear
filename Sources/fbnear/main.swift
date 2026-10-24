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

let args = Array(CommandLine.arguments.dropFirst())
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

struct WebDay: Codable {
    var dateISO: String
    var towns: Int
    var driveBudget: String
    var generatedAt: String
    var events: [WebEvent]
}
struct WebEvent: Codable {
    var title: String
    var url: String
    var start: Date?
    var end: Date?
    var driveSeconds: Double?
    var driveMeters: Double?
    var venue: String?
    var ongoing: Bool
}
struct WebData: Codable {
    var defaultDay: String
    var days: [String: WebDay]
}

@MainActor
func publishWeb(kept: [EventRecord], dateISO: String, towns: Int, maxDriveMin: Int, generatedAt: String) throws {
    let repoDir = URL(fileURLWithPath: fm.homeDirectoryForCurrentUser.path + "/works/repos/fbnear")
    let dataURL = repoDir.appendingPathComponent("web/data.json")
    var web: WebData
    if let old = try? Data(contentsOf: dataURL),
       let parsed = try? JSONDecoder().decode(WebData.self, from: old) {
        web = parsed
    } else {
        web = WebData(defaultDay: "today", days: [:])
    }
    let cal2 = cal
    let events = kept.map { r in
        WebEvent(title: r.title, url: r.url, start: r.start, end: r.end,
                 driveSeconds: r.driveSeconds, driveMeters: r.driveMeters,
                 venue: r.place ?? r.address,
                 ongoing: { if let s = r.start { return s <= now && (r.end ?? s) > now }; return false }())
    }
    web.days[dateISO] = WebDay(dateISO: dateISO, towns: towns,
                               driveBudget: "\(maxDriveMin)", generatedAt: generatedAt,
                               events: events)
    // keep the 7 most recent days
    let sortedDays = web.days.keys.sorted()
    if sortedDays.count > 7 {
        for k in sortedDays.prefix(sortedDays.count - 7) { web.days[k] = nil }
    }
    let todayKey = dayDF.string(from: Date())
    web.defaultDay = web.days[todayKey] != nil ? todayKey : (sortedDays.last ?? dateISO)
    let enc2 = JSONEncoder()
    enc2.dateEncodingStrategy = .iso8601
    enc2.outputFormatting = [.sortedKeys]
    try enc2.encode(web).write(to: dataURL, options: .atomic)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "cd \(repoDir.path) && git add web/data.json && git commit -q -m 'data \(dateISO)' && git push -q origin main && git subtree split --prefix=web -b gh-pages-tmp >/dev/null 2>&1 && git push -q origin gh-pages-tmp:gh-pages && git branch -q -D gh-pages-tmp"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    print("[publish] web/data.json updated and pushed")
}

@MainActor
func run() throws {
    let config = loadConfig()
    let maxDriveMin = Int(argValue("--max-drive") ?? "") ?? 45
    let radiusKm = Double(argValue("--radius") ?? "") ?? 30
    let rings = argValue("--rings").map { $0.split(separator: ",").compactMap { Double($0) } } ?? [5, 10, 15, 20, 30]
    let maxDetails = Int(argValue("--max-details") ?? "") ?? 200
    let fbDateFilter = hasFlag("--fb-date-filter")
    let noPrefilter = hasFlag("--no-prefilter")
    let queriesOuter = (argValue("--query") ?? "events").split(separator: ",").map(String.init)
    let queriesInner = (argValue("--queries-inner") ?? "events,concert,festa,sagra").split(separator: ",").map(String.init)
    let innerKm = Double(argValue("--inner-km") ?? "") ?? 12
    let refreshTowns = hasFlag("--refresh-towns")
    let keepTab = hasFlag("--keep-tab")
    let tabs = max(1, Int(argValue("--tabs") ?? "") ?? 2)
    let dashboard = hasFlag("--dashboard")
    let noFetch = hasFlag("--no-fetch")
    let publish = hasFlag("--publish")
    let noSearch = hasFlag("--no-search")
    let discover = hasFlag("--no-discover") ? false : true
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
        towns = cache.towns.filter { $0.km <= radiusKm + 0.01 }
        print("[towns] cached \(towns.count) municipalities within \(Int(radiusKm)) km (cache radius \(Int(cache.radiusKm)) km)")
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

    let drivers = (0..<tabs).map { SafariDriver(worker: $0) }
    let driver = drivers[0]
    defer {
        for d in drivers {
            if !keepTab { d.closeOurTab() }
            d.cleanup()
        }
    }

    // MARK: Stage 2: resolve FB town codes

    let weekAgo = now.addingTimeInterval(-7 * 86_400)
    let missing = gatedTowns.filter { $0.fbCode == nil && ($0.unresolvedAt == nil || $0.unresolvedAt! < weekAgo) }
    let skipped = gatedTowns.filter { $0.fbCode == nil && !missing.contains($0) }.count
    if skipped > 0 { print("[codes] skipping \(skipped) unresolved towns (7-day TTL)") }
    if !missing.isEmpty {
        print("[codes] resolving \(missing.count) town codes...")
        _ = try? driver.go("https://www.facebook.com/events/", readyJS: FB.dashboardReady, timeout: 40)
        Thread.sleep(forTimeInterval: 1.5)
        var resolved = 0
        for var t in missing {
            var result: (code: String, canonical: String)? = try? Towns.resolveCodeGraphQL(driver: driver, name: t.name)
            if result == nil && !noSearch {
                _ = try? driver.go("https://www.facebook.com/events/search/?q=x", readyJS: FB.searchReady, timeout: 30)
                result = try? Towns.resolveCode(driver: driver, name: t.name)
                _ = try? driver.go("https://www.facebook.com/events/", readyJS: FB.dashboardReady, timeout: 40)
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
                t.unresolvedAt = Date()
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

    // MARK: Stage 3: harvest cards per town (parallel worker tabs)

    var events: [String: EventRecord] = [:]
    let eventsBox = LockedBox(events)
    var stageStart = Date()
    var loadedPages = 0
    struct HarvestJob { let townIdx: Int; let code: String; let name: String; let km: Double; let query: String; let isDiscover: Bool; let tab: String }
    var jobsBuild: [HarvestJob] = []
    if !noSearch {
        for (i, town) in searchable.enumerated() {
            let qs = town.km <= innerKm ? queriesInner : queriesOuter
            for q in qs { jobsBuild.append(HarvestJob(townIdx: i, code: town.fbCode!, name: town.name, km: town.km, query: q, isDiscover: false, tab: "")) }
        }
    }
    if discover {
        for (i, town) in searchable.enumerated() {
            let tabs = town.km <= innerKm ? ["RECOMMENDED", "LOCAL"] : ["RECOMMENDED"]
            for tb in tabs { jobsBuild.append(HarvestJob(townIdx: i, code: town.fbCode!, name: town.name + " [" + tb + "]", km: town.km, query: "", isDiscover: true, tab: tb)) }
        }
    }
    if dashboard { jobsBuild.insert(HarvestJob(townIdx: -1, code: "", name: "Dashboard (nearby)", km: 0, query: "", isDiscover: false, tab: ""), at: 0) }
    let jobs = jobsBuild

    func storeCards(_ cards: [FB.Card], _ townName: String) -> Int {
        var fresh = 0
        eventsBox.with { ev in
            for c in cards {
                if ev[c.id] == nil {
                    ev[c.id] = EventRecord(
                        id: c.id, url: "https://www.facebook.com/events/\(c.id)/",
                        title: c.text, start: nil, end: nil, endIsFallback: false,
                        isPast: nil, address: nil, place: nil, lat: nil, lng: nil,
                        driveSeconds: nil, driveMeters: nil,
                        townsSeenIn: [townName], whenText: c.text, keep: false)
                    fresh += 1
                } else if !(ev[c.id]!.townsSeenIn.contains(townName)) {
                    ev[c.id]!.townsSeenIn.append(townName)
                }
            }
        }
        return fresh
    }

    func fetchCards(_ url: String, _ d: SafariDriver) throws -> FB.FetchCards? {
        _ = try d.eval(FB.fetchCardsJS(url))
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            let raw = (try? d.eval("window.__fetchCards||'pending'")) ?? "pending"
            if raw == "pending" { continue }
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(FB.FetchCards.self, from: data)
        }
        return nil
    }

    func harvestPage(_ job: HarvestJob, _ d: SafariDriver) {
        let url: String
        if job.townIdx < 0 {
            url = "https://www.facebook.com/events/"
        } else if job.isDiscover {
            url = "https://www.facebook.com/events/?discover_tab=\(job.tab)&location_id=\(job.code)"
        } else {
            url = FB.searchURL(townCode: job.code, dateISO: fbDateFilter ? dateISO : nil, categoryCode: categories.first, query: job.query)
        }
        if job.isDiscover && blockedBox.with({ $0 }) { return }
        _ = noFetch // discover always navigates: its SSR carries no links
        // Fetch mode: no navigation, no render (dashboard/discover jobs always navigate)
        if !noFetch && job.townIdx >= 0 && !job.isDiscover {
            if let fc = try? fetchCards(url, d) {
                if fc.blocked == true {
                    print("  [harvest] BLOCKED by Facebook rate limit; stopping all workers")
                    blockedBox.with { $0 = true }
                    return
                }
                if let cards = fc.cards, !cards.isEmpty {
                    let fresh = storeCards(cards, job.name)
                    print("  [\(String(format: "%4.1f", job.km)) km] \(job.name.padding(toLength: 30, withPad: " ", startingAt: 0)) +\(fresh) (fetch)")
                    return
                }
                print("  [harvest] fetch empty for \(job.name); falling back to navigation")
            }
        }
        do {
            let ready = (job.townIdx < 0 || job.isDiscover) ? FB.dashboardReady : FB.searchReady
            try d.go(url, readyJS: ready)
        } catch FbnearError.blocked {
            print("  [harvest] BLOCKED by Facebook rate limit; stopping all workers")
            blockedBox.with { $0 = true }
            return
        } catch {
            print("  [harvest] page failed \(job.name): \(error)")
            return
        }
        if let data = try? d.evalJSON(FB.extractCards),
           let cards = try? JSONDecoder().decode([FB.Card].self, from: data) {
            let fresh = storeCards(cards, job.name)
            print("  [\(String(format: "%4.1f", job.km)) km] \(job.name.padding(toLength: 30, withPad: " ", startingAt: 0)) +\(fresh)")
        }
    }

    let counter = LockedBox(0)
    let pagesBox = LockedBox(0)
    let blockedBox = LockedBox(false)
    let runningH = LockedBox(drivers.count)
    for w in 0..<drivers.count {
        let th = Thread {
            defer { runningH.with { $0 -= 1 } }
            while true {
                let i = counter.with { c -> Int in
                    if c < jobs.count { c += 1; return c - 1 }
                    return -1
                }
                if i < 0 { return }
                let job = jobs[i]
                if blockedBox.with({ $0 }) && !job.isDiscover && job.townIdx >= 0 { continue }
                harvestPage(job, drivers[w])
                pagesBox.with { $0 += 1 }
                Thread.sleep(forTimeInterval: 1.0 + Double.random(in: 0...1.5))
            }
        }
        th.name = "fbnear-w\(w)"
        th.start()
    }
    while runningH.with({ $0 }) > 0 { Thread.sleep(forTimeInterval: 0.05) }
    loadedPages = pagesBox.with { $0 }
    events = eventsBox.with { $0 }
    print("[harvest] \(loadedPages) pages on \(drivers.count) tabs -> \(events.count) unique events (\(Int(Date().timeIntervalSince(stageStart)))s)")

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
            print("[prefilter] jev kept \(events.count - dropped) of \(events.count) cards")
        } catch {
            print("[prefilter] WARNING jev failed, keeping all cards and continuing: \(error)")
        }
    }

    // MARK: Stage 4b: event details (parallel worker tabs, 12h detail cache)

    stageStart = Date()
    let detailsCacheURL = configDir.appendingPathComponent("details.json")
    struct DetailCacheEntry: Codable { var detail: FB.Detail; var fetchedAt: Date }
    var detailCache: [String: DetailCacheEntry] = [:]
    if let data = try? Data(contentsOf: detailsCacheURL) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let c = try? dec.decode([String: DetailCacheEntry].self, from: data) {
            detailCache = c
        }
    }
    let cacheCutoff = now.addingTimeInterval(-12 * 3600)
    for (id, r) in events where r.start == nil {
        if let e = detailCache[id], e.fetchedAt > cacheCutoff {
            let d = e.detail
            events[id]?.start = d.start.map { Geo.localDate($0) }
            events[id]?.end = d.end.map { Geo.localDate($0) }
            events[id]?.isPast = d.isPast
            events[id]?.address = d.address
            events[id]?.place = d.place
            events[id]?.lat = d.lat
            events[id]?.lng = d.lng
            if let tt = d.title, tt.count > 3 { events[id]?.title = tt }
        }
    }
    let cachedCount = events.values.filter { $0.start != nil }.count
    print("[details] cache hit for \(cachedCount) events")
    let detailIds = Array(events.keys.filter { events[$0]!.dropReason == nil }
        .sorted { events[$0]!.townsSeenIn.count > events[$1]!.townsSeenIn.count }.prefix(maxDetails))
    let detailCounter = LockedBox(0)
    let detailDone = LockedBox(0)
    let cacheBox = LockedBox(detailCache)
    let runningD = LockedBox(drivers.count)
    for w in 0..<drivers.count {
        let th = Thread {
            defer { runningD.with { $0 -= 1 } }
            while true {
                let i = detailCounter.with { c -> Int in
                    if c < detailIds.count { c += 1; return c - 1 }
                    return -1
                }
                if i < 0 { return }
                let id = detailIds[i]
                if eventsBox.with({ ev in ev[id]?.start != nil }) { detailDone.with { $0 += 1 }; continue }
                let url = "https://www.facebook.com/events/\(id)/"
                if blockedBox.with({ $0 }) { return }
                var fetched: FB.Detail? = nil
                var viaHTTP = false
                if let h = try? DetailHTTP.fetch(eventID: id), h.start != nil {
                    var d = FB.Detail()
                    d.title = h.title
                    d.start = h.start
                    d.end = h.end
                    d.lat = h.lat
                    d.lng = h.lng
                    d.address = h.address
                    d.isPast = h.isPast
                    fetched = d
                    viaHTTP = true
                    Thread.sleep(forTimeInterval: 0.5 + Double.random(in: 0...0.7))
                }
                if fetched == nil && !noFetch {
                    _ = try? drivers[w].eval(FB.fetchDetailJS(url))
                    let deadline = Date().addingTimeInterval(12)
                    while Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.4)
                        let raw = (try? drivers[w].eval("window.__fetchDetail||'pending'")) ?? "pending"
                        if raw == "pending" { continue }
                        if let data = raw.data(using: .utf8) {
                            fetched = try? JSONDecoder().decode(FB.Detail.self, from: data)
                        }
                        break
                    }
                }
                if let d = fetched, d.start != nil {
                    _ = viaHTTP
                    eventsBox.with { ev in
                        guard var r = ev[id] else { return }
                        if let tt = d.title, tt.count > 3 { r.title = tt }
                        r.start = d.start.map { Geo.localDate($0) }
                        r.end = d.end.map { Geo.localDate($0) }
                        r.isPast = d.isPast
                        r.address = d.address
                        r.place = d.place
                        r.lat = d.lat
                        r.lng = d.lng
                        ev[id] = r
                    }
                    cacheBox.with { $0[id] = DetailCacheEntry(detail: d, fetchedAt: Date()) }
                    detailDone.with { $0 += 1 }
                    Thread.sleep(forTimeInterval: 0.6 + Double.random(in: 0...0.9))
                    continue
                }
                do {
                    try drivers[w].go(url, readyJS: FB.eventReady)
                    if let data = try? drivers[w].evalJSON(FB.extractDetail),
                       let d = try? JSONDecoder().decode(FB.Detail.self, from: data) {
                        eventsBox.with { ev in
                            guard var r = ev[id] else { return }
                            if let tt = d.title, tt.count > 3 { r.title = tt }
                            r.start = d.start.map { Geo.localDate($0) }
                            r.end = d.end.map { Geo.localDate($0) }
                            r.isPast = d.isPast
                            r.address = d.address
                            r.place = d.place
                            r.lat = d.lat
                            r.lng = d.lng
                            ev[id] = r
                        }
                        cacheBox.with { $0[id] = DetailCacheEntry(detail: d, fetchedAt: Date()) }
                        detailDone.with { $0 += 1 }
                    }
                } catch FbnearError.blocked {
                    print("  [detail] BLOCKED by Facebook rate limit; stopping all workers")
                    blockedBox.with { $0 = true }
                } catch {
                    print("  [detail] failed \(id): \(error)")
                }
                Thread.sleep(forTimeInterval: 0.6 + Double.random(in: 0...0.9))
            }
        }
        th.name = "fbnear-d\(w)"
        th.start()
    }
    while runningD.with({ $0 }) > 0 { Thread.sleep(forTimeInterval: 0.05) }
    events = eventsBox.with { $0 }
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    detailCache = cacheBox.with { $0 }
    if let data = try? enc.encode(detailCache) {
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? data.write(to: detailsCacheURL, options: .atomic)
    }
    print("[details] \(detailDone.with { $0 })/\(detailIds.count) pages read (\(Int(Date().timeIntervalSince(stageStart)))s)")

    // MARK: Stage 5: geocode gaps + drive ETAs

    stageStart = Date()
    var asyncDone = false
    var coords: [String: (Double, Double)] = [:]
    for (id, r) in events where r.start != nil {
        if let la = r.lat, let lo = r.lng { coords[id] = (la, lo) }
    }
    let needGeocode = events.filter { $0.value.start != nil && $0.value.lat == nil }
    if !needGeocode.isEmpty {
        print("[geo] geocoding \(needGeocode.count) events without coordinates...")
        Task {
            for (id, r) in needGeocode {
                var q = r.address ?? r.place ?? ""
                let decTitle = r.title
                    .replacingOccurrences(of: "&#064;", with: "@")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#039;", with: "'")
                if q.isEmpty, let at = decTitle.range(of: "@") {
                    let venue = decTitle[at.upperBound...].prefix(70)
                        .replacingOccurrences(of: "Dal ", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let town = r.townsSeenIn.first { $0 != "Dashboard (nearby)" && !$0.contains("[") } ?? "Verona"
                    if venue.count > 2 { q = "\(venue), \(town)" }
                }
                if !q.isEmpty, let c = await Geo.geocode(q, near: origin) {
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
    var fixedEvents: [String: EventRecord] = [:]
    for (id, r) in events {
        var rr = r
        rr.title = rr.title
            .replacingOccurrences(of: "&#064;", with: "@")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
        fixedEvents[id] = rr
    }
    events = fixedEvents
    kept = kept.map { r in
        var rr = r
        rr.title = rr.title
            .replacingOccurrences(of: "&#064;", with: "@")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#039;", with: "'")
        return rr
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
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
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

    let harvestOK = loadedPages > 0 && !blockedBox.with({ $0 })
    if publish && harvestOK {
        try publishWeb(kept: kept, dateISO: dateISO, towns: searchable.count,
                       maxDriveMin: maxDriveMin, generatedAt: timeDF.string(from: now))
    } else if publish {
        print("[publish] skipped: harvest did not complete (blocked or empty); keeping last good data")
    }
}

setbuf(stdout, nil)

if let probe = argValue("--probe-detail") {
    for id in probe.split(separator: ",").map(String.init) {
        do {
            let r = try DetailHTTP.fetch(eventID: id)
            print(id, "| start", r.start ?? -1, "| end", r.end ?? -1, "| lat", r.lat ?? -1, "| past", r.isPast ?? false, "|", (r.title ?? "").prefix(45), "|", (r.address ?? "").prefix(40))
        } catch { print(id, "ERROR", error) }
        Thread.sleep(forTimeInterval: 1.0)
    }
    exit(0)
}

do {
    try run()
} catch {
    print("fbnear failed: \(error)")
    exit(1)
}
