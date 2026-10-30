<p align="center"><img src="docs/images/icon.png" width="112" alt=""></p>

<h1 align="center">Beeline</h1>

<p align="center"><b>Type, or hold ⌘Space and talk. A bee shows where Beeline acts.</b><br>
A Mac assistant that works out what you mean and does it, on your Mac.</p>

<p align="center"><img src="docs/images/bar.png" width="640" alt="Beeline searching for wifi: Wi-Fi settings first, then the actions to turn Wi-Fi off or on"></p>

## What it does

- **Opens anything:** apps, files, browser tabs, windows, and System Settings pages from everyday words like "night shift"
- **Acts in the app in front:** runs its menu commands and presses its buttons, like "show ruler" in TextEdit
- **Controls the Mac:** sleep, lock, mute, dark mode, Wi-Fi, quitting apps, and moving the front window to half or full screen
- **Answers on the spot:** sums, units, currencies and time zones
- **Handles chores:** reminders and goals, saved desktops of apps, windows and tabs, file moves and copies from Finder, compressing, renaming, converting and shrinking files, and rewriting selected text in any app
- **Listens:** hold ⌘Space and speak; your words fill the bar as you talk. Say an app, a setting or a window plainly and it opens when you let go, after a beat to press esc
- **Runs your Shortcuts:** anything you built in the Shortcuts app shows up by name
- **Takes things back:** type "undo" to reverse the last toggle, window move or file copy or move, including a file it replaced
- **Plans with Claude:** asks Claude to answer a question or plan a multi-step request, which you see and approve before anything runs
- **Learns, visibly:** what you pick for a phrase comes first next time, marked "learned"; ⇧⌘⌫ forgets it, and an unused pick fades after four weeks
- **Aliases:** type a few letters, select a result and press ⇧⌘A; those letters open it from then on

<p align="center">
  <img src="docs/images/answer.png" width="49%" alt="A currency conversion shown as a large answer">
  <img src="docs/images/plan.png" width="49%" alt="A three-step plan from Claude with Cancel and Run buttons">
</p>

## The bee

When Beeline is about to press something on screen, a small bee flies there first, a yellow ring settles on the target, and a label says what it is about to do. Then it acts. Your own pointer never moves.

<p align="center"><img src="docs/images/live-bar.png" width="560" alt="The bar with “show ruler” typed and TextEdit's Show Ruler command as the top hit"></p>
<p align="center"><img src="docs/images/bee-flight.png" width="560" alt="The bee in flight over a TextEdit document"></p>
<p align="center"><img src="docs/images/bee-landed.png" width="560" alt="The bee beside TextEdit's Format menu, ringed in yellow, with the label Run Show Ruler"></p>

You stay in charge while it works:

- **Escape, in any app,** stops it. Beeline only watches for Escape and never swallows it, so it still reaches the app in front.
- **Your own click or keypress** stops it too: you have taken over. Moving the pointer doesn't.
- **The target is checked again** when the bee lands. If the window changed on the way, nothing is pressed.

The bee goes only to things with a place on screen: buttons, fields, menu commands and windows. Opening an app or a setting happens at once. Turn the bee off in Settings, and with Reduce Motion on it appears in place instead of flying.

## How it works

- **Matching happens on your Mac.** Beeline reads your apps, settings, windows and tabs, plus the front app's menus and buttons through Accessibility, and ranks them against what you type. The on-device language model rewrites loose requests into search words.
- **Speech is recognised on your Mac,** in your Mac's language when it can be, with your app names as hints. Without on-device recognition, Beeline doesn't listen at all.
- **Letting go acts only when it's plain and safe.** If your words name one app, setting, window or toggle exactly (or your alias for it), it runs after a short beat you can stop with esc. Anything that sends, deletes, closes, quits or runs a Shortcut waits for ↩. "Act when you let go" in Settings turns this off.
- **Claude only picks from a list.** For a plan, Claude sees numbered options built from what is on your Mac and replies with option numbers. It has no tools and cannot run anything. You see every step before pressing Run.
- **Anything that can't be undone asks twice:** emptying the Trash, restarting, shutting down, logging out, ejecting disks, closing several tabs, replacing a file, and buttons or menu commands like Delete, Send, Don't Save, Close All Tabs, or OK in a dialog.

## Install

