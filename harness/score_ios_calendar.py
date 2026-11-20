"""Turn a calendar run from the iOS app (or pe-replay) into Disha's prediction and trajectory files.

The phone only generates; this parses each raw output with harness/calendar_schema.py and, for a
config with verification (C3), runs harness/verify_calendar.py on it, exactly as run_calendar.py
does. The repair ablation is not supported (it needs a second generation on the phone).

Usage:
  python harness/score_ios_calendar.py --device-run DIR --config configs/C3.yaml --out results/raw/ios_C3_calendar_dev
  python eval/score_calendar.py --gold data/dev/calendar_dev.jsonl --pred results/raw/ios_C3_calendar_dev_pred.jsonl \
      --trajectory results/raw/ios_C3_calendar_dev_trajectory.jsonl
"""
import argparse
from pathlib import Path

from calendar_schema import parse_action, to_pred
from config import load_config
from io_utils import read_jsonl, write_jsonl
from run_calendar import decide
from verify_calendar import make_verifier

DEVICE_KEYS = ["prompt_tokens", "gen_tokens", "first_token_ms", "total_ms", "decode_tok_s", "prompt_sha256",
               "footprint_peak_mb", "available_min_mb", "thermal_state_before", "thermal_state_after",
               "battery_before", "battery_after", "t_start_s", "cycle"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device-run", required=True, help="directory with the app's pred.jsonl and trajectory.jsonl")
    ap.add_argument("--config", required=True)
    ap.add_argument("--items", default="data/dev/calendar_dev.jsonl")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    cfg = load_config(a.config)
    if (cfg.get("verifier") or {}).get("recovery") == "repair":
        raise SystemExit("repair needs a second generation on the phone; not supported")
    verifier = make_verifier(cfg) if cfg.get("verification") else None
    items = {it["id"]: it for it in read_jsonl(a.items)}
    dev = {t["id"]: t for t in read_jsonl(Path(a.device_run) / "trajectory.jsonl") if t.get("cycle", 0) == 0}
    preds, traj = [], []
    for iid, t in dev.items():
        it = items[iid]
        action, err = parse_action(t["raw_output"])
        before = to_pred(iid, action)
        verdict = None
        if verifier is not None and action is not None:
            action, verdict = verifier(it, action)
        preds.append(to_pred(iid, action))
        traj.append({"id": iid, "config": cfg["name"], "backend": "ios", "raw_output": t["raw_output"],
                     "schema_valid": err is None, "parse_error": err,
                     "pred_before_verify": before if verifier else None, "verifier": verdict,
                     "repair": None, "decision": decide(action), **{k: t.get(k) for k in DEVICE_KEYS}})
    write_jsonl(a.out + "_pred.jsonl", preds)
    write_jsonl(a.out + "_trajectory.jsonl", traj)
    print(f"Wrote {len(preds)} items to {a.out}_pred.jsonl and _trajectory.jsonl")


if __name__ == "__main__":
    main()
