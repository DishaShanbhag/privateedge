"""Run a model configuration (C0, C1, ...) on the notes items, on the Mac.

Same GGUF file, same llama.cpp engine (via llama-cpp-python, Metal) and same retrieval as the
iOS app, so quality results carry over; latency and memory here are Mac numbers only and are
never reported as phone numbers.

Usage:
  python harness/run_notes.py --config configs/C0.yaml --out results/C0_notes_dev [--limit 5]

Writes <out>_pred.jsonl (id, answer, citations, abstained, format_ok) and <out>_trajectory.jsonl
(retrieval, raw output, parse result, decision, latency and speed per item).
"""
import argparse
import hashlib
import json
import re
import time
from datetime import datetime
from pathlib import Path

from chat_prompt import render_llama32, tokenize_prompt
from config import load_config
from io_utils import read_jsonl, write_jsonl
from metrics import abstention_report, print_reports, retrieval_report
from retrieval import build_retriever
from verify_notes import check as verify_answer

ABSTAIN = "the notes don't say"


def format_notes(hits):
    return "\n\n".join(f"[{h.note_id}] {h.title}\n{h.body}" for h in hits)


def user_message(item, hits):
    ref = datetime.fromisoformat(item["reference_time"])
    today = f"{ref:%A}, {ref.day} {ref:%B %Y}, {ref:%H:%M}"
    return f"Today is {today}.\n\nNotes:\n\n{format_notes(hits)}\n\nQuestion: {item['question']}"


def parse_output(text):
    """Return (answer, citations, format_ok). Accepts JSON optionally wrapped in a code fence."""
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    start, end = s.find("{"), s.rfind("}")
    try:
        obj = json.loads(s[start:end + 1]) if start != -1 else None
    except json.JSONDecodeError:
        obj = None
    if not isinstance(obj, dict) or not isinstance(obj.get("answer"), str):
        return text.strip(), [], False
    cits = obj.get("citations") or []
    ok = isinstance(cits, list) and all(isinstance(c, dict) and {"note_id", "quote"} <= c.keys() for c in cits)
    cits = [{"note_id": str(c["note_id"]), "quote": str(c["quote"])} for c in cits if isinstance(c, dict)
            and {"note_id", "quote"} <= c.keys()]
    return obj["answer"].strip(), cits, ok


def is_abstain(answer):
    return answer.strip().lower().rstrip(".") == ABSTAIN


def load_model(cfg, root):
    from llama_cpp import Llama
    m = cfg["local_model"]
    return Llama(model_path=str(root / m["file"]), n_ctx=m["context_tokens"], n_gpu_layers=-1,
                 seed=0, verbose=False)


def load_grammar(cfg, root):
    if not cfg.get("constrained_decoding"):
        return None
    from llama_cpp import LlamaGrammar
    return LlamaGrammar.from_file(str(root / cfg["grammars"]["notes"]), verbose=False)


