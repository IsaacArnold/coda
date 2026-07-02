#!/usr/bin/env bash
#
# term-bench.sh — measure terminal rendering speed from inside a terminal.
#
# Coda renders via SwiftTerm's CPU/CoreText path (no GPU acceleration), so a
# ⌘K clear (Ctrl-L → full-grid redraw) or a burst of new lines is bound by how
# fast the terminal can draw cells. The PTY applies backpressure, so when the
# terminal draws slowly the writer blocks — meaning these timings reflect real
# on-screen redraw cost, not just how fast the shell can printf.
#
# Run the SAME script in each of these and compare the three numbers:
#   1) Coda (release build) on the slow Mac
#   2) Terminal.app / iTerm on the slow Mac   <- the tell: if this is also slow,
#                                                it's the machine/display, not Coda
#   3) Coda on a fast Mac
#
# Resize every window to the same rows x cols first so it's apples-to-apples.
#
# Usage: bash scripts/term-bench.sh
set -u

# High-resolution wall clock. perl ships with macOS, so no python3 assumption.
now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
elapsed() { perl -e 'printf "%.3f", $ARGV[1]-$ARGV[0]' "$1" "$2"; }

cols=$(tput cols 2>/dev/null || echo '?')
rows=$(tput lines 2>/dev/null || echo '?')
echo "terminal size: ${cols}x${rows} (cols x rows) — match this across machines"
echo

# 1) Throughput: dump many colored lines (stresses per-cell CoreText drawing).
printf 'throughput (20000 colored lines): '
t0=$(now)
for i in $(seq 1 20000); do
  printf '\033[3%dm%05d the quick brown fox jumps over the lazy dog 0123456789\033[0m\n' $((i % 8)) "$i"
done
printf '%ss\n' "$(elapsed "$t0" "$(now)")"

# 2) Clear latency: exactly what ⌘K triggers (full-screen clear + home), 200x.
printf 'clears (200x full-screen clear):  '
t0=$(now)
for _ in $(seq 1 200); do printf '\033[2J\033[H'; done
printf '%ss\n' "$(elapsed "$t0" "$(now)")"

# 3) Scroll cost: rapid newlines at the bottom (the "slow new line" feel).
printf 'scroll (5000 newlines):           '
t0=$(now)
for i in $(seq 1 5000); do printf 'line %d\n' "$i"; done
printf '%ss\n' "$(elapsed "$t0" "$(now)")"

echo
echo 'Done. Compare the three numbers across the runs above.'
