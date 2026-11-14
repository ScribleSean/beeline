# Feature map

What a user can do, how they reach it, and what checks it. Live check means `scripts/live-check.sh <scenario>`.

| Feature | How a user reaches it | Checked by |
| --- | --- | --- |
| Open the bar | ⌘Space (or ⌥/⌃Space), menu bar | live check `open`, ShortcutConflictTests |
| Search apps, files, settings, windows | type in the bar | RankingTests, MatcherTests, TextMatchingTests |
| Switch or close browser tabs | type a tab title, "close tabs" | TabTests, BrowserTests, live check `tab` |
| Run a menu command or press a button in the front app | type its name, ↩ | ControlsTests, ScreenScanTests, live check `press` |
| Confirm before anything irreversible | ↩ twice | ControlsTests, RankingTests, BarModelTests |
| Mac controls (sleep, lock, mute, dark mode, Wi-Fi, quit, window halves) | type the action | RankingTests, LockAndAlertTests, CancelCleanupTests |
| Sums, units, currencies, time zones | type the expression | ConverterTests, RatesTests, RankingTests |
| Reminders and goals | "remind me …" | TextMatchingTests (time parsing only) |
| Saved desktops | "save desktop as …", its name | TextMatchingTests (wording only) |
| File chores: move, copy, replace, compress | Finder selection, then the chore | FileToolsTests |
| File chores: rename, convert, resize, combine, shrink video | Finder selection, then the chore | none |
| Rewrite selected text | select text, "make it formal" | RewriteTests, live check `rewrite` |
| Clipboard history | type "clipboard" | ClipboardTests |
| Talk while holding ⌘Space | hold the shortcut | SpeechEngineTests, FileSpeechBackendTests, VoiceLevelTests, live check `release`, `scripts/voice-check.sh` |
| Try again when nothing was heard | hold the shortcut, then **Try again** | TakeVaultTests, RetryTakeTests (saved audio, replay and the bar's note; the recognizers are stand-ins) |
| Act on release when plain and safe | let go of the shortcut | AutoActTests, VoiceOverTests, live check `release` |
| macOS Shortcuts by name | type the shortcut name | AliasAndShortcutTests |
| Undo the last toggle, window move or file move | type or say "undo" or "undo that" | UndoTests, FollowUpTests, FollowUpCommandTests, FileToolsTests |
| Go back to the previously focused window | say "the other window" | FollowUpCommandTests |
| Ask Claude or get a plan | pick the Claude row, Run | PlannerTests, ClaudeBinaryTests, ScreenTextTests, FollowUpTests, live check `plan` |
| Stop a run (esc, click, key) | esc in any app, click | RunGuardTests, live check `escape`, `click` |
| The bee | any on-screen action | BeeFlightTests, BeeLabelTests |
| Learned picks and forgetting them | pick a result, ⇧⌘⌫, Settings › Forget picks | LearningTests, CancelCleanupTests |
| Aliases | ⇧⌘A | AliasAndShortcutTests, ActionPanelTests |
| ⌘K actions panel | ⌘K on a result | ActionPanelTests |
| VoiceOver | VoiceOver on | VoiceOverTests, `scripts/voiceover-check.mjs` |
| Settings toggles (bee, act on release, clipboard history, learn from use) | Settings | none for the off states |
| Welcome and permissions | first launch | live check `welcome`, `permissions` |
| Update Beeline | menu bar | UpdateTests |
