#!/usr/bin/env bash
#
# perf-window.sh - onde as threads gastaram CPU numa janela de horario.
#
# Le o <saida>-perf.data gravado por "monitor -P" e responde, para um trecho
# escolhido pelo horario dos CSVs (por exemplo, uma parada em que a GPU foi a
# 0%): quais threads rodaram, e em qual biblioteca e funcao.
#
# Uso: perf-window.sh <saida> <de> <ate> [thread]
#        saida    o caminho dado a -o, com ou sem .csv, ou o proprio -perf.data
#        de, ate  horario local HH:MM:SS[.mmm], o mesmo que aparece nos CSVs
#        thread   trecho do nome da thread para filtrar (ex.: GlobPool)
#
# Exemplo:
#   tools/perf-window.sh ~/.monitor/log/dota2-20260929-140736 14:10:24 14:10:26 GlobPool
#
# Tres visoes, porque cada uma responde uma coisa:
#   - por thread: quem estava rodando
#   - pela biblioteca da amostra: jogo, driver de video, libc ou kernel
#   - pelo primeiro quadro fora do kernel: quando a amostra cai no kernel, qual
#     codigo do programa fez a chamada (o kernel aparece sem simbolos quando
#     kptr_restrict esta ligado, que e o padrao)

set -uo pipefail
export LC_ALL=C
# Sem debuginfod: com ele (padrao no Ubuntu) o perf consulta a rede para cada
# biblioteca sem simbolos - a primeira analise levou 14 s parada, e os build-ids
# das bibliotecas do jogo iriam para um servidor externo. Os simbolos locais
# bastam para dizer em qual biblioteca e funcao a thread estava.
export DEBUGINFOD_URLS=

die() { printf 'erro: %s\n' "$1" >&2; exit 1; }

(( $# >= 3 )) || die "uso: ${0##*/} <saida> <de> <ate> [thread]"
base="$1"; from="$2"; to="$3"; thread="${4:-}"
base="${base%.csv}"; base="${base%-perf.data}"
data="$base-perf.data"; clock="$base-perf.clock"
[[ -r "$data" ]]  || die "nao achei $data"
command -v perf >/dev/null 2>&1 || die "perf nao encontrado"

# Horario torto para antes de tocar no perf.data: a conversao de verdade vem
# depois (precisa do dia da coleta), mas "25:99" nao vale em dia nenhum.
for t in "$from" "$to"; do
  date -d "$t" >/dev/null 2>&1 || die "horario invalido: $t"
done

# A ponte entre o horario dos CSVs e o relogio do perf. Gravado com -k, o
# perf.data traz a referencia de horario real, e o "-F tod" mostra a hora de
# cada amostra ao lado do tempo monotonico: o primeiro par basta. Gravacoes
# antigas do monitor nao tinham isso confirmado e deixavam um .clock com o par
# lido no inicio da coleta - ele fica como alternativa.
rt0=""; mono0=""
read -r rt0 mono0 < <(perf script -i "$data" -F tod,time 2>/dev/null | awk '
  $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $3 ~ /^[0-9.]+:$/ {
    sub(/:$/, "", $3); print $1 " " $2, $3; exit
  }' | { read -r d t m && printf "%s %s\n" "$(date -d "$d $t" +%s.%N)" "$m"; })
if [[ -z "$rt0" || -z "$mono0" ]]; then
  [[ -r "$clock" ]] \
    || die "sem referencia de horario: o perf.data nao tem -F tod e nao achei $clock"
  rt0=$(sed -n 's/^realtime=//p' "$clock")
  mono0=$(sed -n 's/^monotonic=//p' "$clock")
  [[ -n "$rt0" && -n "$mono0" ]] || die "$clock incompleto"
fi

# O horario vem sem data: e o dia em que a coleta comecou. Uma coleta que vira
# a meia-noite exigiria a data explicita, o que "de" e "ate" aceitam tambem
# (qualquer coisa que o "date -d" entenda).
day=$(date -d "@${rt0%.*}" +%F)
to_mono() {
  local s rt
  if [[ "$1" =~ ^[0-9]{1,2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?$ ]]; then s="$day $1"; else s="$1"; fi
  rt=$(date -d "$s" +%s.%N) || die "horario invalido: $1"
  awk -v rt="$rt" -v rt0="$rt0" -v m0="$mono0" 'BEGIN { printf "%.6f", rt - rt0 + m0 }'
}
# O die de dentro do $(...) so encerra o subshell: sem o "|| exit", um horario
# invalido seguiria adiante como janela vazia.
m_from=$(to_mono "$from") || exit 1
m_to=$(to_mono "$to") || exit 1

perf script -i "$data" --time "$m_from,$m_to" -F comm,tid,time,ip,sym,dso 2>/dev/null \
| awk -v want="$thread" '
  # Cada amostra: uma linha de cabecalho ("comm tid tempo:") e depois os quadros
  # da pilha, indentados, do mais interno para o mais externo.
  function flush(   k) {
    if (!inside) return
    n++
    th[comm]++
    lib[leafdso]++
    key = (userdso != "" ? userdso ": " usersym : "(so kernel)")
    usr[key]++
    inside = 0
  }
  function pick(line,   d, s) {
    d = line; sub(/^.*\(/, "", d); sub(/\)[ \t]*$/, "", d)
    s = line; sub(/^[ \t]*[0-9a-f]+[ \t]+/, "", s); sub(/[ \t]+\([^()]*\)[ \t]*$/, "", s)
    sub(/\+0x[0-9a-f]+$/, "", s)
    gsub(/.*\//, "", d)
    pd = d; ps = s
  }
  /^[^ \t]/ {
    flush()
    # O comm pode ter espacos: o tid e o penultimo campo, o tempo o ultimo.
    comm = $0; sub(/[ \t]+[0-9]+[ \t]+[0-9.]+:.*$/, "", comm)
    inside = (want == "" || index(comm, want) > 0)
    leafdso = ""; userdso = ""; usersym = ""; depth = 0
    next
  }
  inside && /^[ \t]+[0-9a-f]+/ {
    pick($0)
    depth++
    kernel = ($0 ~ /^[ \t]+ffffffff/ || pd == "[kernel.kallsyms]")
    if (depth == 1) leafdso = kernel ? "kernel" : pd
    if (!kernel && userdso == "") { userdso = pd; usersym = ps }
  }
  function top(arr, title, lim,   i, k, best, bv) {
    printf("\n%s\n", title)
    for (i = 1; i <= lim; i++) {
      best = ""; bv = 0
      for (k in arr) if (arr[k] > bv) { bv = arr[k]; best = k }
      if (best == "") break
      printf("  %5.1f%%  %6d  %s\n", bv * 100 / n, bv, best)
      delete arr[best]
    }
  }
  END {
    flush()
    if (!n) { print "nenhuma amostra nessa janela" (want != "" ? " para \"" want "\"" : ""); exit 1 }
    printf("%d amostras\n", n)
    top(th,  "por thread:", 10)
    top(lib, "pela biblioteca onde a amostra caiu:", 10)
    top(usr, "pelo primeiro quadro fora do kernel (biblioteca: funcao):", 15)
  }'
