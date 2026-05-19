#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
[[ -f Lizard.c && -f Makefile ]] || { echo "must run in Lizard_c root"; exit 1; }
mkdir -p results
TS="$(date -u +%Y%m%dT%H%M%SZ)"
INV="results/lizard_impl_inventory_${TS}.md"
CSV="results/lizard_refcheck_bench_${TS}.csv"

COMMIT="$(git rev-parse HEAD)"
GIT_STATUS="$(git status --short || true)"
CC_VER="$(gcc --version | head -n1)"
CPU_MODEL="$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | xargs)"
OS_INFO="$(uname -a)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ORIG_LIZ=$(mktemp)
cp Lizard.c "$ORIG_LIZ"
trap 'cp "$ORIG_LIZ" Lizard.c >/dev/null 2>&1 || true; rm -f "$ORIG_LIZ"' EXIT

# phase 1: impl inventory
HAS_REF_DIR="no"
find . -type d \( -iname '*ref*' -o -iname '*reference*' \) > /tmp/lizard_ref_dirs.txt 2>/dev/null || true
# ignore .git internals
rg -v '^\./\.git' /tmp/lizard_ref_dirs.txt >/tmp/lizard_ref_dirs2.txt || true
[[ -s /tmp/lizard_ref_dirs2.txt ]] && HAS_REF_DIR="yes"
HAS_OPT_DIR="no"
find . -type d \( -iname '*opt*' -o -iname '*optimized*' -o -iname '*avx2*' \) > /tmp/lizard_opt_dirs.txt 2>/dev/null || true
rg -v '^\./\.git' /tmp/lizard_opt_dirs.txt >/tmp/lizard_opt_dirs2.txt || true
[[ -s /tmp/lizard_opt_dirs2.txt ]] && HAS_OPT_DIR="yes"

MAKE_TARGETS="$(awk -F: '/^[a-zA-Z0-9_.-]+ *:/{print $1}' Makefile | xargs)"
MAKE_HAS_REF="no"; echo "$MAKE_TARGETS" | rg -q '(^| )(reference|ref)( |$)' && MAKE_HAS_REF="yes"
MAKE_HAS_PORTABLE="no"; echo "$MAKE_TARGETS" | rg -q '(^| )portable( |$)' && MAKE_HAS_PORTABLE="yes"
MAKE_HAS_OPT="no"; echo "$MAKE_TARGETS" | rg -q '(^| )(optimized|avx2)( |$)' && MAKE_HAS_OPT="yes"

INTRIN_HITS="$(rg -n '__m256i|_mm256_|immintrin\.h' Lizard.c Makefile README.md || true)"
FALLBACK_HINTS="$(rg -n '#ifdef __AVX2__|NO_AVX2|USE_AVX2|\bAVX2\b|SCALAR|PORTABLE' Lizard.c Makefile README.md || true)"
DEFAULT_FLAGS="$(rg -n '^CFLAGS=' Makefile || true)"
DEFAULT_USES_AVX2="no"; echo "$DEFAULT_FLAGS" | rg -q -- '-mavx2|-march=native' && DEFAULT_USES_AVX2="yes"

cat > "$INV" <<EOF
# Lizard implementation inventory
- timestamp: $NOW
- commit: $COMMIT
- git status --short:
\
$GIT_STATUS
\
- compiler: $CC_VER
- cpu: $CPU_MODEL
- os: $OS_INFO

## Structure and targets
- separate reference directory: $HAS_REF_DIR
- separate optimized directory: $HAS_OPT_DIR
- make targets: $MAKE_TARGETS
- make has reference/ref target: $MAKE_HAS_REF
- make has portable target: $MAKE_HAS_PORTABLE
- make has optimized/avx2 target: $MAKE_HAS_OPT

## AVX2 and fallback signals
- default CFLAGS line: $DEFAULT_FLAGS
- default build uses -mavx2 or -march=native: $DEFAULT_USES_AVX2
- avx2 intrinsic hits:
\
$INTRIN_HITS
\
- scalar/portable fallback hints:
\
$FALLBACK_HINTS
\

## Conclusions
EOF

if [[ "$HAS_REF_DIR" == "no" && "$MAKE_HAS_REF" == "no" ]]; then
  echo "- no_separate_reference_implementation" >> "$INV"
fi
if [[ "$DEFAULT_USES_AVX2" == "yes" ]]; then
  echo "- portable build can be attempted by overriding CFLAGS without -mavx2 and without -march=native" >> "$INV"
  echo "- portable_build_used_as_non_avx2_baseline" >> "$INV"
fi
if ! rg -q 'CRYPTO_PUBLICKEYBYTES|CRYPTO_SECRETKEYBYTES|CRYPTO_CIPHERTEXTBYTES|PUBLICKEY_BYTES|SECRETKEY_BYTES|CIPHERTEXT_BYTES|PUBLIC_KEY_BYTES|SECRET_KEY_BYTES|CIPHER_TEXT_BYTES' Lizard.c; then
  echo "- size_macros_not_found" >> "$INV"
