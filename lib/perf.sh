# shellcheck shell=bash
#
# perf.sh - amostragem de pilhas (perf record) dos PIDs-alvo, opcional (-P).
#
# O CSV de threads diz QUAL thread girou e em qual estado; o perf diz ONDE ela
# girou: em qual biblioteca e funcao. Numa thread a 100% com a GPU parada, e
# isso que separa "o jogo preso num laco" de "o driver de video esperando
# ativamente por algo" - o que o /proc sozinho nao consegue mostrar.
#
# Grava dois arquivos:
#
#   <saida>-perf.data    as amostras, comprimidas (-z)
#   <saida>-perf.log     o que o perf imprimiu
#
# Por que -k CLOCK_MONOTONIC: com um clockid explicito o perf grava no proprio
# perf.data a referencia de horario real ("clock data" no cabecalho), e o
# "perf script -F tod" passa a mostrar a hora de cada amostra. E essa a ponte
# para o horario dos CSVs - sem ela, o shell nao tem como ler o monotonico. O
# CLOCK_BOOTTIME seria o ideal (e o do /proc/uptime que o sys.sh usa), mas o
# kernel recusa esse clockid para eventos de hardware.
#
# Frequencia baixa por padrao (49 Hz): um jogo ocupa varios nucleos por horas,
# e com pilha completa isso vira centenas de MB. Para achar uma thread que
# gira por segundos, 49 amostras por segundo sobram.

PERF_PID=""
PERF_PIDS=""          # "123;456" - PIDs de -f pid:N
PERF_FREQ="${MONITOR_PERF_FREQ:-49}"

resolve_perf() {
  PERF_PIDS="${FILTER_PIDS#;}"; PERF_PIDS="${PERF_PIDS%;}"
  [[ -n "$PERF_PIDS" ]] || die "$(msg perf_needs_pid)"
  command -v perf >/dev/null 2>&1 || die "$(msg perf_not_found)"
  [[ "$PERF_FREQ" =~ ^[0-9]+$ ]] && (( PERF_FREQ > 0 )) \
    || die "$(msg sys_bad_env MONITOR_PERF_FREQ "$PERF_FREQ")"

  # Sem root, o perf so acompanha processos do proprio usuario com
  # perf_event_paranoid <= 1. O padrao do Ubuntu e 4, e ai o record falharia
  # com uma mensagem longa e pouco clara - melhor dizer o que fazer antes.
  # PROC_ROOT vem do sys.sh: a suite aponta para um /proc falso.
  if (( EUID != 0 )); then
    local paranoid
    paranoid=$(cat "$PROC_ROOT/sys/kernel/perf_event_paranoid" 2>/dev/null || echo 4)
    (( paranoid <= 1 )) || die "$(msg perf_paranoid "$paranoid")"
  fi
}

start_perf() {
  # SIGINT, e nao o TERM padrao do timeout: e o sinal com que o perf fecha o
  # arquivo direito. -p segue as threads que o alvo criar depois (inherit).
  (
    if LC_ALL=C awk -v d="$DURATION" 'BEGIN { exit !(d > 0) }'; then
      exec timeout -s INT "$DURATION" perf record -F "$PERF_FREQ" -g -z -k CLOCK_MONOTONIC \
        -p "${PERF_PIDS//;/,}" -o "$PERF_OUT"
    else
      exec perf record -F "$PERF_FREQ" -g -z -k CLOCK_MONOTONIC \
        -p "${PERF_PIDS//;/,}" -o "$PERF_OUT"
    fi
  ) > "$PERF_LOG" 2>&1 &
  PERF_PID=$!
}
