"""Run a configuration (C0, C1, C3, ...) on the calendar/action items, locally or on the cloud baseline.

Local: same GGUF file and llama.cpp engine (llama-cpp-python, Metal) as the iOS app, so quality
carries over; latency here is Mac latency and is never reported as phone latency.
Cloud: Gemini (configs/cloud.yaml) with the SAME items, prompt and output schema.

Usage:
  python harness/run_calendar.py --config configs/C0.yaml --out results/C0_calendar_dev [--limit 5]
  python harness/run_calendar.py --config configs/C1.yaml --backend gemini --out results/cloud_calendar_dev

Writes <out>_pred.jsonl (scored by eval/score_calendar.py) and <out>_trajectory.jsonl: per item the
raw output, parse result, verifier verdict (C3), decision, first-token and total latency, input and
output tokens, decode speed, and for the cloud the returned model version, attempts and cost.
Every call has a timeout and a max-token cap; local runs use temperature 0.
"""
import argparse
import os
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import yaml

from calendar_schema import Clarify, action_json_schema, parse_action, to_pred
from config import load_config
from io_utils import read_jsonl, write_jsonl

ROOT = Path(__file__).resolve().parents[1]


def user_message(item):
    now = datetime.fromisoformat(item["reference_time"]).astimezone(ZoneInfo(item["tz"]))
    off = now.strftime("%z")
    return (f"Now: {now:%A}, {now.day} {now:%B %Y}, {now:%H:%M} "
            f"({item['tz']}, UTC{off[:3]}:{off[3:]}).\n\nMessage: {item['message']}")


