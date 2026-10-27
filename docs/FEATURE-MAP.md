# Feature map

What a user can do, how they reach it, and what checks it today. Tests are in `Tests/BeelineTests`. "Live" means `scripts/live-check.sh`.

| Feature | How a user reaches it | Checked by |
| --- | --- | --- |
| Open the bar | ⌘Space (or ⌥/⌃Space), menu bar | live `open` (passed 22 Oct 2026) |
| Hotkey conflict card | Welcome screen when Spotlight holds ⌘Space | ShortcutConflictTests, live `welcome` |
| Search and rank apps, settings, actions | Type in the bar | RankingTests, MatcherTests, `--query` |
| Search files | Type in the bar | none |
| Switch to a window | Type its name | AutoActTests (safety only) |
| Switch browser tabs | Type a tab's title | BrowserTests (tab list, titles stay text in AppleScript), live `tab` (passed 22 Oct 2026) |
| Close tabs by browser or word | "close chrome tabs", "close tabs about x" | TabTests, BrowserTests (quoting), live `tab` closes one tab (passed 22 Oct 2026) |
| Menu commands of the front app | "show ruler" | ControlsTests (labels, same window), live `press` |
| Press buttons in the front window | Type a button's label | ControlsTests (labels), ScreenScanTests, live `press` |
| Confirm card for drastic items | Return twice | BarModelTests, ControlsTests, RankingTests |
| The bee: flight, perch, label | Any on-screen press | BeeFlightTests, BeeLabelTests, live `press` |
| Stop with Escape or by taking over | Escape or a click mid-run | RunGuardTests, live `escape` and `click` |
| Mac controls (sleep, lock, mute, dark mode, Wi-Fi) | Type the action | RankingTests (ranking only), KeyboardTests (lock keys) |
| Restart, Shut Down, Log Out, Eject | Type the action | RankingTests (confirm and ranking only) |
| Move the front window to half or full | Type "left half" or similar | none |
| Sums, units, currencies, time zones | Type a sum or "5 km in miles" | ConverterTests, RankingTests (dates are not sums) |
| Currency rates download | Twice a day, automatic | currencyRatesParseSavedResponse, currencyRatesRejectMalformedOrPartialResponses (parser only) |
| Reminders and goals | "remind me to …" | TextMatchingTests (date parsing and title only) |
| Saved desktops | "save desktop as x", "open desktop x" | TextMatchingTests (name parsing only) |
| File chores: move, copy, replace | Finder selection, "move this to desktop" | FileToolsTests |
| Compress | "compress" with a Finder selection | FileToolsTests |
| Rename, convert, resize images | "rename to x", "convert to jpg" | TextMatchingTests (row titles only) |
| Rewrite selected text | "make this more formal" | TextMatchingTests (when it is offered), live `rewrite` (passed 22 Oct 2026) |
| Clipboard history | Type "clipboard" | ClipboardTests |
| Voice: hold to talk | Hold ⌘Space | VoiceLevelTests (meter and hints only) |
| Act on release | Let go of ⌘Space | AutoActTests, live `release` |
| Run Shortcuts | Type a Shortcut's name | AliasAndShortcutTests |
| Undo | "undo" | UndoTests, FileToolsTests |
| Plan with Claude | "Ask Claude to work it out" row, then Run | PlannerTests (reading the reply: only distinct whole numbers from the list, at most 8; pipe; finding claude), live `plan` |
| Ask Claude | "Ask Claude" row under a question | none |
| On-device model rewrite of loose requests | Automatic | none (only `--ai` by hand) |
| Learned picks and forgetting | Pick a result; ⇧⌘⌫ | LearningTests, StoreTests |
| Aliases | ⇧⌘A | AliasAndShortcutTests |
| Web search | Last row, Return | RankingTests (`+` kept) |
| Settings window | Menu bar › Settings | none |
| Welcome and permissions | First launch | live `welcome` (card only) |
| Update Beeline | Menu bar › Update Beeline | UpdateTests (throwaway repos: main only, checking never moves the folder, no merge of a diverged main, a failed build keeps the working app) |

## Gaps, ranked

Severity is how much a user loses if it breaks silently (10 = Beeline is useless). Closed in Oct 2026 unless marked open.

| Severity | Feature | Status |
| --- | --- | --- |
| 9 | Open the bar with the shortcut | closed: live `open` passed |
| 8 | Plan with Claude: reading the reply | closed: PlannerTests |
| 7 | Switch browser tabs | closed: unit parts (BrowserTests) and live `tab` passed |
| 7 | Rewrite selected text | closed: live `rewrite` passed |
| 7 | Update Beeline | closed: UpdateTests. Open: the confirm dialog and relaunch |
| 6 | Move the front window to half or full | open: live check that tiles the TextEdit window and reads its frame |
| 6 | Mac controls actually acting (mute, dark mode) | open: live check that toggles twice and compares |
| 6 | Saved desktops restore | open: live check that saves, moves and restores the TextEdit window |
| 6 | Voice end to end | open: needs a way to feed a recording (`--hear file.wav`) |
| 5 | Search files | open: needs a Spotlight-backed check; `--files` runs file chores (covered by FileToolsTests), not search |
| 5 | Currency rates download | closed: currencyRatesParseSavedResponse, currencyRatesRejectMalformedOrPartialResponses |
| 5 | Reminders creation | open: manual (writes to your Reminders) |
| 4 | Ask Claude, on-device rewrite of loose requests | open: `--ai` and `--plan` by hand |
| 3 | Settings window | open: render the panes |
| 3 | Restart, Shut Down, Log Out, Eject acting | open: never run for real; confirm card is tested |

## Human-owned

Tests listed here are Sean's. Reviews never change or delete them.

None yet.
