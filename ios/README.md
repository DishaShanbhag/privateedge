# iOS app (owner: Yash)

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
  App/                  SwiftUI app (project.yml -> xcodegen -> PrivateEdge.xcodeproj)
```

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
ios/fetch_llama.sh
python harness/export_ios_bundle.py

# 2. Check the Swift pipeline against Python on the Mac (optional)
cd ios/PrivateEdgeCore && swift build -c release && swift test
.build/release/pe-replay --bundle ../App/Bundle --models ../../models --run C1_notes --out /tmp/swift_C1_notes
cd ../.. && python harness/compare_parity.py --python results/C1_notes_dev --swift /tmp/swift_C1_notes

# 3. Generate the Xcode project and open it
cd ios/App && xcodegen && open PrivateEdge.xcodeproj
```

In Xcode, under **Signing & Capabilities**, pick your team. Then select the iPhone 16 Pro and build with the **Release** configuration (Product → Scheme → Edit Scheme → Run → Build Configuration → Release).

## Put the models on the phone

The models aren't bundled (2 GB). Connect the iPhone, open **Finder → iPhone → Files → PrivateEdge**, and drag in:

- `models/Llama-3.2-3B-Instruct-Q4_K_M.gguf`
- the `models/embed/` folder (it needs `embed/bge-small-en-v1.5-q8_0.gguf`)

If anything is missing, the app lists it.

## Runs

| Mode | What it does |
|---|---|
| Feasibility gate | 10 notes items (C2, index loaded) and 10 calendar items (C1; C3 verification runs on the Mac) |
| Full dev run | All 60 items of one config |
| Sustained | 30 requests, one every 20 s: decode speed at minute 10 vs minute 1, thermal state |
| Stress | 10 minutes back-to-back, cycling through the items |

Each run writes to `Documents/runs/<time>_<name>/`:
- `pred.jsonl`
- `trajectory.jsonl`, which records per request: first-token and total latency, tok/s, peak footprint, minimum available memory, thermal state before and after, and battery;
- `memory.csv`, sampled every 50 ms;
- `summary.json`, with the run's peak memory and thermal-state changes.

Copy the folder back with Finder into `local_results/` (not committed), then:

```bash
python harness/compare_parity.py --python results/C2_notes_dev --swift <run folder>        # phone vs Mac
python harness/score_ios_calendar.py --device-run <run folder> --config configs/C3.yaml --out local_results/ios_C3_calendar_dev
```

## Heat

iOS gives apps no temperature, only `ProcessInfo.thermalState` (nominal, fair, serious, critical). The app logs it before and after every request and whenever it changes. The effect that matters is the slowdown, measured as decode tok/s in the sustained and stress runs. For a °C reading, use an infrared thermometer on the back of the phone at fixed points in the sustained run.

## Protocol reminders

- Release build, airplane mode, Low Power Mode off, fixed brightness. The app keeps the screen on during runs.
- Reboot before each run, and start unplugged at 80–90% battery in the nominal thermal state.

## Not done yet

- C3 on the phone. The calendar resolver and verifier are Python, so verification currently runs on the Mac on the phone's outputs. On-device C3 latency needs a Swift port of `harness/resolver.py` and `harness/verify_calendar.py`.
- Energy with Instruments, and the privacy checks (App Privacy Report, packet capture).
- Whether iOS's built-in SQLite includes FTS5. The app reports "no such module: fts5" if it doesn't, in which case SQLite would have to be bundled.
