import Foundation

/// Municipalities around the origin in concentric rings (OSM Overpass),
/// each resolved once to a Facebook town code via the search typeahead.
struct Town: Codable, Equatable {
    var name: String
    var lat: Double
    var lng: Double
    var km: Double
    var ring: Int
    var fbCode: String?
    var fbName: String?
    var unresolvedReason: String?
}

struct TownsCache: Codable {
    var originLat: Double
    var originLng: Double
    var radiusKm: Double
    var updatedAt: Date
    var towns: [Town]
}

enum Towns {
    static func haversineKm(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6371.0
        let dLat = (b.0 - a.0) * .pi / 180
        let dLon = (b.1 - a.1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.0 * .pi / 180) * cos(b.0 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(sqrt(h))
    }

    static func fetchOverpass(origin: (Double, Double), radiusKm: Double) throws -> [(name: String, lat: Double, lng: Double)] {
        let q = "[out:json][timeout:30];(relation[\"boundary\"=\"administrative\"][\"admin_level\"=\"8\"](around:\(Int(radiusKm * 1000)),\(origin.0),\(origin.1)););out center tags;"
        var req = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        req.httpMethod = "POST"
        req.setValue("fbnear/1.0 (macOS; personal tool)", forHTTPHeaderField: "User-Agent")
        req.httpBody = "data=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)".data(using: .utf8)
        let sem = DispatchSemaphore(value: 0)
        var payload: Data?
        var errText: String?
        let task = URLSession.shared.dataTask(with: req) { d, resp, e in
            if let e = e { errText = e.localizedDescription }
            else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                errText = "overpass HTTP \(http.statusCode)"
            } else { payload = d }
            sem.signal()
        }
        task.resume()
        guard sem.wait(timeout: .now() + 60) == .success, let data = payload else {
            throw FbnearError.safariScript("towns: \(errText ?? "overpass timeout")")
        }
        struct OP: Codable {
            struct El: Codable {
                struct C: Codable { var lat: Double; var lon: Double }
                struct T: Codable { var name: String? }
                var center: C?
                var tags: T?
            }
            var elements: [El]?
        }
        let op = try JSONDecoder().decode(OP.self, from: data)
        var out: [(String, Double, Double)] = []
        for el in op.elements ?? [] {
            if let n = el.tags?.name, let c = el.center {
                out.append((n, c.lat, c.lon))
            }
        }
        return out
    }

    static func bucket(_ raw: [(name: String, lat: Double, lng: Double)],
                       origin: (Double, Double), rings: [Double]) -> [Town] {
        raw.compactMap { r in
            let km = haversineKm(origin, (r.lat, r.lng))
            guard km <= (rings.last ?? 0) + 0.01 else { return nil }
            var ring = 0
            for (i, edge) in rings.enumerated() where km <= edge { ring = i; break }
            return Town(name: r.name, lat: r.lat, lng: r.lng, km: (km * 10).rounded() / 10, ring: ring, fbCode: nil)
        }
        .sorted { $0.km < $1.km }
    }

    // MARK: typeahead resolution

