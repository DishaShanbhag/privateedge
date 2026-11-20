# Feasibility gate on the iPhone 16 Pro (2026-11-19)

10 notes items (C2: hybrid retrieval, index loaded) and 10 calendar items (C1 generation), run from the app's Measure tab. Release build, model loaded with mmap off, all layers on the GPU.

**Conditions (a check, not a protocol run):** the phone was plugged in and charging at about 50% battery, not rebooted, and not in airplane mode. The notes run came first, then calendar. Memory samples (`memory.csv`, every 50 ms) stay in `results/raw/`.

- `*/pred.jsonl`, `*/trajectory.jsonl`, `*/summary.json`: as written by the app. Per request: latency, tok/s, peak footprint, available memory, thermal state and battery.
- `C1_calendar/scored_C3_calendar_gate_*`: the phone's C1 outputs, parsed and verified with C3 on the Mac (`harness/score_ios_calendar.py --config configs/C3.yaml`).

Phone vs Mac: identical raw output on 10/10 notes items (and identical prompts and retrieval) and 10/10 calendar items (`harness/compare_parity.py`).
