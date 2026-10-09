# Native component attribution

CursorVoice was inspected selectively at revision `7a9f6d87dc149af11549e34bc17b4afcf0d0382b`, retrieved from its main-branch commit endpoint on 2026-10-06. The inspected files were [AXTree.swift](https://github.com/cursorvoice/cursor-voice/blob/7a9f6d87dc149af11549e34bc17b4afcf0d0382b/Sources/CursorVoice/Capabilities/AXTree.swift), [InputSynth.swift](https://github.com/cursorvoice/cursor-voice/blob/7a9f6d87dc149af11549e34bc17b4afcf0d0382b/Sources/CursorVoice/Capabilities/InputSynth.swift), and LICENSE.

The native layer follows its small AX helper and private CGEvent source/tag patterns. Observation freshness, conservative ambiguity resolution, cancellation boundaries, explicit empty modifiers, correct UTF-16 payloads and confirmation exclusions were implemented for this prototype. No CursorVoice coordinator, model service, shell, AppleScript, memory, audio or network code was imported. No package dependency was added. Preserve this upstream notice with distributions that include these native controls.

## CursorVoice MIT notice

MIT License

Copyright (c) 2026 cursorvoice

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Apple frameworks retain Apple's terms. This source inspection is not a dependency audit of CursorVoice as a whole.
