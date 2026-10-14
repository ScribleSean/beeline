# Beeline

A fast, native replacement for Spotlight on the Mac. Press **Cmd+Space** (or Option or Control+Space, set in Settings), type what you want in plain words, and press Return.

**In development.** It runs on the author's Mac and has no releases.

## What it does

- Opens or switches to apps, by name or by what they do ("video call", "browser").
- Opens System Settings panes by everyday words ("night shift", "change my resolution").
- Switches to open browser tabs in Chrome, Safari, Brave and Edge.
- Switches to any open window and runs menu commands of the app in front. These need the Accessibility permission.
- For requests that match nothing exactly ("make my mac quieter"), asks the language model built into macOS to rewrite the request as search words. Those results are marked "best guess".

- Presses buttons, links, checkboxes and fields inside the front window by name ("share", "undo"). Like menu commands, a control only appears when every typed word matches it, and one labelled like Delete, Send or Buy needs Return twice.
- Runs actions: sleep, lock, mute, volume, dark mode, Wi-Fi, quit an app, and more. Empty Trash needs Return twice.
- Finds files and folders by name through the Spotlight index, most recently used first.
- Does arithmetic as you type ("15% of 234", "2^10"). Return copies the answer.
- Converts units ("10 km in mi", "20c in f"), currencies ("100 usd in eur", "$50 in gbp") and time zones ("3pm london in new york", "time in tokyo"). Currency rates are the European Central Bank's, fetched from the free Frankfurter service twice a day.
- Keeps the last 100 things you copied, in memory only. Type "clip" to list them, or "clip invoice" to narrow them; Return pastes. Items a password manager marks as concealed are never kept.
- Closes browser tabs ("close every tab about flights") and moves the front window to the left half, right half or full screen.
- Remembers what you pick, so frequent choices rank higher and a learned request is instant.
- For multi-step requests, "Ask Claude to work it out" sends the request to Claude through the Claude Code sign-in on this Mac. Claude has no tools and can only pick from a numbered list of steps. Its plan is previewed, and nothing runs until Return.

Settings, in the menu bar or by typing "beeline settings", can start Beeline at login, change the shortcut, switch off the on-device model, the Claude row and learning, clear the history, and turn on a details strip that shows why a result was chosen and how long it took.

Exact matches appear as you type. The model is only asked after a pause, and it never chooses or runs anything itself.

## Build

Apple silicon, macOS 26 or later for the on-device model, and the Swift toolchain from the Xcode Command Line Tools.

```sh
bash scripts/build-app.sh && open build/Beeline.app
```

The script signs ad hoc unless `BEELINE_SIGNING_IDENTITY`, or an untracked `.signing-identity` file, names a certificate fingerprint. A stable certificate keeps macOS permissions across rebuilds.

**Update Beeline** in the menu bar pulls the newest pushed commit, rebuilds and relaunches, or tells you that you are up to date.

## Check the matching without the UI

```sh
build/Beeline.app/Contents/MacOS/Beeline --query "night shift"
build/Beeline.app/Contents/MacOS/Beeline --ai "make my mac quieter"
build/Beeline.app/Contents/MacOS/Beeline --plan "mute and open sound settings"   # prints Claude's plan, runs nothing
build/Beeline.app/Contents/MacOS/Beeline --controls Safari   # lists the controls offered in Safari's front window, presses nothing
```

## Layout

| File | Role |
| --- | --- |
| `Catalogue.swift` | Everything Beeline can act on, and the search across it |
| `Matcher.swift` | Word matching and scoring |
| `Chooser.swift` | The on-device model, used to turn a loose request into search words |
| `Semantic.swift` | Last-resort matching by meaning with the built-in embeddings |
| `Actions.swift` | Fixed commands such as sleep, mute and dark mode |
| `Planner.swift` | Asks Claude for a multi-step plan built only from listed steps |
| `Files.swift`, `Calculator.swift`, `Converter.swift` | File search by name, arithmetic, and unit, currency and time-zone conversion |
| `Clipboard.swift` | Clipboard history, in memory only |
| `Usage.swift` | Remembers picks, stored locally in Application Support |
| `Accessibility.swift`, `Controls.swift`, `Browser.swift` | Reading windows, menu commands and tabs |
| `BarView.swift`, `BarController.swift` | The bar and its panel |
| `scripts/make-icon.swift` | Builds the app icon and menu bar glyph from `Resources/AppIcon-source.png` |

The repository's first commit is an unrelated earlier prototype, Voice Control, kept as history.

## License

[MIT](LICENSE)
