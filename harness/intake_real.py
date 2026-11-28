"""Turn your own real messages or notes into anonymized items for the real-data slice.

Each team member runs this on THEIR OWN data and sends the output file to the labeller
privately (never through git). Output goes to data/private/, which git ignores. No gold labels
are written: the labeller adds them, following conventions.md.

Input, messages (one per line):   <sent time with offset> | <IANA time zone> | <message>
    2026-11-03T18:42:00-05:00 | America/New_York | dinner w Sam fri at 7?
Input, notes (blocks separated by a line "---"; first line is the title, the rest the body):
    Wifi
    network HomeNet, password <PASSWORD>
    ---

    python harness/intake_real.py messages my_messages.txt --who ds --names names.txt
    python harness/intake_real.py notes my_notes.txt --who ds --names names.txt

The script REFUSES to write while it finds personal details: phone numbers, email addresses, URLs,
street addresses, long digit runs (card or account numbers) and any name listed in --names (one
per line: the real names of people, places or employers that appear in your data). Replace each
with a placeholder of the same kind, e.g. <NAME>, <PHONE>, <ADDRESS>, or with a consistent fake
("Sam"), then run it again. It also warns about capitalised words that might be names; check them.
"""
import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]

PII = {
    "phone number": re.compile(r"(?<!\d)(?:\+?\d{1,2}[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}(?!\d)"),
    "email address": re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),
    "URL": re.compile(r"\bhttps?://\S+|\bwww\.\S+", re.I),
    "street address": re.compile(r"\b\d{1,5}\s+(?:[NSEW]\.?\s+)?(?:[A-Z][a-z]+|\d{1,3}(?:st|nd|rd|th))(?:\s+[A-Z][a-z]+)*\s+"
                                 r"(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Ln|Lane|Dr|Drive|Pl|Place|Way|Ct)\b\.?"),
    "long number (card/account)": re.compile(r"(?<![\d:/.-])\d{8,}(?![\d:/])|\b(?:\d{4}[\s-]){3}\d{4}\b"),
}
SENTENCE_WORDS = set("""i im i'm the a an and or but so ok okay hey hi hello yes no not my me we you he she they it this that
mon tue wed thu fri sat sun monday tuesday wednesday thursday friday saturday sunday jan feb mar apr may jun jul aug sep
oct nov dec january february march april june july august september october november december dr mr ms mrs prof""".split())


def problems(text, names):
    found = []
    for kind, rx in PII.items():
        found += [f"{kind}: {m.group(0)!r}" for m in rx.finditer(text)]
    for n in names:
        if re.search(rf"\b{re.escape(n)}\b", text, re.I):
            found.append(f"listed name: {n!r}")
    return found


def maybe_names(text):
    out = []
    text = re.sub(r"<[A-Z_]+>", " ", text)  # placeholders are fine
    for sent in re.split(r"(?<=[.!?])\s+|\n+", text):
        words = re.findall(r"[A-Za-z][A-Za-z'-]+", sent)
        out += [w for w in words[1:] if w[0].isupper() and w.lower() not in SENTENCE_WORDS and not w.startswith("<")]
    return out


def read_messages(path):
    rows = []
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|", 2)]
        if len(parts) != 3:
            raise SystemExit(f"line {n}: expected '<time> | <zone> | <message>'")
        when, tz, msg = parts
        try:
            t = datetime.fromisoformat(when)
            ZoneInfo(tz)
        except Exception as e:  # noqa: BLE001
            raise SystemExit(f"line {n}: bad time or zone ({e})")
        if t.tzinfo is None:
            raise SystemExit(f"line {n}: the time needs its UTC offset, e.g. 2026-11-03T18:42:00-05:00")
        rows.append({"message": msg, "reference_time": t.isoformat(timespec="seconds"), "tz": tz, "line": n})
    return rows


def read_notes(path):
    blocks = [b.strip("\n") for b in open(path, encoding="utf-8").read().split("\n---") if b.strip()]
    out = []
    for b in blocks:
        lines = b.strip().split("\n")
        out.append({"title": lines[0].strip(), "body": "\n".join(lines[1:]).strip()})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=["messages", "notes"])
    ap.add_argument("file")
    ap.add_argument("--who", required=True, help="your initials, used in item IDs (e.g. ds)")
    ap.add_argument("--names", help="file with real names to catch, one per line")
    ap.add_argument("--out-dir", default=str(ROOT / "data" / "private"))
    a = ap.parse_args()
    names = [n.strip() for n in open(a.names, encoding="utf-8")] if a.names else []
    names = [n for n in names if n and not n.startswith("#")]

    rows = read_messages(a.file) if a.kind == "messages" else read_notes(a.file)
    bad, warn = [], []
    for i, r in enumerate(rows, 1):
        text = r["message"] if a.kind == "messages" else r["title"] + "\n" + r["body"]
        where = f"line {r['line']}" if a.kind == "messages" else f"note {i} ({r['title'][:30]!r})"
        bad += [f"{where}: {p}" for p in problems(text, names)]
        warn += [f"{where}: {w!r}" for w in maybe_names(text)]
    if warn:
        print(f"Check these capitalised words: are any real names? ({len(warn)})")
        for w in warn[:40]:
            print("  ", w)
    if bad:
        print(f"\nNOT WRITTEN: {len(bad)} personal details still in the data. Replace them with placeholders "
              "(<NAME>, <PHONE>, <ADDRESS>, ...) or consistent fakes, then run again:")
        for b in bad:
            print("  ", b)
        raise SystemExit(1)

    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    who = re.sub(r"\W", "", a.who.lower())
    if a.kind == "messages":
        items = [{"id": f"real-{who}-{i:03d}", "message": r["message"], "reference_time": r["reference_time"],
                  "tz": r["tz"], "source": "real", "contributor": who, "slice": ["real"]} for i, r in enumerate(rows, 1)]
        dest = out / f"{who}_messages.jsonl"
    else:
        items = [{"id": f"rn-{who}-{i:03d}", "title": r["title"], "body": r["body"], "source": "real",
                  "contributor": who} for i, r in enumerate(rows, 1)]
        dest = out / f"{who}_notes.jsonl"
    with open(dest, "w", encoding="utf-8") as f:
        for it in items:
            f.write(json.dumps(it, ensure_ascii=False) + "\n")
    ignored = (ROOT / ".gitignore").read_text()
    print(f"\nWrote {len(items)} items to {dest} (git-ignored: {'data/private/*' in ignored}).")
    print("Send this file to the labeller privately (not through git). No labels were added.")


if __name__ == "__main__":
    main()
