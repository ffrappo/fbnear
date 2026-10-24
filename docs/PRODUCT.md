# fbnear

Events reachable by car from San Pietro in Cariano, refreshed twice a day.

## Truth

- Visitor: Francesco, from phone or laptop, checking what is reachable today or tomorrow.
- Data: Facebook events harvested from towns in concentric rings around home,
  filtered locally to the chosen day, not finished, and within the drive-time
  budget; sorted by driving time. Refresed by a scheduled run at 09:30 and
  17:30 Europe/Rome.
- The webapp is read-only. No accounts, no forms.
- Assumption (from brief, not confirmed): 45 minutes default drive budget,
  shown values are car travel from home in San Pietro in Cariano.

## Surfaces

- `/` (web/index.html): event list for a day. Operate mode: scan fast on a
  phone, open an event on Facebook in one tap.
