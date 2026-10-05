#!/usr/bin/env bash
#
# freeze-probe.sh - sonda das travadas da thread principal (bpftrace, root).
#
# Subprojeto do monitor, mas independente dele: o monitor continua rodando
# como usuario, pelo hook do GameMode, exatamente como antes. So este script
# precisa de root, porque carrega um programa eBPF no kernel.
#
# Espera o jogo abrir, prende a sonda (freeze.bt) ao processo e grava, a cada
# travada da thread principal acima do limiar, um bloco com: o timeout que ela
# pediu ao kernel, a pilha em que dormiu, quem a acordou (e por qual mecanismo),
# quem rodou durante a parada e o descritor do epoll que disparou. Sai sozinho
# quando o jogo fecha.
#
# Uso:
#   sudo ./probe/freeze-probe.sh                 # espera o dota2 e grava
#   sudo ./probe/freeze-probe.sh -n outro_jogo   # outro processo (nome exato)
#   sudo ./probe/freeze-probe.sh -p 12345        # um PID que ja esta rodando
#   sudo ./probe/freeze-probe.sh -t 1000         # so travadas >= 1000 ms
#   sudo ./probe/freeze-probe.sh --check         # so valida o programa e sai
#   ./probe/freeze-probe.sh -V                 # versao (a mesma do monitor)
#
# Instalado pelo install.sh do monitor, vira o comando freeze-probe: os exemplos
# acima valem com "sudo freeze-probe" (ou o caminho completo, se o diretorio
# nao estiver no secure_path do sudo - o install.sh mostra qual usar).
#
# Saida: ~/.monitor/log/<nome>-<AAAAMMDD-HHMMSS>-probe.txt do usuario que
# chamou o sudo (dono do arquivo e ele, nao o root). O horario e o mesmo
# relogio local dos CSVs do monitor e do MangoHud.
#
# Custo: so as chamadas futex/epoll da thread principal sao seguidas o tempo
# todo; o resto (amostras a 99 Hz, chamadas das outras threads, quem acorda)
# so grava algo enquanto uma travada esta em curso.

set -uo pipefail
export LC_ALL=C

SELF_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
BT="$SELF_DIR/freeze.bt"
# So para a suite de testes: um /proc falso e rodar sem root contra mocks.
PROC="${FREEZE_PROBE_PROC:-/proc}"
# Nome com que a pessoa chama a sonda, para a ajuda e as mensagens: o lancador
# instalado pelo install.sh define FREEZE_PROBE_CMD; direto do repositorio, e o $0.
PROG="${FREEZE_PROBE_CMD:-$0}"
ARGS=("$@")

NAME="dota2"
PID=""
THR_MS=500
OUT_DIR=""
CHECK=0

die() { printf 'erro: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1" >&2; }

# A ajuda e o bloco "Uso:" do cabecalho, com o nome trocado pelo que a pessoa
# usou (PROG): "sudo freeze-probe ..." quando instalado.
usage() {
  sed -n '/^# Uso:/,/^# Saida:/{/^# Saida:/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" \
    | sed "s#\./probe/freeze-probe\.sh#$PROG#"
}

# A versao e a do monitor, do qual a sonda faz parte: lida do monitor.sh um
# nivel acima (no repositorio e na instalacao, que copia o probe/ ao lado dele).
version() {
  local v
  v=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SELF_DIR/../monitor.sh" 2>/dev/null)
  printf 'freeze-probe (monitor %s)\n' "${v:-?}"
}

while (( $# )); do
  case "$1" in
    -n|--name)    NAME="${2:?}"; shift 2 ;;
    -p|--pid)     PID="${2:?}"; shift 2 ;;
    -t|--thresh)  THR_MS="${2:?}"; shift 2 ;;
    -o|--out)     OUT_DIR="${2:?}"; shift 2 ;;
    --check)      CHECK=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -V|--version) version; exit 0 ;;
    *)            die "opcao desconhecida: $1 (veja -h)" ;;
  esac
done

[[ "$THR_MS" =~ ^[0-9]+$ ]] && (( THR_MS >= 50 )) || die "limiar invalido: $THR_MS (ms, minimo 50)"
[[ -z "$PID" || "$PID" =~ ^[0-9]+$ ]] || die "PID invalido: $PID"
(( EUID == 0 )) || [[ "${FREEZE_PROBE_ALLOW_USER:-}" == 1 ]] || die "precisa de root: sudo $PROG ${ARGS[*]}"
command -v bpftrace >/dev/null 2>&1 || die "bpftrace nao encontrado (sudo apt install bpftrace)"
[[ -r "$BT" ]] || die "nao achei $BT"