    /// Resolves one town name to a Facebook location code.
    /// Primary: suggestion rows expose the entity code in aria-describedby.
    /// Fallback: scored click (Italy/Veneto/exact preferred), then URL readback.
    static func resolveCode(driver: SafariDriver, name: String) throws -> (code: String, canonical: String)? {
        _ = try driver.eval(clearChipJS)
        Thread.sleep(forTimeInterval: 1.2)
        guard try driver.eval(typeJS(name)) == "typed" else { return nil }

        let scan = """
        (function(){
          function norm(s){return (s||'').normalize('NFD').replace(/[\\u0300-\\u036f]/g,'').toLowerCase().replace(/\\s+/g,' ').trim();}
          var target=norm(\(jsArg(name)));
          var toks=target.split(' ').filter(function(w){return w.length>3;});
          var seen={}, rows=[];
          document.querySelectorAll('[aria-describedby]').forEach(function(e){
            var d=e.getAttribute('aria-describedby');
            if(!/^\\d{10,17}$/.test(d) || seen[d]) return;
            var t=norm(e.innerText);
            if(!t||t.length>90) return;
            var main=t.split(',')[0].trim();
            var related = (main===target) || (main.indexOf(target)===0) || (t.indexOf(target)===0) ||
              toks.filter(function(w){return main.indexOf(w)===0 || (' '+main+' ').indexOf(' '+w+' ')>=0;}).length>0;
            if(!related) return;
            seen[d]=1;
            rows.push({code:d, text:t});
          });
          return encodeURIComponent(JSON.stringify(rows.slice(0,14)));
        })()
        """
        let dbg = ProcessInfo.processInfo.environment["FBNEAR_DEBUG"] != nil
        var candidates: [(code: String, text: String)] = []
        for i in 0..<3 {
            Thread.sleep(forTimeInterval: 1.6)
            let raw = (try? driver.eval(scan)) ?? "<eval-failed>"
            if dbg { print("      [dbg] poll \(i) raw=\(raw.prefix(160))") }
            if let dec = raw.removingPercentEncoding,
               let data = dec.data(using: .utf8),
               let rows = try? JSONDecoder().decode([FB.Row].self, from: data), !rows.isEmpty {
                candidates = rows.map { ($0.code, $0.text) }
                break
            }
        }
        if dbg { print("      [dbg] candidates=\(candidates.map { $0.text })") }
        guard !candidates.isEmpty else { return nil }

        // Jev picks the row that is the intended municipality (or none of them).
        var qs: [String: Jev.Question] = [:]
        qs["pick"] = Jev.Question(
            instructions: "Intended municipality: \(name), in the province of Verona, Veneto, Italy. Which Facebook location suggestion below is this exact same municipality? Suggestion text may omit suffixes, but a same-name municipality in a different Italian province is a different place (for example the large Rivoli in Piemonte is not Rivoli Veronese): for those choose none.",
            criteria: {
                var c: [String: String] = ["none": "None of the suggestions is the intended municipality"]
                for (i, cand) in candidates.enumerated() {
                    c["r\(i)"] = "Suggestion: \(cand.text)"
                }
                return c
            }())
        do {
            let answers = try Jev.choice(
                state: "Facebook events location typeahead matching for province of Verona, Italy",
                questions: qs)
            if dbg { print("      [dbg] jev pick=\(answers["pick"] ?? "nil")") }
            guard let pick = answers["pick"], pick != "none", let idx = Int(pick.dropFirst()) else { return nil }
            guard idx < candidates.count else { return nil }
            return (candidates[idx].code, candidates[idx].text)
        } catch {
            if dbg { print("      [dbg] jev error: \(error)") }
            throw error
        }

        // Fallback: scored click + URL readback
        var clicked = false
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 1.6)
            if (try? driver.eval(clickJS(name))) ?? "" == "clicked" { clicked = true; break }
        }
        guard clicked else { return nil }
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 1.6)
            guard let raw = try? driver.eval(readJS), !raw.isEmpty,
                  let data = raw.removingPercentEncoding?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let filtersStr = obj["filters"] as? String,
                  let filters = try? JSONSerialization.jsonObject(with: Data(filtersStr.utf8)) as? [String: String],
                  let loc = filters["rp_events_location:0"],
                  let locObj = try? JSONSerialization.jsonObject(with: Data(loc.utf8)) as? [String: String],
                  let code = locObj["args"] else { continue }
            var canonical = name
            if let chip = obj["chip"] as? String {
                canonical = chip.replacingOccurrences(of: "Clear filter Location: ", with: "")
            }
            return (code, canonical)
        }
        return nil
    }

    private static let clearChipJS = """
    (function(){
      var c=document.querySelector('[aria-label^="Clear filter Location"]');
      if(c){['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(ev){c.dispatchEvent(new MouseEvent(ev,{bubbles:true,cancelable:true,view:window}));});}
      return 'clear-'+(c?'yes':'no');
    })()
    """

    private static func typeJS(_ name: String) -> String {
        """
        (function(){
          var inp=document.querySelector('input[aria-label="Location"]');
          if(!inp) return 'no-input';
          inp.focus();
          var setter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
          setter.call(inp, \(jsArg(name)));
          inp.dispatchEvent(new Event('input',{bubbles:true}));
          return 'typed';
        })()
        """
    }

    private static func clickJS(_ name: String) -> String {
        """
        (function(){
          function norm(s){return (s||'').normalize('NFD').replace(/[\\u0300-\\u036f]/g,'').toLowerCase().replace(/\\s+/g,' ').trim();}
          var target=norm(\(jsArg(name)));
          var els=Array.from(document.querySelectorAll('span,div,a')).filter(function(e){
            var t=norm(e.innerText);
            if(!t||t.length>70||e.children.length>3) return false;
            return t===target || t.indexOf(target+',')===0 || t.indexOf(target+' (')===0 || t.indexOf(target+' -')===0;
          });
          if(!els.length) return 'no-suggestion';
          var el=els[els.length-1];
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(ev){el.dispatchEvent(new MouseEvent(ev,{bubbles:true,cancelable:true,view:window}));});
          return 'clicked';
        })()
        """
    }

    private static let readJS = """
    (function(){
      var f=new URLSearchParams(location.search).get('filters');
      if(!f) return '';
      var chip=document.querySelector('[aria-label^="Clear filter Location"]');
      return encodeURIComponent(JSON.stringify({filters:atob(f), chip:chip?chip.getAttribute('aria-label'):null}));
    })()
    """

    static func jsArg(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "'\(esc)'"
    }
}
