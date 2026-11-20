"""Try the calendar pipeline on your own message: shows what B0 and a model configuration do.

Usage:
  python harness/try_calendar.py "dinner with Sam friday at 7"
  python harness/try_calendar.py "lunch tmrw at 1" --config configs/C1.yaml
  python harness/try_calendar.py "spent $12 on parking yesterday" --now 2026-12-01T09:00:00-05:00

Default config is C3 (grammar + verification). Default "now" is the project's reference time,
Mon 2 Nov 2026 10:00 America/New_York; --now real uses the current time.
Not part of the evaluation: nothing is written to results/.
"""
import argparse
import json
from datetime import datetime
from zoneinfo import ZoneInfo

from b0_calendar import run_one
from calendar_schema import parse_action
from config import load_config
from run_calendar import ROOT, LocalModel, user_message


def show(label, action, extra=""):
    body = action.model_dump(mode="json", exclude={"spans"}) if action is not None else {"error": "not schema-valid"}
    print(f"\n{label}{extra}\n  " + json.dumps(body, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("message")
    ap.add_argument("--config", default="configs/C3.yaml")
    ap.add_argument("--now", default="2026-11-02T10:00:00-05:00", help="ISO time with offset, or 'real'")
    ap.add_argument("--tz", default="America/New_York")
    a = ap.parse_args()

    now = datetime.now(ZoneInfo(a.tz)).isoformat(timespec="seconds") if a.now == "real" else a.now
    item = {"id": "try", "message": a.message, "reference_time": now, "tz": a.tz}
    print(user_message(item))

    b0_action, _, _ = run_one(item)
    show("B0 (rules, no model):", b0_action)

    cfg = load_config(ROOT / a.config)
    model = LocalModel(cfg, timeout_s=30, max_tokens=160)
    raw, info = model((ROOT / cfg["prompts"]["calendar"]).read_text().strip(), user_message(item))
    action, err = parse_action(raw)
    show(f"{cfg['name']} model output:", action, f"  ({info['total_ms']:.0f} ms on this Mac)")
    if err:
        print("  raw:", raw[:200], "\n  error:", err)
    if cfg.get("verification") and action is not None:
        from verify_calendar import make_verifier
        final, verdict = make_verifier(cfg)(item, action)
        status = "passed" if verdict["ok"] else f"FAILED {verdict['failed']} -> {verdict.get('recovery')}"
        show(f"{cfg['name']} after verification ({status}):", final)
        for k, v in verdict["details"].items():
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