# --check: compila e prende todas as sondas no proprio shell, sem rodar nada.
# Pega erro de sintaxe e tracepoint inexistente antes de ir jogar.
if (( CHECK )); then
  info "validando $BT com bpftrace $(bpftrace --version 2>/dev/null | awk '{print $2}')..."
  if bpftrace --dry-run "$BT" "$$" "$THR_MS"; then
    info "ok: o programa compila e todas as sondas prendem."
    exit 0
  fi
  die "o bpftrace recusou o programa (mensagem acima)"
fi

# O arquivo vai para o usuario que chamou o sudo, como os CSVs do monitor.
RUN_USER="${SUDO_USER:-root}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
[[ -n "$RUN_HOME" ]] || die "nao achei a home de $RUN_USER"
OUT_DIR="${OUT_DIR:-$RUN_HOME/.monitor/log}"
install -d -o "$RUN_USER" -g "$(id -gn "$RUN_USER")" "$OUT_DIR" || die "nao consegui criar $OUT_DIR"

# --- espera o processo ------------------------------------------------------
if [[ -z "$PID" ]]; then
  info "esperando o processo \"$NAME\" (Ctrl+C cancela)..."
  while :; do
    # O mais antigo com esse nome e o processo do jogo; filhos com o mesmo
    # nome, se houver, vem depois.
    PID="$(pgrep -o -x "$NAME" 2>/dev/null)" && break
    sleep 2
  done
fi
[[ -d "$PROC/$PID" ]] || die "o processo $PID nao existe"
NAME="$(cat "$PROC/$PID/comm" 2>/dev/null || echo "$NAME")"

OUT="$OUT_DIR/${NAME}-$(date +%Y%m%d-%H%M%S)-probe.txt"
: > "$OUT" && chown "$RUN_USER:$(id -gn "$RUN_USER")" "$OUT" || die "nao consegui criar $OUT"
info "processo $PID ($NAME); gravando em $OUT"

{
  printf '# freeze-probe  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '# kernel %s  bpftrace %s\n' "$(uname -r)" "$(bpftrace --version 2>/dev/null | awk '{print $2}')"
  printf '# processo pid=%s nome=%s limiar=%sms\n' "$PID" "$NAME" "$THR_MS"
  printf '# threads no inicio (tid nome):\n'
  for t in "$PROC/$PID"/task/*; do
    printf '#   %s %s\n' "${t##*/}" "$(cat "$t/comm" 2>/dev/null)"
  done
} >> "$OUT"

# --- traducao do epoll --------------------------------------------------------
# O epoll devolve so o cookie "data" que o programa registrou. O fdinfo do
# descritor do epoll lista, para cada fd vigiado, o mesmo cookie: com isso a
# linha "primeiro_evento" vira "era o fd N, que e um eventfd/socket/...".
# Lido como root na hora, com o jogo vivo, uma vez por epfd: o conjunto
# vigiado da principal nao muda durante a partida.
declare -A EP_SEEN=()
dump_epoll() {
  local epfd="$1" tag="$2" line tfd tgt
  local info="$PROC/$PID/fdinfo/$epfd"
  [[ -r "$info" ]] || { printf '# epfd=%s: fdinfo indisponivel\n' "$epfd"; return; }
  printf '# epfd=%s (%s): fds vigiados (tfd, eventos, data, alvo)\n' "$epfd" "$tag"
  while read -r line; do
    [[ "$line" == tfd:* ]] || continue
    tfd="$(awk '{print $2}' <<<"$line")"
    tgt="$(readlink "$PROC/$PID/fd/$tfd" 2>/dev/null || echo '?')"
    printf '#   %s  -> %s\n' "$line" "$tgt"
  done < "$info"
}

