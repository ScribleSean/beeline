# Beeline

A fast, native replacement for Spotlight on the Mac. Press **Option+Space**, type what you want in plain words, and press Return.

**In development.** It runs on the author's Mac and has no releases.

## What it does

- Opens or switches to apps, by name or by what they do ("video call", "browser").
- Opens System Settings panes by everyday words ("night shift", "change my resolution").
- Switches to open browser tabs in Chrome, Safari, Brave and Edge.
- Switches to any open window and runs menu commands of the app in front. These need the Accessibility permission.
- For requests that match nothing exactly ("make my mac quieter"), asks the language model built into macOS to rewrite the request as search words. Those results are marked "best guess".

- Runs actions: sleep, lock, mute, volume, dark mode, Wi-Fi, quit an app, and more. Empty Trash needs Return twice.
- Finds files and folders by name through the Spotlight index, most recently used first.
- Does arithmetic as you type ("15% of 234", "2^10"). Return copies the answer.
- Closes browser tabs ("close every tab about flights") and moves the front window to the left half, right half or full screen.
- Remembers what you pick, so frequent choices rank higher and a learned request is instant.
- For multi-step requests, "Ask Claude to work it out" sends the request to Claude through the Claude Code sign-in on this Mac. Claude has no tools and can only pick from a numbered list of steps. Its plan is previewed, and nothing runs until Return.

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
| `Files.swift`, `Calculator.swift` | File search by name, and arithmetic |
| `Usage.swift` | Remembers picks, stored locally in Application Support |
| `Accessibility.swift`, `Browser.swift` | Reading windows, menu commands and tabs |
| `BarView.swift`, `BarController.swift` | The bar and its panel |
| `scripts/make-icon.swift` | Draws the app icon |

The repository's first commit is an unrelated earlier prototype, Voice Control, kept as history.

## License

[MIT](LICENSE)
