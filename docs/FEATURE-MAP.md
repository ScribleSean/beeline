# Feature map

What a user can do, how they reach it, and what checks it today. Tests are in `Tests/BeelineTests`. "Live" means `scripts/live-check.sh`.

| Feature | How a user reaches it | Checked by |
| --- | --- | --- |
| Open the bar | ⌘Space (or ⌥/⌃Space), menu bar | none |
| Hotkey conflict card | Welcome screen when Spotlight holds ⌘Space | ShortcutConflictTests, live `welcome` |
| Search and rank apps, settings, actions | Type in the bar | RankingTests, MatcherTests, `--query` |
| Search files | Type in the bar | none (only `--files` by hand) |
| Switch to a window | Type its name | AutoActTests (safety only) |
| Switch browser tabs | Type a tab's title | none (AppleScript not run in tests) |
| Close tabs by browser or word | "close chrome tabs", "close tabs about x" | TabTests |
| Menu commands of the front app | "show ruler" | ControlsTests (labels, same window), live `press` |
| Press buttons in the front window | Type a button's label | ControlsTests (labels), ScreenScanTests, live `press` |
| Confirm card for drastic items | Return twice | BarModelTests, ControlsTests, RankingTests |
| The bee: flight, perch, label | Any on-screen press | BeeFlightTests, BeeLabelTests, live `press` |
| Stop with Escape or by taking over | Escape or a click mid-run | RunGuardTests, live `escape` and `click` |
| Mac controls (sleep, lock, mute, dark mode, Wi-Fi) | Type the action | RankingTests (ranking only), KeyboardTests (lock keys) |
| Restart, Shut Down, Log Out, Eject | Type the action | RankingTests (confirm and ranking only) |
| Move the front window to half or full | Type "left half" or similar | none |
| Sums, units, currencies, time zones | Type a sum or "5 km in miles" | ConverterTests, RankingTests (dates are not sums) |
| Currency rates download | Twice a day, automatic | none |
| Reminders and goals | "remind me to …" | TextMatchingTests (date parsing and title only) |
| Saved desktops | "save desktop as x", "open desktop x" | TextMatchingTests (name parsing only) |
| File chores: move, copy, replace | Finder selection, "move this to desktop" | FileToolsTests |
| Compress | "compress" with a Finder selection | FileToolsTests |
| Rename, convert, resize images | "rename to x", "convert to jpg" | TextMatchingTests (row titles only) |
| Rewrite selected text | "make this more formal" | none (only `--rewrite` by hand) |
| Clipboard history | Type "clipboard" | ClipboardTests |
| Voice: hold to talk | Hold ⌘Space | VoiceLevelTests (meter and hints only) |
| Act on release | Let go of ⌘Space | AutoActTests, live `release` |
| Run Shortcuts | Type a Shortcut's name | AliasAndShortcutTests |
| Undo | "undo" | UndoTests, FileToolsTests |
| Plan with Claude | "Ask Claude to work it out" row, then Run | PlannerTests (pipe and finding claude only), live `plan` |
| Ask Claude | "Ask Claude" row under a question | none |
| On-device model rewrite of loose requests | Automatic | none (only `--ai` by hand) |
| Learned picks and forgetting | Pick a result; ⇧⌘⌫ | LearningTests, StoreTests |
| Aliases | ⇧⌘A | AliasAndShortcutTests |
| Web search | Last row, Return | RankingTests (`+` kept) |
| Settings window | Menu bar › Settings | none |
| Welcome and permissions | First launch | live `welcome` (card only) |
| Update Beeline | Menu bar › Update Beeline | none |

## Human-owned

Tests listed here are Sean's. Reviews never change or delete them.

None yet.
