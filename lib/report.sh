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

  # m_top ja vem com o numero expandido: o awk so o imprime. O LC_ALL=C continua
  # governando a formatacao numerica, que independe do idioma do texto.
  LC_ALL=C awk -F, -v skip="$PROCS_SKIP" -v top="$TOP_N" \
               -v m_top="$(msg awk_top_procs "$TOP_N")" '
  NR <= skip { next }
  {
    key = $3 " " $5 " " $4
    sum[key] += $6; cnt[key]++
    if ($6 + 0 > peak[key]) peak[key] = $6 + 0
  }
  END {
    if (!length(sum)) exit
    printf("\n%s:\n", m_top)
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

  # "leitura"/"escrita" sairam da linha e foram para o cabecalho: como rotulo
  # traduzido eles teriam largura variavel e empurrariam as colunas seguintes
  # de um idioma para outro. No cabecalho, a tabela fica alinhada em qualquer
  # idioma - e sobram duas flags em vez de quatro.
  LC_ALL=C awk -F, -v skip="$DISK_SKIP" \
               -v m_hdr="$(msg awk_disk_header)" \
               -v m_nosensor="$(msg awk_no_sensor)" '
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
    printf("\n%s:\n", m_hdr)
    for (d in n) {
      t = (tn[d] ? sprintf("%.1f / %.1f C", ts[d] / tn[d], tp[d]) : m_nosensor)
      printf("  %-10s %6.1f / %6.1f MB/s   %6.1f / %6.1f MB/s   temp %s\n",
             d, rs[d] / n[d], rp[d], ws[d] / n[d], wp[d], t)
    }
  }
  ' "$DISK_OUT"
}

# Numeros que dizem se o gargalo foi a CPU: a media esconde um nucleo saturado
# (a thread principal de um jogo), por isso o pico do nucleo mais ocupado vem
# ao lado. O PSI diz quanto tempo algo esperou por CPU, memoria ou disco.
summarize_sys() {
  [[ -s "$SYS_OUT" ]] || return 0

  LC_ALL=C awk -F, -v skip="$SYS_SKIP" \
               -v m_hdr="$(msg awk_sys_header)" \
               -v m_core="$(msg awk_sys_core)" \
               -v m_psi="$(msg awk_sys_psi)" \
               -v m_proc="$(msg awk_sys_proc)" '
  NR <= skip { next }
  {
    n++
    cs += $2; if ($2 + 0 > cp) cp = $2 + 0
    if ($4 + 0 > mc) mc = $4 + 0
    if ($9  + 0 > pc) pc = $9  + 0
    if ($10 + 0 > pm) pm = $10 + 0
    if ($11 + 0 > pi) pi = $11 + 0
    if ($12 != "") { ps += $12; pn++; if ($12 + 0 > pp) pp = $12 + 0 }
  }
  END {
    if (!n) exit
    printf("\n%s:\n", m_hdr)
    printf("  CPU      %6.1f / %6.1f %%   %s %6.1f %%\n", cs / n, cp, m_core, mc)
    printf("  PSI      %s cpu %.1f%%  mem %.1f%%  io %.1f%%\n", m_psi, pc, pm, pi)
    if (pn) printf("  %s %6.1f / %6.1f %%\n", m_proc, ps / pn, pp)
  }
  ' "$SYS_OUT"

  summarize_threads
}

# As threads que mais gastaram CPU. A media divide pelo numero de amostras da
# coleta inteira, e nao so pelas linhas em que a thread apareceu: uma thread so
# entra no CSV quando esta ativa, e dividir so por essas linhas inflaria a media.
summarize_threads() {
  (( TOP_N > 0 )) || return 0
  [[ -n "$SYS_PIDS" && -s "$THREADS_OUT" ]] || return 0

  local samples
  samples=$(( $(wc -l < "$SYS_OUT") - SYS_SKIP ))
  (( samples > 0 )) || return 0

  LC_ALL=C awk -F, -v skip="$THREADS_SKIP" -v top="$TOP_N" -v samples="$samples" \
               -v m_top="$(msg awk_top_threads "$TOP_N")" '
  NR <= skip { next }
  {
    key = $3 " " $4
    sum[key] += $6
    if ($6 + 0 > peak[key]) peak[key] = $6 + 0
  }
  END {
    if (!length(sum)) exit
    printf("\n%s:\n", m_top)
    for (i = 1; i <= top; i++) {
      best = ""; bestv = -1
      for (k in sum) if (sum[k] > bestv) { bestv = sum[k]; best = k }
      if (best == "") break
      sp = index(best, " ")
      printf("  %-24s tid %-7s %6.1f / %6.1f %%\n",
             substr(best, sp + 1), substr(best, 1, sp - 1), bestv / samples, peak[best])
      delete sum[best]
    }
  }
  ' "$THREADS_OUT"
}

print_banner() {
  (( QUIET )) && return 0
  if (( WANT_GPU || WANT_PROC )); then
    msg report_gpu "$(backend_call name)" \
      "$( (( GPU_COUNT == 1 )) && msg report_one_card || msg report_n_cards "$GPU_COUNT" )"
  fi
  (( WANT_GPU ))  && msg report_writing_to "$OUTPUT"
  (( WANT_PROC )) && msg report_procs_to \
    "$PROCS_OUT" "$PROCS_MODE" "${FILTER_RAW:+$(msg report_filter_suffix "$FILTER_RAW")}"
  (( WANT_DISK )) && msg report_disk_to "$DISK_OUT" "${DISK_DEVS//;/, }"
  if (( WANT_SYS )); then
    msg report_sys_to "$SYS_OUT"
    [[ -n "$SYS_PIDS" ]] && msg report_threads_to "$THREADS_OUT" "${SYS_PIDS//;/, }"
  fi
  msg report_interval \
    "$INTERVAL_MS" "$( [[ "$DURATION" == 0 ]] && msg report_unlimited || printf '%ss' "$DURATION" )"
  return 0
}

print_footer() {
  (( QUIET )) && return 0
  printf '\n'
  (( WANT_GPU ))  && msg report_csv "$OUTPUT"
  (( WANT_PROC )) && msg report_csv_procs "$PROCS_OUT"
  (( WANT_DISK )) && msg report_csv_disk "$DISK_OUT"
  (( WANT_SYS ))  && msg report_csv_sys "$SYS_OUT"
  (( WANT_SYS )) && [[ -n "$SYS_PIDS" ]] && msg report_csv_threads "$THREADS_OUT"
  return 0
}
