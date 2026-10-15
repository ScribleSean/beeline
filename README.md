<p align="center"><img src="docs/icon.png" width="112" alt=""></p>

<h1 align="center">Beeline</h1>

<p align="center"><b>Type what you want. Go straight there.</b><br>
A fast Spotlight replacement for the Mac that understands plain words.</p>

<p align="center"><img src="docs/bar.png" width="640" alt="Beeline searching for wifi: Wi-Fi settings first, then the actions to turn Wi-Fi off or on"></p>

Press ⌘Space and type it the way you'd say it. "night shift" opens the right settings pane. "close every tab about flights" closes them. "100 usd in eur" just answers. When something takes more than one step, Claude plans it and you approve it before anything runs.

## What it does

- **Opens anything.** Apps, System Settings by everyday words, browser tabs, windows, files, and the menu commands and buttons of the app in front.
- **Does things.** Sleep, lock, mute, dark mode, Wi-Fi, quit an app, put a window on half the screen, close matching tabs.
- **Answers.** Sums, units, currencies and time zones, shown large. Return copies.
- **Remembers.** "remind me to call Sam at 5" goes to Reminders. "save desktop as tax work" brings back the same apps, windows and tabs later.
- **Pastes again.** "clip" lists what you copied.
- **Listens.** Hold ⌘Space and speak.
- **Asks Claude.** Questions are answered in the bar. Multi-step requests become a plan built only from steps Beeline offers, and nothing runs until you press Return.

It learns what you pick, so what you use most comes first.

<p align="center">
  <img src="docs/answer.png" width="49%" alt="A currency conversion shown as a large answer">
  <img src="docs/plan.png" width="49%" alt="A three-step plan from Claude with Cancel and Run buttons">
</p>

## Install

There's no release yet, so build it. You need an Apple silicon Mac with macOS 14 or later, and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/ScribleSean/beeline
cd beeline
bash scripts/build-app.sh && open build/Beeline.app
```

To use ⌘Space, first turn off Spotlight's shortcut in System Settings › Keyboard › Keyboard Shortcuts › Spotlight. Beeline falls back to ⌥Space until you do.

Some parts need more than that:

- Rewriting loose requests ("make my mac quieter") uses the model built into macOS 26 with Apple Intelligence.
- Ask Claude needs [Claude Code](https://claude.com/claude-code) installed and signed in.

To update, choose **Update Beeline** in the menu bar. It pulls the newest commit, rebuilds and relaunches, or says you're up to date.

## Privacy

Beeline runs on your Mac. It goes online only for:

- **Currency rates,** from the European Central Bank through [Frankfurter](https://frankfurter.dev), twice a day. Nothing about you is sent.
- **Ask Claude,** when you choose it. Your request goes to Claude, and for a plan, so do the names of your open windows and tabs.
- **Search the web,** when you choose it, in your browser.

Clipboard history stays in memory and ends when Beeline quits. Anything a password manager marks as private is never kept. What you pick is remembered in `~/Library/Application Support/Beeline`, and Settings can clear it.

## Permissions

macOS asks the first time a feature needs one.

| Permission | For |
| --- | --- |
| Accessibility | Windows, menu commands, buttons, pasting |
| Automation | Browser tabs, dark mode, emptying the Trash |
| Reminders | Reminders and goals |
| Microphone and Speech Recognition | Holding ⌘Space to talk |

## Keys

| Key | Does |
| --- | --- |
| ⌘Space | Open or close |
| Hold ⌘Space | Talk |
| ↑ ↓ | Move |
| ↩ | Open, run or copy |
| esc | Back, then close |

Anything that can't be undone, like emptying the Trash, asks for a second ↩.

## Development

Everything is in `Sources/Beeline`. These check behaviour without opening the bar:

```sh
build/Beeline.app/Contents/MacOS/Beeline --query "night shift"       # ranked results
build/Beeline.app/Contents/MacOS/Beeline --ai "make my mac quieter"  # the on-device model's pick
build/Beeline.app/Contents/MacOS/Beeline --plan "mute and dark mode"  # Claude's plan, runs nothing
build/Beeline.app/Contents/MacOS/Beeline --preview "wifi" bar.png    # render the bar to an image
```

The build signs ad hoc, so macOS may ask for permissions again after each rebuild. Set `BEELINE_SIGNING_IDENTITY` to a code-signing certificate's fingerprint to keep them.

## License

[MIT](LICENSE)
