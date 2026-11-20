# iOS app (owner: Yash; calendar part: Disha)

The app runs the same pipeline as the Mac harness, on the phone: Llama 3.2 3B Q4_K_M through llama.cpp on Metal, grammar-constrained decoding, and notes retrieval (SQLite FTS5 BM25, plus bge-small embeddings for C2). While it runs, it measures latency, memory, thermal state and battery.

```
ios/
  fetch_llama.sh        downloads llama.cpp b12387 (llama.xcframework) and checks its SHA-256
  PrivateEdgeCore/      Swift package with the pipeline, shared by the app and the Mac tool
    Sources/PrivateEdgeCore/
      ChatPrompt.swift    Llama 3.2 prompt with the item's reference date (= harness/chat_prompt.py)
      NotesTask.swift     notes user message, output parsing, abstain rule (= harness/run_notes.py)
      Retrieval.swift     BM25 (FTS5), dense, hybrid RRF (= harness/retrieval.py)
      LlamaEngine.swift   model loading (mmap off), greedy + grammar generation, embeddings
      Metrics.swift       footprint every 50 ms, os_proc_available_memory, thermal state
      Replay.swift        runs an exported config; writes pred.jsonl, trajectory.jsonl, memory.csv, summary.json
    Sources/pe-replay/  Mac command-line tool, used to check the Swift pipeline against Python
  PrivateEdge/          the app (see below): Calendar, Notes, Replay, Measure and Model tabs
  Bundle/               run settings and dev data exported from configs/ (generated, git-ignored)
```

## One app with everything (also runs in the Simulator)

`ios/PrivateEdge` combines both halves on one llama.cpp build:

| Tab | What it does | Code |
|---|---|---|
| Calendar | type a message, get one action; C0 / C1 / C3 with the C3 checks run **on the phone** | CalendarCore |
| Notes | ask a question; search the 49 dev notes (C0/C1 keyword, C2 hybrid) and answer with citations | PrivateEdgeCore |
| Replay | the 60 calendar dev items, written as the Mac harness's pred / trajectory files | CalendarCore |
| Measure | feasibility gate, full run, sustained and stress runs, with device measurements | PrivateEdgeCore |
| Model | load, GPU switch, SHA-256 check, device memory | |

Calendar and Notes share one copy of the weights; Measure frees it, runs with its own copy, then reloads it.

```bash
source .venv/bin/activate
ios/scripts/build_llama.sh        # once, ~10 min: llama.cpp b12387 with iPhone + Simulator + macOS slices
                                  # (into PrivateEdgeCore/Frameworks; replaces the fetch_llama.sh download)
# models/ needs Llama-3.2-3B-Instruct-Q4_K_M.gguf and embed/bge-small-en-v1.5-q8_0.gguf
ios/scripts/make_project.sh       # exports ios/Bundle if missing, generates the Xcode project
open ios/PrivateEdge/PrivateEdge.xcodeproj    # pick a Simulator or the iPhone, press Run
```

The model files are copied into the app, so nothing needs to be dragged onto the phone. In the
Simulator the model runs on the Mac's CPU (the Simulator's Metal crashes or returns garbage), about
2-3 minutes per request; its timings, memory and thermal state are the Mac's, not a phone's.

## Why the phone matches the Mac

- **Same inference code.** llama.cpp b12387 is the commit vendored by llama-cpp-python 0.3.37, the version the Mac harness uses.
- **Same settings.** Greedy sampling with the grammar first, flash attention off, batch 512, 4K context.
- **Same prompt.** Both sides render the Llama 3.2 chat prompt themselves, with "Today Date" set to the item's reference date, and tokenize it with special tokens parsed and no extra BOS.
- **One source of truth.** Configs are exported from `configs/*.yaml` by `harness/export_ios_bundle.py`, so prompts, grammars and retrieval settings are never re-typed in Swift. Calendar prompts are rendered in Python with Disha's `user_message()`. The phone only generates, and `harness/score_ios_calendar.py` parses, verifies (C3) and scores the outputs on the Mac.

Checked on the Mac with `pe-replay` against the Python harness (2026-11-19), on all 60 dev items per config:

| Run | Same prompt | Same retrieval | Same raw output |
|---|---|---|---|
| C0 notes | 60/60 | 60/60 | 60/60 |
| C1 notes | 60/60 | 60/60 | 60/60 |
| C2 notes (hybrid, embeddings) | 60/60 | 60/60 | 60/60 |
| C1 calendar | 60/60 | n/a | 60/60 |

Peak memory footprint on the Mac was 3.19–3.25 GB, above the 3.0 GB target. Mac and iPhone account for memory differently, so this is a warning to check at the feasibility gate, not a phone result.

## Setup

