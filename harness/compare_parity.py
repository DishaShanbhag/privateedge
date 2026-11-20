"""Check that a Swift run (pe-replay on the Mac, or the iOS app) matches the Python harness.

Usage: python harness/compare_parity.py --python results/C1_notes_dev --swift <dir with trajectory.jsonl>

Compares per item: the exact prompt (SHA-256), the retrieved note IDs and the raw model output.
Prompt and retrieval must match exactly. Raw output can differ in rare greedy ties when the
hardware or kernels differ; every difference is listed.
"""
import argparse
import json


def load(path):
    with open(path) as f:
        return {r["id"]: r for r in map(json.loads, filter(str.strip, f))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True, help="prefix, e.g. results/C1_notes_dev")
    ap.add_argument("--swift", required=True, help="directory with trajectory.jsonl")
    a = ap.parse_args()
    py = load(a.python + "_trajectory.jsonl")
    sw = load(a.swift.rstrip("/") + "/trajectory.jsonl")
    ids = [i for i in sw if i in py]
    same_prompt = sum(py[i].get("prompt_sha256") == sw[i]["prompt_sha256"] for i in ids)
    same_ret = sum([r["note_id"] for r in py[i].get("retrieved", [])] == [r["note_id"] for r in sw[i].get("retrieved", [])] for i in ids)
    diff_out = [i for i in ids if py[i]["raw_output"] != sw[i]["raw_output"]]
    print(f"items compared: {len(ids)}")
    print(f"identical prompt:     {same_prompt}/{len(ids)}")
    print(f"identical retrieval:  {same_ret}/{len(ids)}")
    print(f"identical raw output: {len(ids) - len(diff_out)}/{len(ids)}")
    for i in diff_out:
        print(f"  {i}\n    python: {py[i]['raw_output'][:120]!r}\n    swift:  {sw[i]['raw_output'][:120]!r}")


if __name__ == "__main__":
    main()