def percentile(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = min(len(xs) - 1, max(0, round(p / 100 * (len(xs) - 1))))
    return xs[k]


def latency_summary(traj, key):
    vals = [t[key] for t in traj if t.get(key) is not None]
    if not vals:
        return f"{key}: n/a"
    return f"{key}: median {percentile(vals, 50)}, p95 {percentile(vals, 95)}, max {max(vals)}  (n={len(vals)})"


# ---------------------------------------------------------------- local (llama.cpp)

class LocalModel:
    def __init__(self, cfg, timeout_s, max_tokens):
        from llama_cpp import Llama, LlamaGrammar
        m = cfg["local_model"]
        self.llm = Llama(model_path=str(ROOT / m["file"]), n_ctx=m["context_tokens"], n_gpu_layers=-1,
                         seed=0, verbose=False)
        self.grammar = (LlamaGrammar.from_file(str(ROOT / cfg["grammars"]["calendar"]), verbose=False)
                        if cfg.get("constrained_decoding") else None)
        self.temperature = m.get("temperature", 0)
        self.timeout_s, self.max_tokens = timeout_s, max_tokens
        self.name = f"{m['name']}-{m['quant']}"

    def __call__(self, system, user):
        t0 = time.perf_counter()
        t_first, pieces, timed_out, n_out, finish = None, [], False, 0, None
        stream = self.llm.create_chat_completion(
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            temperature=self.temperature, max_tokens=self.max_tokens, grammar=self.grammar, stream=True)
        for chunk in stream:
            choice = chunk["choices"][0]
            if choice["finish_reason"] is not None:
                finish = choice["finish_reason"]
            elif "content" in choice["delta"]:
                n_out += 1  # one streamed chunk per generated token
                if choice["delta"]["content"]:
                    t_first = t_first or time.perf_counter()
                    pieces.append(choice["delta"]["content"])
            if time.perf_counter() - t0 > self.timeout_s:
                timed_out = True
                break
        t_end = time.perf_counter()
        text = "".join(pieces)
        # Context holds prompt + generated tokens, except the last token sampled at the length cap,
        # which is never evaluated. Checked against llama.cpp's own usage.prompt_tokens.
        n_in = self.llm.n_tokens - n_out + (1 if finish == "length" else 0)
        decode_s = (t_end - t_first) if t_first else 0.0
        return text, {
            "first_token_ms": round((t_first - t0) * 1000, 1) if t_first else None,
            "total_ms": round((t_end - t0) * 1000, 1),
            "input_tokens": n_in, "output_tokens": n_out,
            "decode_tok_s": round((n_out - 1) / decode_s, 1) if decode_s > 0 and n_out > 1 else None,
            "timed_out": timed_out, "hit_max_tokens": finish == "length", "finish_reason": finish,
            "model_version": self.name, "cost_usd": 0.0,
        }


# ---------------------------------------------------------------- cloud (Gemini)

class GeminiModel:
    def __init__(self, cloud_cfg, timeout_s, max_tokens, structured):
        from dotenv import load_dotenv
        from google import genai
        from google.genai import types
        load_dotenv(ROOT / ".env")
        key = os.environ.get(cloud_cfg["api_key_env"])
        if not key:
            raise SystemExit(f"Set {cloud_cfg['api_key_env']} in .env (see .env.example)")
        self.types = types
        self.client = genai.Client(api_key=key, http_options=types.HttpOptions(timeout=int(timeout_s * 1000)))
        self.model = cloud_cfg["model"]
        self.cfg = cloud_cfg
        self.max_tokens, self.structured = max_tokens, structured
        self.retries = cloud_cfg.get("max_retries", 3)
        self.name = self.model

    def _config(self, system):
        t = self.types
        kw = dict(system_instruction=system, max_output_tokens=self.max_tokens,
                  thinking_config=t.ThinkingConfig(thinking_level=self.cfg.get("thinking_level", "low")))
        if self.cfg.get("temperature") not in (None, "default"):
            kw["temperature"] = self.cfg["temperature"]
        if self.structured:  # same output schema as the local grammar (C1 and later)
            kw.update(response_mime_type="application/json", response_json_schema=action_json_schema())
        return t.GenerateContentConfig(**kw)

    def _cost(self, n_in, n_out):
        price = self.cfg.get("price_usd_per_mtok") or {}
        if price.get("input") is None or price.get("output") is None:
            return None
        return round(n_in / 1e6 * price["input"] + n_out / 1e6 * price["output"], 8)

    def __call__(self, system, user):
        from google.genai import errors
        attempts, last_err = 0, None
        while attempts <= self.retries:
            attempts += 1
            t0 = time.perf_counter()
            t_first, pieces, last = None, [], None
            try:
                for chunk in self.client.models.generate_content_stream(
                        model=self.model, contents=user, config=self._config(system)):
                    if chunk.text:
                        t_first = t_first or time.perf_counter()
                        pieces.append(chunk.text)
                    last = chunk
            except (errors.APIError, OSError, TimeoutError, Exception) as e:  # noqa: B014
                # APIError carries an HTTP code; transport errors (read timeout, connection reset)
                # do not, and are treated like a 503: retried, then logged as this item's error.
                code = getattr(e, "code", None)
                last_err = f"{code} {getattr(e, 'status', '')}".strip() if code else type(e).__name__
                if (code in (429, 500, 503) or code is None) and attempts <= self.retries:
                    time.sleep(min(60, 4 * 2 ** (attempts - 1)))
                    continue
                return "", {"error": last_err, "attempts": attempts, "first_token_ms": None,
                            "total_ms": round((time.perf_counter() - t0) * 1000, 1), "cost_usd": None}
            t_end = time.perf_counter()
            u = last.usage_metadata if last else None
            n_in = (u.prompt_token_count or 0) if u else 0
            n_out = (u.candidates_token_count or 0) if u else 0
            n_think = (getattr(u, "thoughts_token_count", 0) or 0) if u else 0
            decode_s = (t_end - t_first) if t_first else 0.0
            return "".join(pieces), {
                "first_token_ms": round((t_first - t0) * 1000, 1) if t_first else None,
                "total_ms": round((t_end - t0) * 1000, 1),
                "input_tokens": n_in, "output_tokens": n_out, "thinking_tokens": n_think,
                "decode_tok_s": round(n_out / decode_s, 1) if decode_s > 0 and n_out else None,
                "model_version": getattr(last, "model_version", None),
                "finish_reason": str(last.candidates[0].finish_reason) if last and last.candidates else None,
                "attempts": attempts, "error": None,
                "cost_usd": self._cost(n_in, n_out + n_think),  # thinking tokens are billed as output
            }
        return "", {"error": last_err, "attempts": attempts, "first_token_ms": None, "total_ms": None, "cost_usd": None}


# ---------------------------------------------------------------- main loop

def decide(action):
    if action is None:
        return "invalid"
    return {"clarify": "clarify", "none": "none"}.get(action.action, "act")


REPAIR_NOTE = ("Your previous answer failed a check: {why}. Reply again with one corrected JSON object, "
               "or clarify if the message does not say.")


def run(items, model, system, cfg, verifier=None):
    preds, traj = [], []
    for i, it in enumerate(items, 1):
        raw, info = model(system, user_message(it))
        action, err = parse_action(raw)
        before = to_pred(it["id"], action)
        verdict, repair = None, None
        if verifier is not None and action is not None:
            action, verdict = verifier(it, action)
            if verdict.get("recovery") == "repair_pending":
                # ONE capped retry: the failure goes back as feedback; a second failure -> clarify.
                why = "; ".join(f"{k}: {v}" for k, v in verdict["details"].items())
                raw2, info2 = model(system, user_message(it) + "\n\nPrevious answer: " + raw + "\n\n"
                                    + REPAIR_NOTE.format(why=why))
                action2, err2 = parse_action(raw2)
                if action2 is None:
                    action2 = Clarify(action="clarify", fields=[verdict["clarify_field"]])
                    v2 = {"ok": False, "failed": ["schema"], "recovery": "clarify"}
                else:
                    from verify_calendar import check
                    vc = cfg.get("verifier") or {}
                    v2 = check(it, action2, vc.get("calendar_crosscheck"), vc.get("span_policy", "drop_and_merge"))
                    if not v2["ok"]:
                        action2 = Clarify(action="clarify", fields=[v2["clarify_field"]])
                        v2["recovery"] = "clarify"
                action, repair = action2, {"raw_output": raw2, "parse_error": err2, "verifier": v2, **info2}
                verdict["recovery"] = "repair"
        pred = to_pred(it["id"], action)
        preds.append(pred)
        traj.append({"id": it["id"], "config": cfg["name"], "backend": model.name,
                     "raw_output": raw, "schema_valid": err is None, "parse_error": err,
                     "pred_before_verify": before if verifier else None,
                     "verifier": verdict, "repair": repair, "decision": decide(action), **info})
        print(f"[{i}/{len(items)}] {it['id']} {decide(action):<8} {info.get('total_ms')}ms  "
              f"{(err or '')[:60]}{raw[:70]!r}")
    return preds, traj


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--backend", choices=["local", "gemini"], default="local")
    ap.add_argument("--cloud-config", default="configs/cloud.yaml")
    ap.add_argument("--items", default="data/dev/calendar_dev.jsonl")
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--max-tokens", type=int, default=160)
    ap.add_argument("--timeout-s", type=float, default=30.0)
    a = ap.parse_args()

    cfg = load_config(a.config)
    items = read_jsonl(a.items)[: a.limit]
    system = (ROOT / cfg["prompts"]["calendar"]).read_text().strip()
    if a.backend == "local":
        model = LocalModel(cfg, a.timeout_s, a.max_tokens)
    else:
        cloud = yaml.safe_load((ROOT / a.cloud_config).read_text())
        model = GeminiModel(cloud, a.timeout_s, a.max_tokens, structured=bool(cfg.get("constrained_decoding")))
    verifier = None
    if cfg.get("verification"):
        from verify_calendar import make_verifier
        verifier = make_verifier(cfg)

    preds, traj = run(items, model, system, cfg, verifier)
    write_jsonl(a.out + "_pred.jsonl", preds)
    write_jsonl(a.out + "_trajectory.jsonl", traj)

    n = len(preds)
    print(f"\nSchema-valid: {sum(t['schema_valid'] for t in traj)}/{n}.  "
          f"Timed out: {sum(bool(t.get('timed_out')) for t in traj)}.  "
          f"Hit max tokens: {sum(bool(t.get('hit_max_tokens')) for t in traj)}.  "
          f"Errors: {sum(bool(t.get('error')) for t in traj)}")
    where = "Mac (not phone)" if a.backend == "local" else "cloud"
    for key in ("first_token_ms", "total_ms", "decode_tok_s", "input_tokens", "output_tokens"):
        print(f"{where} {latency_summary(traj, key)}")
    costs = [t.get("cost_usd") for t in traj]
    if a.backend == "gemini":
        print("Cost: " + (f"${sum(costs):.4f} total" if all(c is not None for c in costs)
                          else "not computed (set price_usd_per_mtok in configs/cloud.yaml)"))
        print("Model versions returned:", sorted({str(t.get("model_version")) for t in traj}))
    print(f"Wrote {a.out}_pred.jsonl and {a.out}_trajectory.jsonl; score with eval/score_calendar.py")


if __name__ == "__main__":
    main()
