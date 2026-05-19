#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mkdir -p results
TS=$(date -u +%Y%m%dT%H%M%SZ)
INV="results/lizard_parameter_inventory_${TS}.md"; CSV="results/lizard_bench_${TS}.csv"
ORIG=$(mktemp); cp Lizard.c "$ORIG"; trap 'cp "$ORIG" Lizard.c; rm -f "$ORIG"' EXIT
COMMIT=$(git rev-parse HEAD)
PAT='PARAMS_|CCA_CATEGORY|CPA_CATEGORY|CATEGORY|N536|N663|Lizard.CCA|Lizard.KEM|RLizard|RING|n =|N =|CRYPTO_PUBLICKEYBYTES|CRYPTO_SECRETKEYBYTES|CRYPTO_CIPHERTEXTBYTES|PUBLICKEY|SECRETKEY|CIPHERTEXT'
SCAN=$(rg -n "$PAT" . || true)
MACROS=$(rg -o 'PARAMS_[A-Za-z0-9_]+' Lizard.c | sort -u)
{
 echo "# inventory"; echo "commit: $COMMIT"; echo "timestamp: $(date -u +%FT%TZ)"; echo '```'; echo "$MACROS"; echo '```';
 echo "- CCA_CATEGORY1_N536: $(rg -n 'CCA_CATEGORY1_N536' . || echo not_found)"
 echo "- CCA_CATEGORY1_N663: $(rg -n 'CCA_CATEGORY1_N663' . || echo not_found)"
 echo "- ring/RLizard: $(rg -n 'RLizard|RING' . || echo not_found)"
 echo '## scan'; echo '```'; echo "$SCAN"; echo '```';
 echo '- reasons: paper_public_material_has_only_category1_or_unclear_levels repo_exposes_only_PARAM_macro_family repo_has_no_level_1_3_5_CCA_KEM_instances'
} > "$INV"
mapfile -t CANDS < <(printf '%s
' "$MACROS")
echo 'scheme,parameter,mode,keygen_kcycles,enc_kcycles,dec_kcycles,pk_bytes,ct_bytes,sk_bytes,iterations,status,notes' > "$CSV"
RAW=()
for p in "${CANDS[@]}"; do
  cp "$ORIG" Lizard.c
  sed -i 's@^#define PARAMS_Recommended@//#define PARAMS_Recommended@' Lizard.c
  sed -i 's@^//#define PARAMS_Classical@//#define PARAMS_Classical@' Lizard.c
  sed -i 's@^//#define PARAMS_Homadd@//#define PARAMS_Homadd@' Lizard.c
  sed -i 's@^//#define PARAMS_Classical_Plaintext_32bit@//#define PARAMS_Classical_Plaintext_32bit@' Lizard.c
  sed -i 's@^//#define PARAMS_CCA@//#define PARAMS_CCA@' Lizard.c
  sed -i "s@^//\(#define ${p}\)@\1@" Lizard.c
  mode=avx2; status=ok; b="/tmp/b_${p}.log"
  if ! make clean >/dev/null 2>&1 || ! make all >"$b" 2>&1; then
    mode=portable
    if ! make clean >/dev/null 2>&1 || ! make all CFLAGS='-O3 -std=c99' >"$b" 2>&1; then
      raw="results/lizard_raw_${p}_${mode}_${TS}.log"; cp "$b" "$raw"; RAW+=("$raw")
      echo "Lizard,$p,$mode,NA,NA,NA,NA,NA,NA,NA,build_fail,build_failed" >> "$CSV"; continue
    fi
  fi
  raw="results/lizard_raw_${p}_${mode}_${TS}.log"; ./Lizard > "$raw" 2>&1 || status=run_fail; RAW+=("$raw")
  j=$(python3 scripts/parse_lizard_output.py "$raw")
  vals=$(python3 - <<PY
import json;d=json.loads('''$j''');
print(d['keygen'],d['enc'],d['dec'],';'.join(d['notes']),d['entry'])
PY
)
  k=$(echo $vals|awk '{print $1}'); e=$(echo $vals|awk '{print $2}'); d=$(echo $vals|awk '{print $3}'); n=$(echo $vals|awk '{print $4" "$5}')
  cv(){ [[ "$1" == NA ]]&&echo NA||awk -v x="$1" 'BEGIN{printf "%.3f",x/1000}'; }
  echo "Lizard,$p,$mode,$(cv $k),$(cv $e),$(cv $d),NA,NA,NA,iter=100,$status,$n size_macros_not_found" >> "$CSV"
done
cp "$ORIG" Lizard.c
printf 'inventory=%s
csv=%s
' "$INV" "$CSV"; printf '%s
' "${RAW[@]}"; cat "$CSV"