```bash
# 1. Framework and bundle (from the repo root, inside .venv)
ios/scripts/build_llama.sh        # or ios/fetch_llama.sh for an iPhone-only build (no Simulator slice)
python harness/export_ios_bundle.py

# 2. Check the Swift pipeline against Python on the Mac (optional)
cd ios/PrivateEdgeCore && swift build -c release && swift test
.build/release/pe-replay --bundle ../Bundle --models ../../models --run C1_notes --out /tmp/swift_C1_notes
cd ../.. && python harness/compare_parity.py --python results/C1_notes_dev --swift /tmp/swift_C1_notes

# 3. Generate the Xcode project and open it
ios/scripts/make_project.sh && open ios/PrivateEdge/PrivateEdge.xcodeproj
```

In Xcode, under **Signing & Capabilities**, pick your team. Then select the iPhone 16 Pro and build with the **Release** configuration (Product → Scheme → Edit Scheme → Run → Build Configuration → Release).

## Models on the phone

The build copies `models/Llama-3.2-3B-Instruct-Q4_K_M.gguf` and `models/embed/` into the app, so nothing has to be copied by hand. If they aren't in the app, it looks in its Documents folder (**Finder → iPhone → Files → PrivateEdge**).

## Measure tab runs

| Mode | What it does |
|---|---|
| Feasibility gate | 10 notes items (C2, index loaded) and 10 calendar items (C1; C3 is applied on the Mac with `score_ios_calendar.py`) |
| Full dev run | All 60 items of one config |
| Sustained | 30 requests, one every 20 s: decode speed at minute 10 vs minute 1, thermal state |
| Stress | 10 minutes back-to-back, cycling through the items |

Each run writes to `Documents/runs/<time>_<name>/`:
- `pred.jsonl`
- `trajectory.jsonl`, which records per request: first-token and total latency, tok/s, peak footprint, minimum available memory, thermal state before and after, and battery;
- `memory.csv`, sampled every 50 ms;
- `summary.json`, with the run's peak memory and thermal-state changes.

Copy the folder back with Finder into `results/raw/` (git-ignored). Move a run into `results/` only if a reported number comes from it (see `results/README.md`). Then:

```bash
python harness/compare_parity.py --python results/C2_notes_dev --swift <run folder>        # phone vs Mac
python harness/score_ios_calendar.py --device-run <run folder> --config configs/C3.yaml --out results/raw/ios_C3_calendar_dev
```

## Heat

iOS gives apps no temperature, only `ProcessInfo.thermalState` (nominal, fair, serious, critical). The app logs it before and after every request and whenever it changes. The effect that matters is the slowdown, measured as decode tok/s in the sustained and stress runs. For a °C reading, use an infrared thermometer on the back of the phone at fixed points in the sustained run.

## Protocol reminders

- Release build, airplane mode, Low Power Mode off, fixed brightness. The app keeps the screen on during runs.
- Reboot before each run, and start unplugged at 80–90% battery in the nominal thermal state.

## Calendar on the phone: Swift C3 (Disha)

```
ios/
  CalendarCore/         Swift package: resolver, schema (with Pydantic's coercions), C3 verifier,
                        title rule, chat prompt, ported from harness/ and eval/
    Sources/calcore-parity/   compares it with the Python (fixtures from harness/export_swift_parity.py)
  PrivateEdge/          calendar app: type a message, get the action; C0/C1/C3 and C3 + repair on the
                        phone, dev-set replay, "Add to Calendar" (project.yml -> scripts/make_project.sh)
  EngineCheck/          runs PrivateEdge's LlamaEngine.swift on the Mac against the committed Mac runs
  scripts/              build_llama.sh (llama.cpp b12387 with a Simulator slice), make_project.sh
```

Checks (2026-11-19):
- `cd ios/CalendarCore && swift run -c release calcore-parity`: agrees with the Python on all 16,651
  fixture rows (dev items, message n-grams, edge cases, 150 DST cases, every saved model output and
  560 verifier decisions on them, the chat prompt on all 60 items).
- `cd ios/EngineCheck && swift run -c release engine-check C3`: raw output identical to the committed
  Mac runs on 60/60 items for C0, C1 and C3, and the same final decision after the Swift verifier on 60/60.
- In the Simulator the model runs on the Mac's CPU (its Metal crashes or gives garbage), so one
  message takes about 2.5 minutes there. Simulator timings are not phone numbers.

The calendar prompt uses each item's reference date as the template's "Today Date", like the Mac
runner (`harness/chat_prompt.py`); `engine-check C3` matches the Mac run on 60/60 items.

## Not done yet

- C3 in the Measure tab. Its calendar runs write C1 raw outputs, which are verified on the Mac; the Calendar and Replay tabs already run C3 on the phone with `CalendarCore`.
- Energy with Instruments, and the privacy checks (App Privacy Report, packet capture).
- Whether iOS's built-in SQLite includes FTS5. The app reports "no such module: fts5" if it doesn't, in which case SQLite would have to be bundled.
