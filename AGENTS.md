# fbnear

Facebook events reachable by car from home, through the logged-in Safari session.

## Homes

| What | Where |
|---|---|
| Code | ~/works/repos/fbnear |
| Reports | ~/works/artifacts/fbnear/<date>-<ts>/ |
| Config + towns cache | ~/.config/fbnear/ (private, not committed) |

## Notes

- Safari is driven via osascript `do JavaScript` in a background tab (never
  activates Safari, never switches the user's current tab).
- Facebook filters are only a harvest bound; exact date and reachability
  filtering is ours (event timestamps + MKDirections).
- Town codes come from the search typeahead (aria-describedby rows); Jev
  (fornace-jev via ~/.local/bin/jev) picks the correct municipality row and
  classifies card dates. One question per record.
