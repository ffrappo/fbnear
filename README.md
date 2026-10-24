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
