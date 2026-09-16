# shellcheck shell=bash
#
# report.sh - o que aparece na tela: banner, resumos e rodape.
#
# Os resumos leem os CSVs ja gravados, entao independem do backend: qualquer
# fabricante que escreva as colunas de csv.sh e resumido pelo mesmo codigo.

PROCS_SKIP=0

summarize_proc() {
  (( TOP_N > 0 )) || return 0
  [[ -s "$PROCS_OUT" ]] || return 0

  LC_ALL=C awk -F, -v skip="$PROCS_SKIP" -v top="$TOP_N" '
  NR <= skip { next }
  {
    key = $3 " " $5 " " $4
    sum[key] += $6; cnt[key]++
    if ($6 + 0 > peak[key]) peak[key] = $6 + 0
  }
  END {
    if (!length(sum)) exit
    printf("\ntop %d processos por VRAM (media / pico):\n", top)
    # Ordenacao por selecao: o numero de processos com contexto na GPU e pequeno.
    for (i = 1; i <= top; i++) {
      best = ""; bestv = -1
      for (k in sum) {
        avg = sum[k] / cnt[k]
        if (avg > bestv) { bestv = avg; best = k }
      }
      if (best == "") break
      split(best, f, " ")
      printf("  %-24s pid %-7s [%s]  %6.0f MiB / %6d MiB\n",
             f[2], f[1], f[3], bestv, peak[best])
      delete sum[best]
    }
  }
  ' "$PROCS_OUT"
}

summarize_disk() {
  [[ -s "$DISK_OUT" ]] || return 0

  LC_ALL=C awk -F, -v skip="$DISK_SKIP" '
  NR <= skip { next }
  {
    d = $2; n[d]++
    rs[d] += $3; ws[d] += $4
    if ($3 + 0 > rp[d]) rp[d] = $3 + 0
    if ($4 + 0 > wp[d]) wp[d] = $4 + 0
    if ($8 != "" && $8 + 0 > tp[d]) tp[d] = $8 + 0
    if ($8 != "") { ts[d] += $8; tn[d]++ }
  }
  END {
    if (!length(n)) exit
    print "\ndisco (media / pico):"
    for (d in n) {
      t = (tn[d] ? sprintf("%.1f / %.1f C", ts[d] / tn[d], tp[d]) : "sem sensor")
      printf("  %-10s leitura %6.1f / %6.1f MB/s   escrita %6.1f / %6.1f MB/s   temp %s\n",
             d, rs[d] / n[d], rp[d], ws[d] / n[d], wp[d], t)
    }
  }
  ' "$DISK_OUT"
}

print_banner() {
  (( QUIET )) && return 0
  if (( WANT_GPU || WANT_PROC )); then
    printf 'GPU: %s (%s)\n' "$(backend_call name)" \
      "$( (( GPU_COUNT == 1 )) && echo "1 placa" || echo "$GPU_COUNT placas" )"
  fi
  (( WANT_GPU ))  && printf 'gravando em: %s\n' "$OUTPUT"
  (( WANT_PROC )) && printf 'processos em: %s (%s%s)\n' \
    "$PROCS_OUT" "$PROCS_MODE" "${FILTER_RAW:+, filtro: $FILTER_RAW}"
  (( WANT_DISK )) && printf 'disco em: %s (%s)\n' "$DISK_OUT" "${DISK_DEVS//;/, }"
  printf 'intervalo: %ss | duracao: %s | Ctrl+C para parar\n\n' \
    "$INTERVAL" "$( [[ "$DURATION" == 0 ]] && echo ilimitada || echo "${DURATION}s" )"
  return 0
}

print_footer() {
  (( QUIET )) && return 0
  printf '\n'
  (( WANT_GPU ))  && printf 'CSV: %s\n' "$OUTPUT"
  (( WANT_PROC )) && printf 'CSV processos: %s\n' "$PROCS_OUT"
  (( WANT_DISK )) && printf 'CSV disco: %s\n' "$DISK_OUT"
  return 0
}
