<p align="center"><img src="docs/icon.png" width="112" alt=""></p>

<h1 align="center">Beeline</h1>

<p align="center"><b>Beeline to anything.</b><br>
A fast Spotlight replacement for Mac that infers commands from plain text.</p>

<p align="center"><img src="docs/bar.png" width="640" alt="Beeline searching for wifi: Wi-Fi settings first, then the actions to turn Wi-Fi off or on"></p>

## What it does

- Opens apps, files, browser tabs and windows
- Opens System Settings pages from everyday words, like "night shift"
- Runs menu commands and presses buttons in the app in front
- Sleeps, locks, mutes, switches dark mode and Wi-Fi, quits apps
- Moves the front window to half or full screen
- Closes browser tabs that match what you type
- Does sums, and converts units, currencies and time zones
- Adds reminders and goals to Reminders
- Saves your open apps, windows and tabs, and brings them back later
- Copies, moves and installs files from the Finder window, like "packet logger to applications"
- Compresses, renames and converts the files selected in Finder, combines PDFs, and shrinks images and videos
- Rewrites the text selected in any app, like "make this shorter" or "translate to spanish"
- Keeps a history of what you copied
- Listens when you hold ⌘Space
- Asks Claude to answer questions or plan multi-step requests, which you approve first
- Learns what you pick and puts it first

<p align="center">
  <img src="docs/answer.png" width="49%" alt="A currency conversion shown as a large answer">
  <img src="docs/plan.png" width="49%" alt="A three-step plan from Claude with Cancel and Run buttons">
</p>

## Install

Needs an Apple silicon Mac on macOS 14 or later, with the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/ScribleSean/beeline
cd beeline
bash scripts/build-app.sh && open build/Beeline.app
```

To open it with ⌘Space, turn off Spotlight's shortcut in System Settings › Keyboard › Keyboard Shortcuts. Ask Claude needs [Claude Code](https://claude.com/claude-code) signed in. **Update Beeline** in the menu bar keeps it current.

## Privacy

Beeline runs on your Mac. It goes online only for:

- **Currency rates,** from the European Central Bank through [Frankfurter](https://frankfurter.dev), twice a day. Nothing about you is sent.
- **Ask Claude,** when you choose it. Your request goes to Claude. For a plan, so does what it can be built from: the names of your running apps, open windows and tabs, the front app's menu commands (except Open Recent, History, Bookmarks and the like) and the labels of buttons and links in the front window. Those labels can include names and file names in apps like Mail or Slack.
- **Search the web,** when you choose it, in your browser.

Clipboard history stays in memory and ends when Beeline quits. Anything a password manager marks as private is never kept. What you pick, with the words you typed to find it, is remembered in `~/Library/Application Support/Beeline` so it ranks first next time; reminders, web searches, desktops and file chores are not recorded. Settings can clear it. Saved desktops (app, window and tab names) live in the same folder.

## Permissions

macOS asks the first time a feature needs one.

| Permission | For |
| --- | --- |
| Accessibility | Windows, menu commands, buttons, pasting, Lock Screen |
| Automation | Browser tabs, dark mode, Finder's selection, emptying the Trash |
| Files & Folders | File chores on the Desktop, Documents and Downloads |
| Reminders | Reminders and goals |
| Microphone and Speech Recognition | Holding ⌘Space to talk |

Without Accessibility, Lock Screen and paste say so instead of doing nothing. Restart, Shut Down and Log Out need no permission; Eject uses the system directly.

## Keys

| Key | Does |
| --- | --- |
| ⌘Space | Open or close |
| Hold ⌘Space | Talk |
| ↑ ↓ | Move |
| ↩ | Open, run or copy |
| esc | Back, then close |

Anything that can't be undone asks for a second ↩: emptying the Trash, restarting, shutting down, logging out, closing several tabs, replacing a file, and buttons or menu commands like Delete, Send or Don't Save (and any button in a dialog).

## Development

Everything is in `Sources/Beeline`. These check behaviour without opening the bar:

```sh
build/Beeline.app/Contents/MacOS/Beeline --query "night shift"       # ranked results
build/Beeline.app/Contents/MacOS/Beeline --ai "make my mac quieter"  # the on-device model's pick
build/Beeline.app/Contents/MacOS/Beeline --plan "mute and dark mode"  # Claude's plan, runs nothing
build/Beeline.app/Contents/MacOS/Beeline --preview "wifi" bar.png    # render the bar to an image
build/Beeline.app/Contents/MacOS/Beeline --rewrite "more formal" "hey u free?"  # a rewrite, replaces nothing
```

Tests run with `swift test`.

Each ad hoc build is a new app to macOS, so its permissions stop working after a rebuild even though System Settings still shows Beeline switched on; the fix is to remove Beeline from the list with − and add it again. To keep permissions across rebuilds, put a code-signing certificate's name or fingerprint in an untracked `.signing-identity` file in this folder. (`BEELINE_SIGNING_IDENTITY` works too, but only for builds started from a shell that sets it: **Update Beeline** never sees variables from `~/.zshrc`.) The build prints a warning when it signs ad hoc.

## License

[MIT](LICENSE)
