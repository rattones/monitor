#!/usr/bin/env bash
#
# monitor.sh - amostra o uso da GPU (incluindo VRAM), a VRAM por processo, o
# I/O/temperatura dos discos e a CPU/memoria do sistema, gravando um CSV para
# cada um.
#
# Os quatro coletores sao independentes e escolhidos por subcomando:
#
#   ./monitor.sh            # all: os quatro (padrao)
#   ./monitor.sh gpu        # so as metricas da GPU
#   ./monitor.sh disk       # so o I/O de disco
#   ./monitor.sh proc       # so a VRAM por processo
#   ./monitor.sh sys        # so CPU, memoria, PSI e as threads do alvo
#
# O codigo mora em lib/: cada modulo cuida de uma coisa, e o que e especifico de
# um fabricante de GPU fica em lib/backends/<nome>.sh, atras do contrato descrito
# em lib/backend.sh. Hoje so o backend NVIDIA coleta; AMD e Intel sao esqueletos.

set -uo pipefail

VERSION="3.7"

# readlink -f resolve a cadeia de symlinks ate o arquivo real: instalado, o
# comando em /usr/local/bin e um link, e sem isto o lib/ seria procurado ao
# lado do link, onde nao existe. LIB_DIR pode vir do ambiente para uma
# instalacao que separe o executavel das bibliotecas (ex.: /usr/lib/monitor).
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
LIB_DIR="${MONITOR_LIB_DIR:-$SCRIPT_DIR/lib}"

# A ordem importa: i18n.sh vem primeiro porque o die() de core.sh usa msg();
# core.sh define esse die(), que todos os outros usam; e backend.sh define o
# backend_call() de que filter.sh e report.sh dependem.
for _m in i18n core backend csv filter args disk sys perf report; do
  # shellcheck source=/dev/null
  . "$LIB_DIR/$_m.sh" || { printf 'error: could not load lib/%s.sh\n' "$_m" >&2; exit 1; }
done
unset _m

# Carrega o catalogo do idioma detectado antes de qualquer mensagem sair.
i18n_init

usage() { usage_text; }

# Escolhe o backend: o pedido em --backend, ou o primeiro que a autodeteccao
# aceitar. So os coletores de GPU precisam disso - um "disk" puro roda numa
# maquina sem GPU nenhuma, e por isso a escolha acontece aqui e nao no inicio.
setup_backend() {
  if [[ -n "$GPU_BACKEND" ]]; then
    backend_load "$GPU_BACKEND"
  else
    backend_detect || die "$(msg backend_none_detected "$(backend_list | paste -sd' ')")"
  fi

  backend_call init

  # Um backend que nao sabe atribuir VRAM por processo deve dizer isso antes da
  # coleta, em vez de gerar um CSV com so o cabecalho. Pedido explicito ("proc")
  # e recusado; no "all" o coletor so sai da lista, para os outros continuarem -
  # e o caso do gancho de jogo, que chama "all" sem saber qual driver esta ativo.
  if (( WANT_PROC )) && ! backend_call supports_procs; then
    [[ "$CMD" == all ]] || die "$(msg backend_no_procs "$(backend_call name)")"
    WANT_PROC=0
    (( QUIET )) || msg backend_procs_skipped "$(backend_call name)" >&2
  fi
}

main() {
  parse_args "$@"
  resolve_targets
  validate_args

  (( WANT_GPU || WANT_PROC )) && setup_backend
  (( WANT_DISK )) && resolve_disks
  (( WANT_SYS ))  && resolve_sys
  (( PERF_ON ))   && resolve_perf

  setup_outputs

  trap cleanup EXIT
  trap stop INT TERM

  print_banner

  (( WANT_GPU ))  && backend_call start_gpu
  (( WANT_PROC )) && backend_call start_proc
  (( WANT_DISK )) && start_disk
  (( WANT_SYS ))  && start_sys
  (( PERF_ON ))   && start_perf

  # Os awks rodam em background e o shell espera: assim um sinal e tratado na
  # hora, em vez de ficar pendurado ate um pipeline em foreground terminar.
  wait_for "$GPU_AWK_PID";  GPU_AWK_PID=""
  wait_for "$PROC_AWK_PID"; PROC_AWK_PID=""
  wait_for "$DISK_PID";     DISK_PID=""
  wait_for "$SYS_PID";      SYS_PID=""
  wait_for "$PERF_PID";     PERF_PID=""

  [[ -n "$GPU_SRC_PID"  ]] && { wait "$GPU_SRC_PID"  2>/dev/null; GPU_SRC_PID=""; }
  [[ -n "$PROC_SRC_PID" ]] && { wait "$PROC_SRC_PID" 2>/dev/null; PROC_SRC_PID=""; }

  (( WANT_GPU )) && backend_try report_gpu
  (( WANT_PROC )) && warn_empty_filter
  (( ! QUIET && WANT_PROC )) && summarize_proc
  (( ! QUIET && WANT_DISK )) && summarize_disk
  (( ! QUIET && WANT_SYS ))  && summarize_sys

  print_footer
  return 0
}

main "$@"
