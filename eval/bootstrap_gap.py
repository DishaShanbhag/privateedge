"""Paired-bootstrap 95% CI for the cloud-minus-local gap, in percentage points.

Usage:
  python eval/bootstrap_gap.py --local results/C3_scores.csv --cloud results/cloud_scores.csv [--max-score 2] [--margin 5]

Each CSV has columns id,score (calendar scores 0/1; notes scores 0/1/2, use --max-score 2).
Items are resampled in pairs, so both systems are always compared on the same items.
Non-inferiority is claimed only if the CI upper bound is below the margin.
"""
import argparse
import csv
import random


def read(path):
    with open(path) as f:
        return {r["id"]: float(r["score"]) for r in csv.DictReader(f)}


def paired_bootstrap(local, cloud, max_score=1.0, n=10000, seed=0):
    ids = sorted(set(local) & set(cloud))
    if not ids:
        raise SystemExit("No shared item ids between the two files")
    diffs = [(cloud[i] - local[i]) / max_score * 100 for i in ids]
    rng = random.Random(seed)
    k = len(diffs)
    means = sorted(sum(rng.choice(diffs) for _ in range(k)) / k for _ in range(n))
    gap = sum(diffs) / k
    return gap, means[int(0.025 * n)], means[int(0.975 * n) - 1], k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--local", required=True)
    ap.add_argument("--cloud", required=True)
    ap.add_argument("--max-score", type=float, default=1.0)
    ap.add_argument("--margin", type=float, default=5.0)
    ap.add_argument("--n", type=int, default=10000)
    a = ap.parse_args()

    gap, lo, hi, k = paired_bootstrap(read(a.local), read(a.cloud), a.max_score, a.n)
    print(f"Items: {k}")
    print(f"Gap (cloud - local): {gap:.2f} points, 95% CI [{lo:.2f}, {hi:.2f}]")
    verdict = "non-inferior" if hi < a.margin else "not shown non-inferior"
    print(f"Margin {a.margin} points: {verdict}")


if __name__ == "__main__":
    main()
