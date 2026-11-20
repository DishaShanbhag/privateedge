# iOS app (owner: Yash; calendar part: Disha)

Swift app running Llama 3.2 3B (Q4_K_M) in-process with llama.cpp on Metal.

## Status

| Part | State |
|---|---|
| llama.cpp runtime, model loading, SHA-256 check | done (`PrivateEdge/Sources/LlamaEngine.swift`, `AppModel.swift`) |
| Calendar task, C0 / C1 (grammar) / C3 (verification) / C3 + repair | done |
| Replay of the dev set, writing `_pred.jsonl` and `_trajectory.jsonl` | done (Replay tab) |
| Memory every 50 ms, `os_proc_available_memory`, thermal state and battery per request | done |
| Notes task (retrieval index, C2) | not started (Yash) |

## Layout

- `CalendarCore/` (Swift package): resolver, schema, C3 verifier, title rule and chat prompt, ported from
  `harness/` and `eval/`. `swift run calcore-parity` compares it with the Python on 16,651 fixture rows
  (`harness/export_swift_parity.py` makes them): all agree.
- `PrivateEdge/` (the app, generated with XcodeGen from `project.yml`): Calendar, Replay and Model tabs.
  It bundles the same `prompts/calendar_v0.txt`, `schemas/calendar.gbnf` and `data/dev/calendar_dev.jsonl`
  the Mac runs use, and the model file from `models/`.
- `EngineCheck/`: runs the app's `LlamaEngine.swift` on the Mac (macOS slice of the same llama.cpp build)
  over the dev set and compares with the committed Mac runs. Result on 2026-11-19: raw outputs identical
  on 60/60 items for C0, C1 and C3, and the same final decision on 60/60 for C3.
- `scripts/`: `build_llama.sh` (llama.cpp framework with a Simulator slice), `make_project.sh` (Xcode project).

llama.cpp is release **b12387**, commit `a956a852c`: the commit llama-cpp-python 0.3.37 (the Mac harness)
vendors. Decoding matches the harness: temperature 0 (grammar, then greedy), n_ctx 4096, n_batch 512,
flash attention off, and the common prompt prefix kept in the KV cache between messages.

## Run it

One-time setup (needs full Xcode from the App Store, opened once, and Homebrew):

```bash
sudo xcode-select -s /Applications/Xcode.app
brew install xcodegen cmake
ios/scripts/build_llama.sh      # 5-10 min: llama.cpp b12387 for iPhone and Simulator
ios/scripts/make_project.sh     # writes ios/PrivateEdge/PrivateEdge.xcodeproj
open ios/PrivateEdge/PrivateEdge.xcodeproj
```

In Xcode: choose a device at the top (an **iPhone 16 Pro** simulator, or your plugged-in iPhone), then
press **Run (⌘R)**. For a real iPhone, first pick your Apple ID team under the target's
*Signing & Capabilities*, and on the phone enable *Settings › Privacy & Security › Developer Mode*.
If signing rejects the increased-memory entitlement (some free accounts), delete that line from
`project.yml` and run `make_project.sh` again.

The Simulator runs the model on the Mac's CPU, so it shows the app working but its speed, memory and
heat are **not** phone numbers. Device measurements need the real iPhone.

## Measuring on the phone

Replay tab: pick a config, keep "Prompt date as in the Mac runs" on to compare with the committed Mac
results, tap Run. Files land in the app's Documents/results folder (visible in the Files app); share them
to the Mac and score as usual:

```bash
python eval/score_calendar.py --gold data/dev/calendar_dev.jsonl \
  --pred <file>_pred.jsonl --trajectory <file>_trajectory.jsonl
```

The trajectory adds phone fields: `cached_tokens`, `verify_ms`, `peak_footprint_mb`,
`available_mb_before/after`, `thermal_state_before/after`, `battery_level_before/after`,
`low_power_mode_before`, `device_model`, `os_version`, `today_date`. The "20 s pause" option is the
sustained-use run in the protocol. Protocol controls (release build, airplane mode, unplugged, Low
Power Mode off) are set by hand.

Model weights (`*.gguf`) and `ios/vendor/` are git-ignored.
