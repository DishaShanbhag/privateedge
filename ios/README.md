# iOS app (owner: Yash)

Swift app running Llama 3.2 3B (Q4_K_M) in-process with llama.cpp on Metal.

Planned contents:
- llama.cpp integration and model loading (pin the GGUF SHA-256 in `configs/_base.yaml`)
- grammar-constrained decoding (C1)
- notes index: SQLite FTS5 + small embedding model (C2)
- verifier hooks (C3)
- replay harness that reads a `.jsonl` trace and writes predictions plus per-step trajectory logs
- measurement: peak memory every 50 ms, `os_proc_available_memory`, thermal state per request

Feasibility gate (by Nov 4): 10 calendar + 10 notes items on the iPhone 16 Pro, notes index loaded, verification on.
Fallback: Qwen3 1.7B in the same runtime.

Model weights (`*.gguf`) are git-ignored; download them locally.