# --- bibliotecas do processo ----------------------------------------------------
# As bibliotecas do jogo nao tem simbolos de depuracao, entao o bpftrace imprime
# boa parte da pilha como "0x7ace46bc165b ([unknown])". Com o mapa de memoria do
# processo esses enderecos viram "libanimationsystem.so+0x12b65b". O mapa so
# pode ser lido com o jogo vivo, e bibliotecas sao carregadas ao longo da
# partida (a do mapa so entra ao carregar a partida): e regravado a cada 30 s e
# a cada travada. So os trechos executaveis com arquivo interessam.
MAPS="${OUT%.txt}.maps"
snapshot_maps() {
  local tmp="$MAPS.tmp"
  awk '$2 ~ /x/ && $6 ~ /^\// { print $1, $3, $6 }' "$PROC/$PID/maps" > "$tmp" 2>/dev/null \
    && [[ -s "$tmp" ]] && mv -f "$tmp" "$MAPS" || rm -f "$tmp"
}

# Reescreve o arquivo da sonda trocando cada "0x<end> ([unknown])" por
# "<biblioteca>+0x<deslocamento> ([unknown])". Aritmetica em ponto flutuante do
# awk: enderecos de usuario tem 47 bits, cabem exatos num double (53 bits).
resolve_unknown() {
  [[ -s "$MAPS" && -s "$OUT" ]] || return 0
  local tmp="$OUT.tmp"
  awk '
    function hex(s,   i, c, v) {
      s = tolower(s); sub(/^0x/, "", s); v = 0
      for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c }
      return v
    }
    function tohex(v,   s, d) {
      if (v == 0) return "0"; s = ""
      while (v > 0) { d = v % 16; s = substr("0123456789abcdef", d + 1, 1) s; v = (v - d) / 16 }
      return s
    }
    FNR == NR {
      split($1, r, "-"); n++; lo[n] = hex(r[1]); hi[n] = hex(r[2]); fo[n] = hex($2)
      lib[n] = $3; sub(/.*\//, "", lib[n]); next
    }
    /^\t[0-9a-f]+ 0x[0-9a-f]+ \(\[unknown\]\)$/ {
      a = hex($1)
      for (i = 1; i <= n; i++) if (a >= lo[i] && a < hi[i]) {
        printf "\t%s %s+0x%s ([unknown])\n", $1, lib[i], tohex(a - lo[i] + fo[i]); next
      }
    }
    { print }
  ' "$MAPS" "$OUT" > "$tmp" && mv -f "$tmp" "$OUT" || rm -f "$tmp"
  chown "$RUN_USER:$(id -gn "$RUN_USER")" "$OUT" "$MAPS" 2>/dev/null
}

handle_output() {
  local line epfd
  while IFS= read -r line; do
    printf '%s\n' "$line"
    [[ "$line" == "=== TRAVADA"* ]] && snapshot_maps
    if [[ "$line" =~ ^primeiro_evento:\ epfd=([0-9]+) || "$line" =~ ^principal:\ epoll\ epfd=([0-9]+) ]]; then
      epfd="${BASH_REMATCH[1]}"
      if [[ -z "${EP_SEEN[$epfd]:-}" ]]; then
        EP_SEEN[$epfd]=1
        dump_epoll "$epfd" "primeira vez"
      fi
    fi
  done
}

# --- roda a sonda -------------------------------------------------------------
snapshot_maps
# -B line: cada linha sai na hora (o arquivo acompanha a partida em tempo real).
# env --default-signal=INT: job em segundo plano de script nasce com o SIGINT
# ignorado; isto o devolve ao padrao, para o INT do stop_probe chegar.
env --default-signal=INT bpftrace -B line "$BT" "$PID" "$THR_MS" 2>&1 | handle_output >> "$OUT" &
PIPE_PID=$!
tick=0

# O bpftrace roda o END (resumo) com SIGINT; se nao sair em 5 s, TERM.
stop_probe() {
  local pat="bpftrace -B line $BT $PID" i
  pkill -INT -f "$pat" 2>/dev/null
  for (( i = 0; i < 50; i++ )); do
    pgrep -f "$pat" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  pkill -TERM -f "$pat" 2>/dev/null
}
trap 'info "interrompido; fechando a sonda..."; stop_probe' INT TERM

# Acompanha o jogo: quando ele fecha, encerra a sonda (o END imprime o resumo).
while kill -0 "$PID" 2>/dev/null && kill -0 "$PIPE_PID" 2>/dev/null; do
  sleep 1
  (( ++tick % 30 == 0 )) && snapshot_maps
done
stop_probe
wait "$PIPE_PID" 2>/dev/null
resolve_unknown

n=$(grep -c '^=== TRAVADA' "$OUT" 2>/dev/null)
info "fim: ${n:-0} travadas registradas em $OUT"
