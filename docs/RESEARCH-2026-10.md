# Research: how to make Beeline better (October 2026)

What the best Mac launchers, voice tools and computer-use agents do, and what Beeline should take from them. Four research passes ran in parallel on 21 October 2026, reading primary sources where they could. Claims marked † come from secondary sources or could not be confirmed.

## Findings

### Speed and ranking

- **Raycast** ranks an exact alias first, then alias prefix, fuzzy title, keywords, then frecency, and learns per query. Every result has "Reset Ranking". [Search bar](https://manual.raycast.com/search-bar)
- **Alfred** remembers which item you picked for the exact letters typed ("c" vs "ca"), over a rolling four weeks, so one popular item doesn't take every short query. [Result ordering](https://alfredapp.com/help/kb/understanding-result-ordering)
- **LaunchBar** reassigns an abbreviation after you pick something else for it twice. [Abbreviation search](https://www.obdev.at/resources/launchbar/help/AbbreviationSearch.html)
- **Spotlight in macOS 26** has quick keys ("sm" for send message), actions with fields you Tab through, the front app's menu commands, and App Intents from any app. That overlaps Beeline's menu matching; buttons, the bee and multi-step plans are what it lacks. [Apple newsroom](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/)

### Actions and extensibility

- **Raycast's ⌘K action panel** keeps secondary actions off the main list, each with its shortcut. [Action panel](https://manual.raycast.com/action-panel)
- **Alfred's Universal Actions** act on a selection anywhere; **LaunchBar's Instant Send** takes the selection as the subject, then a target. [Universal Actions](https://www.alfredapp.com/help/features/universal-actions/), [Instant Send](https://www.obdev.at/resources/launchbar/help/InstantSend.html)
- **Extensibility** in all of them starts small: Raycast Script Commands are any script with comment headers. [Script commands](https://manual.raycast.com/script-commands) The cheapest equivalent for Beeline is the user's own Shortcuts, through the `shortcuts` command-line tool.

### Voice

- **Apple's SpeechAnalyzer** (macOS 26) gives fast "volatile" guesses and a final result, on device, with models downloaded by the system. `DictationTranscriber` takes custom words; reportedly `SpeechTranscriber` ignores them †. [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/), [forum](https://developer.apple.com/forums/thread/811083). Third-party tests put its word error rate well below SFSpeechRecognizer's †.
- **The API Beeline uses today** already accepts `contextualStrings`, so app names can bias recognition now.
- **Superwhisper** uses one key for hold-to-talk and tap-to-toggle, plus a cancel key that throws the recording away. [Shortcuts](https://superwhisper.com/docs/get-started/settings-shortcuts)
- **Talon** keeps command and dictation apart and acts only when speech matches a known command; it ends a phrase after 300 ms of silence. [Basic usage](https://talon.wiki/Basic%20Usage/basic_usage)
- **None of the dictation apps auto-execute.** Acting on speech without a keypress is safe only for a narrow, undoable class of commands.

### Intent, agents and follow-ups

- **Ghost cursors:** Clicky (MIT) flies its own cursor to points Claude names and never clicks; OpenAra draws its own cursor and blocks sensitive apps. [Clicky](https://github.com/farzaa/clicky), [OpenAra](https://deepwiki.com/Aradotso/OpenAra). Beeline's bee already goes further: it flies, then acts, and stops on Escape or a click.
- **ChatGPT agent** asks before consequential actions and lets you take over for sensitive input † (help page blocked). [Help](https://help.openai.com/en/articles/11752874-chatgpt-agent)
- **Apple's on-device model** has a 4,096-token context per session, guided generation with `@Generable` types, and tool calling. [Context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window.md)
- **WWDC26** added a hook that runs before every tool call, so an app can confirm or block it, and warns that free-text arguments can carry injected instructions. [Session 347](https://developer.apple.com/videos/play/wwdc2026/347/)
- **Prompt injection from screen text is real:** Brave showed an agent obeying near-invisible page text. [Brave](https://brave.com/blog/unseeable-prompt-injections/) Beeline's plans include window, tab and button names, guarded by one sentence in the prompt.

### Safety and undo

- **Raycast confirms only irreversible deletion**, with a red button and a plain consequence. [Alert API](https://developers.raycast.com/api-reference/feedback/alert)
- **Reversible beats confirmed.** `FileManager.trashItem` returns where the item landed, which is all an Undo needs; Beeline throws it away today. [trashItem](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:))
- **Confirm fatigue:** asking twice for too many things trains people to press Return twice without reading.

### Onboarding, distribution and accessibility

- **Ask for a permission when a feature needs it,** not all up front, unless the app can't work without it. [HIG onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- **`AXIsProcessTrusted()` can say yes while Accessibility calls still fail** after a rebuild; a real read is the honest check. [Forum](https://developer.apple.com/forums/thread/703188)
- **Notarization needs the $99 a year Developer Program**; macOS 15 removed Control-click Open for unnotarized apps; Homebrew's main cask repository is closing to unnotarized apps †. A personal tap that builds from source costs nothing. [Macworld](https://www.macworld.com/article/2457844/what-to-do-when-you-cant-open-an-app-you-just-installed-in-macos-sequoia.html)
- **VoiceOver:** Beeline has one accessibility label. Rows, the confirm card and the bee need labels and announcements. **Dynamic Type has no macOS API** for third-party apps. [Forum](https://developer.apple.com/forums/thread/818858)
- **Liquid Glass** belongs on controls floating above content, never on content, and adapts to Reduce Transparency and Increase Contrast by itself †.

## What Beeline should do, ranked

Impact × effort, highest first. S is under a day, M a few days, L a week or more.

| # | Change | Impact | Effort | Where in Beeline |
| --- | --- | --- | --- | --- |
| 1 | **Act on release, safely.** After you let go of ⌘Space, if the final words match one undoable, local action (open an app or setting, an answer) clearly ahead of the next, show it for a beat with "esc to cancel", then run it. Anything else waits for Return. Setting: never / safe actions | High | M | `BarController.startListening` final transcript, `Matcher` scores, a risk field on `Item` |
| 2 | **Hear app names.** Pass installed app names and command words to the recognizer as custom words | High | S | `Voice.begin`, `contextualStrings` |
| 3 | **Undo.** Keep where trashed files landed and offer Undo; "undo" reverses the last reversible action (window move, toggle, mute) | High | S–M | `FileTools.trash`, `Actions`, a `LastRun` record |
| 4 | **Visible, forgettable learning.** A small "learned" mark on promoted results and a "Forget this pick" action; picks fade after four weeks | High | S | `Usage`, `BarView` rows |
| 5 | **Your own Shortcuts as results**, through `shortcuts list` and `shortcuts run` | Med–high | S | `Catalogue` |
| 6 | **Aliases (quick keys)** that always rank first | High | S–M | `Usage` or a new store, `Matcher` |
| 7 | **Follow-ups.** Remember the last request and its steps for a few minutes so "now the other window" or "undo that" makes sense to Claude | High | M | `Planner.plan`, `LastRun` |
| 8 | **Faster voice start:** capture from key-down, prepare the audio engine when the bar opens; Esc while holding throws the words away | Med | S–M | `Voice`, `BarController.shortcutPressed` |
| 9 | **Harden plans against screen text:** mark window, tab and button names as untrusted data, strip invisible characters | Med | S | `Planner`, `Catalogue.planOptions` |
| 10 | **VoiceOver and contrast pass:** labels on rows, the confirm card and the bee; opaque bar with Increase Contrast | Med | M | `BarView`, `Bee` |
| 11 | **⌘K action panel** for the selected result (copy, reveal, forget pick, add alias) | High | M | `BarView`, `BarModel` |
| 12 | **SpeechAnalyzer on macOS 26**, keeping today's recognizer on 14 and 15 | High | L | `Voice` |
| 13 | **Install for others at $0:** a Homebrew tap that builds from source; Sparkle later | Med | M | new tap repo, README |
| 14 | **Liquid Glass on macOS 26** for the bar's frame and buttons only | Med | M | `BarView` |

### "Smarter after you let go of ⌘Space"

Two ways to decide what to do with the words:

- **On the Mac only (recommended for acting).** Beeline's own ranking, plus Apple's on-device model where available, picks the top result. It acts by itself only for a single undoable action that clearly wins; otherwise it waits for Return. Private, instant, free, works offline.
- **Claude.** Better at multi-step requests and at "the other window", but takes seconds, sends window and button names off the Mac, needs a Claude Code sign-in, and widens the prompt-injection surface. Its plans should always be previewed, never run on release.

The research agrees on a split: the Mac decides and may act for safe single steps; Claude is asked only for plans and follow-ups, and its plans are always shown first.

## Chosen (21 October 2026)

- **After you let go of ⌘Space:** act on safe things. One clear, undoable, local action runs after a short "esc to cancel" beat; anything else waits for Return. Decided on the Mac.
- **Build first:** voice upgrades (app names, faster start, esc while holding), undo, learning you can see, and your Shortcuts plus aliases.
- **⌘Space:** keep it, with a clearer check that names what holds it.