fi

# phase 2 benchmark
printf 'scheme,parameter,mode,keygen_kcycles,enc_kcycles,dec_kcycles,pk_bytes,ct_bytes,sk_bytes,iterations,status,notes\n' > "$CSV"
RAW_LOGS=()

set_param_cca() {
  cp "$ORIG_LIZ" Lizard.c
  sed -i 's@^#define PARAMS_Recommended@//#define PARAMS_Recommended@' Lizard.c
  sed -i 's@^//\s*#define PARAMS_CCA@#define PARAMS_CCA@' Lizard.c
}

extract_cycles() {
  local logfile="$1"
  python3 - "$logfile" <<'PY'
import re,sys
t=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
def g(p):
 m=re.search(p,t,re.I)
 return m.group(1) if m else 'NA'
print(g(r'Keygen\s+Cycles:\s*([0-9]+(?:\.[0-9]+)?)'))
print(g(r'Enc\s+cycles:\s*([0-9]+(?:\.[0-9]+)?)'))
print(g(r'Dec\s+cycles:\s*([0-9]+(?:\.[0-9]+)?)'))
PY
}

run_mode() {
  local mode="$1"; local build_cmd="$2"; local avx2_enabled="$3"
  local raw="results/lizard_refcheck_raw_PARAMS_CCA_${mode}_${TS}.log"
  RAW_LOGS+=("$raw")
  local status="ok"; local notes="mean_cycles_only"

  {
    echo "timestamp=$NOW"
    echo "commit=$COMMIT"
    echo "git_status_short<<EOF"; echo "$GIT_STATUS"; echo "EOF"
    echo "compiler=$CC_VER"
    echo "cpu=$CPU_MODEL"
    echo "os=$OS_INFO"
    echo "build_command=$build_cmd"
    echo "run_command=./Lizard"
    echo "parameter=PARAMS_CCA"
    echo "avx2_enabled=$avx2_enabled"
    echo "cycle_counter_type=repo_rdtsc_average_over_iter_testnum"
  } > "$raw"

  set_param_cca
  make clean >> "$raw" 2>&1 || true
  if ! eval "$build_cmd" >> "$raw" 2>&1; then
    status=$([[ "$mode" == "portable_no_avx2" ]] && echo portable_build_failed || echo build_failed)
    echo "Lizard,PARAMS_CCA,$mode,NA,NA,NA,NA,NA,NA,iter=100,$status,build_failed" >> "$CSV"
    return
  fi

  if ! rg -n '^#define PARAMS_CCA' Lizard.c >> "$raw"; then
    status="wrong_entry"
    echo "Lizard,PARAMS_CCA,$mode,NA,NA,NA,NA,NA,NA,iter=100,$status,params_cca_not_enabled" >> "$CSV"
    return
  fi

  ./Lizard >> "$raw" 2>&1 || status="run_failed"

  local entry="unknown"
  if rg -q 'CCA Parameter' "$raw"; then entry='EncDecTest_CCA'; else status='wrong_entry'; fi

  mapfile -t cyc < <(extract_cycles "$raw")
  local kg="${cyc[0]}"; local ec="${cyc[1]}"; local dc="${cyc[2]}"
  if [[ "$kg" == "NA" || "$ec" == "NA" || "$dc" == "NA" ]]; then
    notes="$notes no_cycle_output_found"
  fi
  kconv(){ [[ "$1" == "NA" ]] && echo "NA" || awk -v x="$1" 'BEGIN{printf "%.3f",x/1000.0}'; }
  echo "keygen_median_cycles=NA" >> "$raw"
  echo "enc_median_cycles=NA" >> "$raw"
  echo "dec_median_cycles=NA" >> "$raw"
  echo "keygen_kcycles=$(kconv "$kg")" >> "$raw"
  echo "enc_kcycles=$(kconv "$ec")" >> "$raw"
  echo "dec_kcycles=$(kconv "$dc")" >> "$raw"
  echo "entry_judgement=$entry" >> "$raw"

  echo "Lizard,PARAMS_CCA,$mode,$(kconv "$kg"),$(kconv "$ec"),$(kconv "$dc"),NA,NA,NA,iter=100,$status,$notes entry=${entry} size_macros_not_found" >> "$CSV"
}

run_mode "avx2" "make all" "yes"
run_mode "portable_no_avx2" "make all CFLAGS='-O3 -fomit-frame-pointer -std=c99 -march=x86-64'" "no"

cp "$ORIG_LIZ" Lizard.c

echo "inventory_path=$INV"
echo "csv_path=$CSV"
echo "raw_logs="; printf '%s\n' "${RAW_LOGS[@]}"
cat "$CSV"
echo "key_conclusion:"; rg -n 'no_separate_reference_implementation|portable_build_used_as_non_avx2_baseline|size_macros_not_found' "$INV" || true
