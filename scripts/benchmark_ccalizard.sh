#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/benchmark_ccalizard"
RESULT_DIR="$ROOT_DIR/benchmark-results"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_FILE="$RESULT_DIR/ccalizard-benchmark-$TIMESTAMP.txt"

CC_BIN="${CC:-gcc}"
ITER="${ITER:-100}"
TESTNUM="${TESTNUM:-1000}"
RUNS="${RUNS:-1}"

show_help() {
  cat <<'HELP'
Usage: scripts/benchmark_ccalizard.sh [options]

One-click benchmark for CCALizard KEM in this repository.

Options:
  --all-params         Also benchmark the non-CCA CPA Lizard parameter macros
                       (Classical, Recommended, Homadd) for comparison.
  --runs N             Run each built binary N times (default: $RUNS or 1).
  --iter N             Override Lizard.c iter macro (default: $ITER or 100).
  --testnum N          Override Lizard.c testnum macro (default: $TESTNUM or 1000).
  --cc COMPILER        Compiler to use (default: $CC or gcc).
  -h, --help           Show this help.

Environment overrides:
  CC, ITER, TESTNUM, RUNS

Output:
  benchmark-results/ccalizard-benchmark-<UTC timestamp>.txt

Notes:
  * "ref" is compiled without AVX2-specific flags.
  * "optimized" is compiled with -msse2avx -mavx2 -march=native.
  * This codebase has one CCALizard KEM parameter macro: PARAMS_CCA. The three
    Classical/Recommended/Homadd macros are CPA Lizard parameters, not CCA/KEM.
HELP
}

INCLUDE_CPA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-params) INCLUDE_CPA=1; shift ;;
    --runs) RUNS="${2:?missing value for --runs}"; shift 2 ;;
    --iter) ITER="${2:?missing value for --iter}"; shift 2 ;;
    --testnum) TESTNUM="${2:?missing value for --testnum}"; shift 2 ;;
    --cc) CC_BIN="${2:?missing value for --cc}"; shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; show_help; exit 2 ;;
  esac
done

if ! command -v "$CC_BIN" >/dev/null 2>&1; then
  echo "Compiler not found: $CC_BIN" >&2
  exit 1
fi

case "$ITER" in (*[!0-9]*|"") echo "--iter/ITER must be a positive integer" >&2; exit 2;; esac
case "$TESTNUM" in (*[!0-9]*|"") echo "--testnum/TESTNUM must be a positive integer" >&2; exit 2;; esac
case "$RUNS" in (*[!0-9]*|"") echo "--runs/RUNS must be a positive integer" >&2; exit 2;; esac
if [[ "$ITER" -lt 1 || "$TESTNUM" -lt 1 || "$RUNS" -lt 1 ]]; then
  echo "--iter, --testnum, and --runs must be >= 1" >&2
  exit 2
fi

mkdir -p "$BUILD_DIR" "$RESULT_DIR"
: > "$RESULT_FILE"

log() {
  printf '%s\n' "$*" | tee -a "$RESULT_FILE"
}

has_cpu_avx2() {
  if [[ -r /proc/cpuinfo ]]; then
    grep -m1 -qw avx2 /proc/cpuinfo
  else
    return 1
  fi
}

# Keep ref portable-ish, but still use the repository's optimization level.
COMMON_FLAGS=(-O3 -fomit-frame-pointer -std=c99 -Wall -Wextra -DITER_OVERRIDE="$ITER" -DTESTNUM_OVERRIDE="$TESTNUM")
REF_FLAGS=()
OPT_FLAGS=(-msse2avx -mavx2 -march=native)

PARAMS=(PARAMS_CCA)
if [[ "$INCLUDE_CPA" -eq 1 ]]; then
  PARAMS+=(PARAMS_Classical PARAMS_Recommended PARAMS_Homadd)
fi

log "CCALizard benchmark started at $TIMESTAMP UTC"
log "Repository: $ROOT_DIR"
log "Compiler: $($CC_BIN --version | head -n 1)"
log "iter=$ITER testnum=$TESTNUM runs=$RUNS"
log ""
log "Parameter note: this repository defines one CCALizard KEM macro: PARAMS_CCA."
if [[ "$INCLUDE_CPA" -eq 1 ]]; then
  log "Also benchmarking CPA-only Lizard macros for comparison: PARAMS_Classical PARAMS_Recommended PARAMS_Homadd."
fi
log ""

if has_cpu_avx2; then
  AVX2_AVAILABLE=1
  log "CPU AVX2 support: yes"
else
  AVX2_AVAILABLE=0
  log "CPU AVX2 support: no (optimized build will be compiled if possible, but not executed)"
fi
log "optimized flags: ${OPT_FLAGS[*]}"
log "ref flags: ${REF_FLAGS[*]:-(none beyond common flags)}"
log ""

compile_binary() {
  local variant="$1"
  local param="$2"
  local out="$3"
  shift 3
  local flags=("$@")

  log "== Building $variant / $param =="
  log "Command: $CC_BIN ${COMMON_FLAGS[*]} ${flags[*]:-} -D$param Lizard.c fips202.c -o $out"
  "$CC_BIN" "${COMMON_FLAGS[@]}" "${flags[@]}" "-D$param" "$ROOT_DIR/Lizard.c" "$ROOT_DIR/fips202.c" -o "$out" -lm 2>&1 | tee -a "$RESULT_FILE"
}

report_avx2_instructions() {
  local bin="$1"
  if ! command -v objdump >/dev/null 2>&1; then
    log "AVX2 instruction check: skipped (objdump not found)"
    return
  fi

  local matches
  matches="$(objdump -d "$bin" | grep -Eo '\b(vpadd[[:alnum:]]*|vpsub[[:alnum:]]*|vpmul[[:alnum:]]*|vperm[[:alnum:]]*|vpbroadcast[[:alnum:]]*|vpgather[[:alnum:]]*|vpsll[[:alnum:]]*|vpsrl[[:alnum:]]*|vpor|vpand|vpxor)\b' | sort | uniq | tr '\n' ' ' || true)"
  if [[ -n "$matches" ]]; then
    log "AVX2 instruction check: found AVX/AVX2-family integer vector mnemonics: $matches"
  else
    log "AVX2 instruction check: no common AVX2 integer mnemonics found by objdump. The build still used AVX2 flags, but the compiler may not have emitted AVX2 for hot loops."
  fi
}

run_binary() {
  local variant="$1"
  local param="$2"
  local bin="$3"

  log "== Running $variant / $param =="
  for ((run=1; run<=RUNS; run++)); do
    log "-- run $run/$RUNS: $bin"
    "$bin" 2>&1 | tee -a "$RESULT_FILE"
  done
}

for param in "${PARAMS[@]}"; do
  ref_bin="$BUILD_DIR/Lizard_${param}_ref"
  opt_bin="$BUILD_DIR/Lizard_${param}_optimized"

  compile_binary ref "$param" "$ref_bin" "${REF_FLAGS[@]}"
  run_binary ref "$param" "$ref_bin"
  log ""

  if compile_binary optimized "$param" "$opt_bin" "${OPT_FLAGS[@]}"; then
    report_avx2_instructions "$opt_bin"
    if [[ "$AVX2_AVAILABLE" -eq 1 ]]; then
      run_binary optimized "$param" "$opt_bin"
    else
      log "== Running optimized / $param =="
      log "Skipped: host CPU does not advertise AVX2 support."
    fi
  fi
  log ""
done

log "Benchmark complete. Results saved to: $RESULT_FILE"
printf '\nResults saved to: %s\n' "$RESULT_FILE"
