import Foundation

/// Facebook events URL grammar, card harvesting and event detail extraction.
enum FB {
    static func searchURL(townCode: String, dateISO: String?, categoryCode: String?, query: String) -> String {
        var filters: [String: String] = [:]
        filters["rp_events_location:0"] = "{\"name\":\"filter_events_location\",\"args\":\"\(townCode)\"}"
        if let d = dateISO {
            filters["filter_events_date_range:0"] = "{\"name\":\"filter_events_date\",\"args\":\"\(d)\"}"
        }
        if let c = categoryCode {
            filters["filter_events_category:0"] = "{\"name\":\"filter_events_category\",\"args\":\"\(c)\"}"
        }
        let json = String(data: try! JSONSerialization.data(withJSONObject: filters), encoding: .utf8)!
        let compact = compactJSON(json)
        let b64 = Data(compact.utf8).base64EncodedString()
        return "https://www.facebook.com/events/search/?q=\(query)&filters=\(b64)"
    }

    /// JSONSerialization output already compact; kept explicit for safety.
    private static func compactJSON(_ s: String) -> String {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return s }
        return String(data: out, encoding: .utf8) ?? s
    }

    static let searchReady = "location.href.indexOf('/events/search')>=0 && !!document.querySelector('input[aria-label=\"Location\"]') ? '1':'0'"
    static let dashboardReady = "location.href.indexOf('/events')>=0 && document.readyState==='complete' && document.documentElement.innerHTML.length>100000 ? '1':'0'"
    static let eventReady = "location.href.indexOf('/events/')>=0 && document.readyState==='complete' && document.documentElement.innerHTML.length>120000 ? '1':'0'"

    /// Extracts event cards from the current search/dashboard page.
    /// Returns [{id, text}] where text carries title/date/place from the card container.
    static let extractCards = """
    (function(){
      var seen={}, out=[];
      document.querySelectorAll('a[href*="/events/"]').forEach(function(a){
        var m=a.href.match(/\\/events\\/(\\d{6,})/);
        if(!m||seen[m[1]]) return;
        var par=a;
        for(var i=0;i<7&&par.parentElement;i++){ par=par.parentElement; var t=(par.innerText||'').replace(/\\s+/g,' ').trim(); if(t.length>90){ seen[m[1]]=1; out.push({id:m[1], text:t.slice(0,200)}); return; } }
        var t2=(a.innerText||'').replace(/\\s+/g,' ').trim();
        if(t2.length>8){ seen[m[1]]=1; out.push({id:m[1], text:t2.slice(0,200)}); }
      });
      return encodeURIComponent(JSON.stringify(out));
    })()
    """

    /// Extracts the primary event's exact data from the event page preload JSON.
    static let extractDetail = """
    (function(){
      var html=document.documentElement.innerHTML, out={};
      out.title=document.title.replace(/ \\| Facebook$/,'');
      var re=/"event_place":\\{/g, mm;
      while((mm=re.exec(html))!==null){
        var seg=html.slice(mm.index,mm.index+900);
        var la=seg.match(/"latitude":(-?\\d+\\.\\d+)/);
        if(la){
          out.lat=parseFloat(la[1]);
          var lo=seg.match(/"longitude":(-?\\d+\\.\\d+)/);
          if(lo) out.lng=parseFloat(lo[1]);
          var cn=seg.match(/"contextual_name":"((?:[^"\\\\]|\\\\.)*)"/);
          if(cn){ try{ out.address=JSON.parse('"'+cn[1]+'"'); }catch(e){} }
          var nm=seg.match(/,"name":"((?:[^"\\\\]|\\\\.)*)"/);
          if(nm){ try{ out.place=JSON.parse('"'+nm[1]+'"'); }catch(e){} }
          var pre=html.slice(Math.max(0,mm.index-4000),mm.index);
          var st=[...pre.matchAll(/"start_timestamp":(\\d{9,})/g)];
          if(st.length) out.start=parseInt(st[st.length-1][1]);
          break;
        }
      }
      if(!out.start){ var s2=html.match(/"start_timestamp":(\\d{9,})/); if(s2) out.start=parseInt(s2[1]); }
      var en=html.match(/"end_timestamp":(\\d{9,})/); if(en) out.end=parseInt(en[1]);
      var ip=html.match(/"is_past":(true|false)/); if(ip) out.isPast=(ip[1]==='true');
      return encodeURIComponent(JSON.stringify(out));
    })()
    """

    struct Card: Codable {
        let id: String
        let text: String
    }

    /// Fetch-mode: same-origin fetch of a search URL, parse SSR HTML with
    /// DOMParser, reuse the card extraction logic offline. No navigation.
    static func fetchCardsJS(_ url: String) -> String {
        """
        (function(){
          window.__fetchCards='pending';
          fetch('\(url)',{credentials:'include'}).then(function(r){return r.text();}).then(function(t){
            if(t.indexOf('Temporarily Blocked')>=0){window.__fetchCards=encodeURIComponent(JSON.stringify({blocked:true}));return;}
            var doc=new DOMParser().parseFromString(t,'text/html');
            var seen={}, out=[];
            doc.querySelectorAll('a[href*="/events/"]').forEach(function(a){
              var m=(a.getAttribute('href')||'').match(/\\/events\\/(\\d{6,})/);
              if(!m||seen[m[1]]) return;
              seen[m[1]]=1;
              var txt=(a.textContent||'').replace(/\\s+/g,' ').trim();
              out.push({id:m[1], text:txt.slice(0,200)});
            });
            window.__fetchCards=encodeURIComponent(JSON.stringify({blocked:false, cards:out.slice(0,40)}));
          }).catch(function(e){window.__fetchCards=encodeURIComponent(JSON.stringify({error:e.message}));});
          return 'fired';
        })()
        """
    }

    /// Fetch-mode detail: fetch event page, regex preloads from SSR HTML.
    static func fetchDetailJS(_ eventURL: String) -> String {
        """
        (function(){
          window.__fetchDetail='pending';
          fetch('\(eventURL)',{credentials:'include'}).then(function(r){return r.text();}).then(function(t){
            var out={};
            if(t.indexOf('Temporarily Blocked')>=0){out.blocked=true;window.__fetchDetail=encodeURIComponent(JSON.stringify(out));return;}
            var tm=t.match(/<title[^>]*>([^<]*)<\\/title>/); if(tm){out.title=tm[1].replace(/ \\| Facebook$/,'');}
            var re=/"event_place":\\{/g, mm;
            while((mm=re.exec(t))!==null){
              var seg=t.slice(mm.index,mm.index+900);
              var la=seg.match(/"latitude":(-?\\d+\\.\\d+)/);
              if(la){
                out.lat=parseFloat(la[1]);
                var lo=seg.match(/"longitude":(-?\\d+\\.\\d+)/); if(lo) out.lng=parseFloat(lo[1]);
                var cn=seg.match(/"contextual_name":"((?:[^"\\\\]|\\\\.)*)"/);
                if(cn){try{out.address=JSON.parse('"'+cn[1]+'"');}catch(e){}}
                var pre=t.slice(Math.max(0,mm.index-4000),mm.index);
                var st=[...pre.matchAll(/"start_timestamp":(\\d{9,})/g)];
                if(st.length) out.start=parseInt(st[st.length-1][1]);
                break;
              }
            }
            if(!out.start){var s2=t.match(/"start_timestamp":(\\d{9,})/); if(s2) out.start=parseInt(s2[1]);}
            var en=t.match(/"end_timestamp":(\\d{9,})/); if(en) out.end=parseInt(en[1]);
            var ip=t.match(/"is_past":(true|false)/); if(ip) out.isPast=(ip[1]==='true');
            window.__fetchDetail=encodeURIComponent(JSON.stringify(out));
          }).catch(function(e){window.__fetchDetail=encodeURIComponent(JSON.stringify({error:e.message}));});
          return 'fired';
        })()
        """
    }

    struct FetchCards: Codable {
        var blocked: Bool?
        var error: String?
        var cards: [Card]?
    }

    struct Row: Codable {
        let code: String
        let text: String
    }

    struct Detail: Codable {
        var title: String?
        var lat: Double?
        var lng: Double?
        var address: String?
        var place: String?
        var start: Int?
        var end: Int?
        var isPast: Bool?
    }
}
