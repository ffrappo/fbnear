# fbnear

Lists Facebook events happening on a date (default today, not finished) that
are reachable by car within a drive-time budget from home, harvested from all
neighboring towns in concentric rings around San Pietro in Cariano.

    fbnear [--date today|tomorrow|YYYY-MM-DD] [--max-drive 45] [--radius 30]
          [--rings 5,10,15,20,30] [--query events] [--max-details 200]
          [--no-prefilter] [--fb-date-filter] [--refresh-towns] [--keep-tab]
          [--out DIR]

Requires Safari logged into Facebook (Develop > Allow JavaScript from Apple
Events). Uses MapKit for drive ETAs and the local `jev` CLI for card-date
classification and town-suggestion matching. Writes report.html + report.json
(+ report-full.json with drop reasons) to the output directory.

Speed comes from caching, not page-load throughput: town codes are cached in
~/.config/fbnear/towns.json (7-day TTL on unresolved towns), event details in
~/.config/fbnear/details.json (12h). Facebook rate-limits the events search
surface ("Temporarily Blocked" interstitial) when pages load faster than human
pace: keep --tabs at 2 and one query; the tool detects the block and stops all
workers instead of hammering. First run pays one-time code resolution (~8s per
town); later runs harvest only.
