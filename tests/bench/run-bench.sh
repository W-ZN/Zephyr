#!/bin/bash
# Runs the app's bench mode over corpus files (design §3.4): Release build, fixed corpus, RUNS runs
# per file (default 3), each stopped after LIMIT seconds (default 300); FULL=NO skips laying out the
# whole file; CANVAS=block|source forces a presentation (default: the app's automatic choice).
# Results are JSON plus a one-line summary per file. Usage:
#   run-bench.sh <Zephyr.app> <corpus dir> <output dir> <sandbox home> [file names…]
set -uo pipefail
APP="$1"; CORPUS="$2"; OUT="$3"; HOME_DIR="$4"; shift 4
RUNS="${RUNS:-3}"; LIMIT="${LIMIT:-300}"; FULL="${FULL:-YES}"; CANVAS="${CANVAS:-}"
EXTRA=()
[ -n "$CANVAS" ] && EXTRA=(-ZephyrCanvas "$CANVAS")
NAMES=("$@")
[ ${#NAMES[@]} -eq 0 ] && NAMES=(prose-1mb math-900 math-3000 long-lines paragraph-20mb)
mkdir -p "$OUT" "$HOME_DIR"
for name in "${NAMES[@]}"; do
    file="$CORPUS/$name.md"
    done_runs=()
    for run in $(seq 1 "$RUNS"); do
        rm -f "$OUT/$name-$run.json"
        CFFIXED_USER_HOME="$HOME_DIR" "$APP/Contents/MacOS/Zephyr" -ZephyrBench "$file" -ZephyrBenchOut "$OUT/$name-$run.json" -ZephyrBenchFull "$FULL" ${EXTRA[@]+"${EXTRA[@]}"} &
        pid=$!
        ( sleep "$LIMIT"; kill "$pid" 2>/dev/null ) &
        watchdog=$!
        wait "$pid"
        kill "$watchdog" 2>/dev/null
        [ -f "$OUT/$name-$run.json" ] && done_runs+=("$run")
    done
    if [ ${#done_runs[@]} -eq 0 ]; then
        echo "$(printf '%-16s' "$name") no result within ${LIMIT}s per run"
        continue
    fi
    "${PYTHON:-python3}" - "$OUT" "$name" "${done_runs[@]}" <<'PY'
import json, statistics, sys
out, name, runs = sys.argv[1], sys.argv[2], sys.argv[3:]
data = [json.load(open(f"{out}/{name}-{i}.json")) for i in runs]
def med(key): return statistics.median(r.get(key, float("nan")) for r in data)
worst = max(zip(runs, data), key=lambda item: item[1].get('scroll_max_ms', 0))
print(f"{name:16} [{data[0].get('canvas', '?')}] n={len(data)}  open {med('open_total_ms'):7.1f} ms  first screen {med('first_screen_ms'):6.1f} ms  "
      f"full layout {med('style_and_layout_all_ms'):8.1f} ms  mem open {med('footprint_open_mb'):5.1f} MB  full {med('footprint_full_mb'):5.1f} MB  end {med('footprint_end_mb'):5.1f} MB  settled {med('footprint_settled_mb'):5.1f} MB  "
      f"jump p95 {med('jump_p95_ms'):6.1f} ms  key p50 {med('key_p50_ms'):6.1f} p99 {med('key_p99_ms'):6.1f} ms  math cache {med('math_cache_bytes') / 1e6:4.1f} MB\n"
      f"{'':16} scroll p50 {med('scroll_p50_ms'):5.1f} p99 {med('scroll_p99_ms'):6.1f} max {worst[1].get('scroll_max_ms', float('nan')):6.1f} ms (run {worst[0]})  theme switch {med('theme_switch_ms'):6.1f} ms  "
      f"then scroll p99 {med('theme_scroll_p99_ms'):6.1f} ms  resize p99 {med('resize_p99_ms'):6.1f} ms")
PY
done
