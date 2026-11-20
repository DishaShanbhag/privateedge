# Results

One file set per run, named `<config>_<task>_<split>` (e.g. `C3_notes_dev`). iPhone runs are named `ios_<config>_<task>_<split>`.

## What gets committed

**Rule: if a number or figure in a report comes from a file, commit the file.** Anyone on the team, or the professor, should be able to open it and re-score it.

| Commit here | Keep in `results/raw/` (git-ignored for everyone) |
|---|---|
| Predictions (`_pred.jsonl`) and scores (`_scores.csv`) of each reported run | Parity checks (Swift vs Python, phone vs Mac) |
| Trajectories (`_trajectory.jsonl`), the source of verifier precision, silent errors and latency | Debugging, smoke-test and exploratory runs |
| iPhone run summaries and per-request trajectories (gate, sustained, stress) | Raw logs that no reported number comes from |
| Memory-over-time data (`memory.csv`) when a report figure uses it | |
| Write-ups (e.g. `calendar_dev_baseline.md`) | |

## Never commit, even for final runs

- **Runs on `data/private/`.** Raw outputs quote the team's real messages and notes. Keep them local and share them privately, like the data.
- **Full outputs of test-set runs.** They would put test items in the repo. Commit only the scores and aggregate numbers; keep predictions and trajectories local and share them privately.

## Grading stays blind

File names reveal the system, so graders don't grade from these files. They grade from a shuffled export with the system names removed, plus a separate key that maps grades back.