def generate(llm, prompt_tokens, grammar, max_tokens):
    t0 = time.perf_counter()
    t_first, pieces = None, []
    stream = llm.create_completion(prompt=prompt_tokens, temperature=0.0, max_tokens=max_tokens,
                                   grammar=grammar, stream=True)
    for chunk in stream:
        delta = chunk["choices"][0]["text"]
        if delta:
            if t_first is None:
                t_first = time.perf_counter()
            pieces.append(delta)
    t_end = time.perf_counter()
    text = "".join(pieces)
    n_tok = len(llm.tokenize(text.encode(), add_bos=False, special=False)) if text else 0
    decode_s = (t_end - t_first) if t_first else 0.0
    return text, {
        "prompt_tokens": len(prompt_tokens),
        "first_token_ms": round((t_first - t0) * 1000, 1) if t_first else None,
        "total_ms": round((t_end - t0) * 1000, 1),
        "gen_tokens": n_tok,
        "decode_tok_s": round((n_tok - 1) / decode_s, 1) if decode_s > 0 and n_tok > 1 else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--items", default="data/dev/notes_dev.jsonl")
    ap.add_argument("--corpus", default="data/dev/notes_corpus.jsonl")
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--max-tokens", type=int, default=256)
    a = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    cfg = load_config(a.config)
    k = cfg["notes_retrieval"]["top_k"]
    items = read_jsonl(a.items)[: a.limit]
    index = build_retriever(cfg, a.corpus, root)
    system = (root / cfg["prompts"]["notes"]).read_text().strip()
    llm, grammar = load_model(cfg, root), load_grammar(cfg, root)
    notes = {n["id"]: n for n in read_jsonl(a.corpus)}

    preds, traj = [], []
    for i, it in enumerate(items, 1):
        hits = index.search(it["question"], k=k)
        prompt = render_llama32(system, user_message(it, hits), datetime.fromisoformat(it["reference_time"]))
        raw, timing = generate(llm, tokenize_prompt(llm, prompt), grammar, a.max_tokens)
        answer, cits, ok = parse_output(raw)
        retrieved = [h.note_id for h in hits]
        before, verdict = None, None
        if cfg.get("verification"):
            # C3: code checks (harness/verify_notes.py); a failed answer becomes "the notes don't say".
            vc = cfg.get("verifier") or {}
            before = {"answer": answer, "citations": cits}
            verdict = verify_answer(answer, cits, [{"note_id": h.note_id, "score": h.score} for h in hits], notes,
                                    float(vc.get("notes_retrieval_threshold") or 0.0), vc.get("notes_grounding", "quote"))
            if not verdict["ok"]:
                answer, cits = ABSTAIN, []
        abst = is_abstain(answer)
        gold = set(it["gold"]["support"])
        preds.append({"id": it["id"], "answer": answer, "citations": cits, "abstained": abst, "format_ok": ok})
        traj.append({
            "id": it["id"], "config": cfg["name"],
            "retrieved": [{"note_id": h.note_id, "score": round(h.score, 4)} for h in hits],
            "retrieval_hit": bool(gold & set(retrieved)) if gold else None,
            "format_ok": ok,
            "cited_ids_retrieved": all(c["note_id"] in retrieved for c in cits),
            # Diagnostic only (C3 is where this check changes behaviour):
            "quotes_verbatim": all(c["quote"].lower() in notes.get(c["note_id"], {}).get("body", "").lower()
                                   for c in cits),
            "pred_before_verify": before, "verifier": verdict,
            "decision": "abstain" if abst else "answer",
            "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest(),
            "raw_output": raw,
            **timing,
        })
        print(f"[{i}/{len(items)}] {it['id']} ok={ok} abstain={abst} {timing['total_ms']}ms  {answer[:70]!r}")

    write_jsonl(a.out + "_pred.jsonl", preds)
    write_jsonl(a.out + "_trajectory.jsonl", traj)
    print_reports(retrieval_report(items, {t["id"]: [r["note_id"] for r in t["retrieved"]] for t in traj}, k),
                  abstention_report(items, {p["id"]: p["abstained"] for p in preds}), k)
    n = len(preds)
    fmt = sum(p["format_ok"] for p in preds)
    verb = sum(t["quotes_verbatim"] for t in traj if t["decision"] == "answer")
    answered = sum(t["decision"] == "answer" for t in traj)
    ttft = sorted(t["first_token_ms"] for t in traj if t["first_token_ms"] is not None)
    tps = sorted(t["decode_tok_s"] for t in traj if t["decode_tok_s"])
    print(f"Format valid: {fmt}/{n}.  Answered with all quotes verbatim: {verb}/{answered}.")
    if ttft and tps:
        print(f"Mac (not phone) first token median {ttft[len(ttft)//2]} ms; decode median {tps[len(tps)//2]} tok/s")
    print(f"Wrote {a.out}_pred.jsonl and {a.out}_trajectory.jsonl")


if __name__ == "__main__":
    main()