Needs an Apple silicon Mac on macOS 14 or later, with the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/ScribleSean/beeline
cd beeline
bash scripts/build-app.sh && open build/Beeline.app
```

The welcome screen walks you through Accessibility. **Update Beeline** in the menu bar pulls the newest version and rebuilds it. Ask Claude needs [Claude Code](https://claude.com/claude-code) signed in on the same Mac. Beeline only runs a `claude` that Anthropic signed, so an npm install won't work; use the native installer.

### ⌘Space and Spotlight

Spotlight owns ⌘Space until you turn its shortcut off in System Settings › Keyboard › Keyboard Shortcuts › Spotlight. Until then Beeline opens with ⌥Space and says so; the welcome screen names what holds ⌘Space (Spotlight, input-source switching or another app) and has a button that takes you to the right page. You can choose ⌘, ⌥ or ⌃Space in Settings.

## Permissions

macOS asks the first time a feature needs one. Nothing else is needed: no Input Monitoring and no Screen Recording.

| Permission | Why |
| --- | --- |
| Accessibility | To read windows, menus and buttons in other apps and press them, paste, lock the screen, and watch for Escape while the bee works |
| Automation | To read and switch browser tabs, switch dark mode, read Finder's selection, and empty the Trash |
| Files & Folders | For file chores on the Desktop, Documents and Downloads |
| Reminders | To add reminders and goals |
| Microphone and Speech Recognition | To hear you while you hold ⌘Space |

Without Accessibility, Lock Screen and paste say so instead of doing nothing. Restart, Shut Down and Log Out need no permission, and Eject uses the system directly.

## Privacy

Beeline runs on your Mac. It goes online only for:

- **Currency rates,** from the European Central Bank through [Frankfurter](https://frankfurter.dev), twice a day. Nothing about you is sent.
- **Ask Claude,** when you choose it. Your request goes to Claude. For a plan, so does what it can be built from: the names of your running apps, open windows and tabs, the front app's menu commands (except Open Recent, History, Bookmarks and the like) and the labels of buttons and links in the front window. Those labels can include names and file names in apps like Mail or Slack.
- **Search the web,** when you choose it, in your browser.

Clipboard history stays in memory and ends when Beeline quits. Anything a password manager marks as private is never kept. What you pick, with the words you typed to find it, is remembered in `~/Library/Application Support/Beeline` so it ranks first next time; reminders, web searches, desktops and file chores are not recorded. Settings can clear it. Saved desktops (app, window and tab names) live in the same folder.

## Keys

| Key | Does |
| --- | --- |
| ⌘Space | Open or close |
| Hold ⌘Space | Talk |
| ↑ ↓ | Move |
| ↩ | Open, run or copy |
| esc | Back, then close |
| esc, in any app | Stop what the bee is doing |
| esc, while holding ⌘Space | Throw away what you said |
| ⌘K | Actions for the selected result |
| ⇧⌘C | Copy its path, link or name |
| ⌘↩ | Show an app or file in Finder |
| ⇧⌘A | Make what you typed an alias for the selected result |
| ⇧⌘⌫ | Forget a learned pick or remove an alias |

## Development

Everything is in `Sources/Beeline`. Tests run with `swift test`. These check behaviour without opening the bar:

```sh
build/Beeline.app/Contents/MacOS/Beeline --query "night shift"       # ranked results
build/Beeline.app/Contents/MacOS/Beeline --ai "make my mac quieter"  # the on-device model's pick
build/Beeline.app/Contents/MacOS/Beeline --plan "mute and dark mode"  # Claude's plan, runs nothing
build/Beeline.app/Contents/MacOS/Beeline --preview "wifi" bar.png    # render the bar to an image
build/Beeline.app/Contents/MacOS/Beeline --rewrite "more formal" "hey u free?"  # a rewrite, replaces nothing
```

`bash scripts/live-check.sh` checks the bee on a real screen, hands-free. It runs Beeline in a throwaway TextEdit document it opens and closes itself, presses only TextEdit's ruler and zoom commands, takes screenshots, and reports pass or fail for a press, a two-step plan, Escape and a click mid-flight, the Spotlight card, and acting on release, plus a `permissions` check that this signed build still gets real mic audio, speech, Reminders, Accessibility and Automation. It needs the app installed in `~/Applications` with Accessibility, and Screen Recording for the terminal.

`swift scripts/make-icon.swift` rebuilds the app icon and the menu bar glyph from `Resources/AppIcon-source.png`. Set `ICON_PREVIEW=/path/to/preview.png` to also write a 512-pixel preview of the icon.

Each ad hoc build is a new app to macOS, so its permissions stop working after a rebuild even though System Settings still shows Beeline switched on; the fix is to remove Beeline from the list with − and add it again. To keep permissions across rebuilds, put a code-signing certificate's name or fingerprint in an untracked `.signing-identity` file in this folder (git worktrees use the main checkout's). `BEELINE_SIGNING_IDENTITY` works too, but only for builds started from a shell that sets it: **Update Beeline** never sees variables from `~/.zshrc`. The build prints a warning when it signs ad hoc.

Builds are signed with hardened runtime, so other code can't load into Beeline (for example through `DYLD_INSERT_LIBRARIES`) and borrow its permissions. `Resources/Beeline.entitlements` turns back on what hardened runtime blocks and Beeline uses: the microphone, Apple Events and Reminders. A new feature that needs another protected resource (camera, contacts, location) needs its entitlement there too, or it fails silently.

How the bee and the stop rules came about is in [docs/VOICE-MERGE.md](docs/VOICE-MERGE.md), which records how an earlier voice-control prototype was folded in.

## License

[MIT](LICENSE)

To test voice without a microphone, build the app and run:

```sh
bash scripts/voice-check.sh "open TextEdit"
bash scripts/voice-check.sh "open TextEdit" --run
bash scripts/voice-check.sh "open TextEdit" --installed
```

The default uses `build/Beeline.app`; `--installed` uses `~/Applications/Beeline.app`,
while `--app /path/Beeline.app` selects another copy. The script generates an AIFF
with `say`, opens the bar as a held shortcut, feeds the recording through the same
recognition sessions as the microphone, and releases at the end. It prints the
transcript, chosen action and result, exits nonzero on failure, and leaves a JSONL
log with partial/final text, engine, action and accessibility announcements.
Actions run only with `--run` (`BEELINE_VOICE_RUN=1`). This checks recognition and
selection; a run result records Beeline dispatching the action, not independent
verification of the target app's state.

File input is enabled only by both `BEELINE_DEMO=voice` and
`BEELINE_VOICE_FILE=/path/to/audio`. It uses an installed macOS 26 dictation model
when available, otherwise the on-device recognizer. It never downloads a model
or requests microphone permission. The recognizer fallback needs existing Speech
Recognition permission; missing permission or a model is a failure with a reason.
The normal `swift test` file tests need no permissions and never show windows.
