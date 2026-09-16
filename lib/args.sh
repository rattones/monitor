# shellcheck shell=bash
#
# args.sh - subcomando, opcoes e validacao.

CMD="all"         # all | gpu | disk | proc
INTERVAL=1        # segundos entre amostras
DURATION=0        # 0 = roda ate Ctrl+C
OUTPUT=""         # padrao: logs/gpu-<data>.csv
GPU_IDX=""        # padrao: todas as GPUs
QUIET=0
PROCS_MODE="all"  # all | compute | off
TOP_N=5           # quantos processos no resumo final
DISK_MODE="all"   # all | off | lista de dispositivos
GPU_BACKEND=""    # vazio = autodeteccao

WANT_GPU=0; WANT_DISK=0; WANT_PROC=0
INTERVAL_MS=0

parse_args() {
  # O subcomando, quando existe, vem primeiro. Sem ele o padrao e "all", para
  # nao quebrar quem ja chama o script so com opcoes.
  case "${1-}" in
    all|gpu|disk|proc) CMD="$1"; shift ;;
  esac

  # "$1" e o nome da opcao; exigir o valor aqui evita o loop infinito de um
  # "shift 2" que nao desloca nada quando a opcao e o ultimo argumento.
  local need='[[ $# -ge 2 ]] || die "a opcao $1 exige um valor"'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--interval) eval "$need"; INTERVAL="$2"; shift 2 ;;
      -d|--duration) eval "$need"; DURATION="$2"; shift 2 ;;
      -o|--output)   eval "$need"; OUTPUT="$2";   shift 2 ;;
      -g|--gpu)      eval "$need"; GPU_IDX="$2";  shift 2 ;;
      -p|--procs)    eval "$need"; PROCS_MODE="$2"; shift 2 ;;
      -D|--disk)     eval "$need"; DISK_MODE="$2";  shift 2 ;;
      -f|--filter)   eval "$need"; add_filter "$2"; shift 2 ;;
      -t|--top)      eval "$need"; TOP_N="$2";    shift 2 ;;
      -b|--backend)  eval "$need"; GPU_BACKEND="$2"; shift 2 ;;
      -q|--quiet)    QUIET=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      -V|--version)  printf 'gpu-monitor %s\n' "$VERSION"; exit 0 ;;
      all|gpu|disk|proc) die "o subcomando deve vir antes das opcoes: ${0##*/} $1 ..." ;;
      *) die "opcao desconhecida: $1 (use --help)" ;;
    esac
  done
}

# Traduz subcomando + modos para os tres interruptores que o resto do script usa.
# -p off e -D off continuam valendo dentro de "all", entao ha duas formas de
# desligar um coletor: nao pedi-lo no subcomando, ou desliga-lo pela opcao.
resolve_targets() {
  case "$CMD" in
    all)  WANT_GPU=1; WANT_DISK=1; WANT_PROC=1 ;;
    gpu)  WANT_GPU=1 ;;
    disk) WANT_DISK=1 ;;
    proc) WANT_PROC=1 ;;
  esac
  [[ "$PROCS_MODE" == off ]] && WANT_PROC=0
  [[ "$DISK_MODE"  == off ]] && WANT_DISK=0

  # Um subcomando cujo unico coletor foi desligado pela opcao nao coletaria
  # nada: melhor dizer isso do que criar um CSV vazio.
  (( WANT_GPU || WANT_DISK || WANT_PROC )) \
    || die "nada a coletar: o subcomando \"$CMD\" foi desligado por --procs/--disk off"
}

validate_args() {
  [[ "$INTERVAL" =~ ^[0-9]*\.?[0-9]+$ ]] || die "intervalo invalido: $INTERVAL"
  [[ "$DURATION" =~ ^[0-9]*\.?[0-9]+$ ]] || die "duracao invalida: $DURATION"
  [[ -z "$GPU_IDX" || "$GPU_IDX" =~ ^[0-9]+$ ]] || die "indice de GPU invalido: $GPU_IDX"
  [[ "$TOP_N" =~ ^[0-9]+$ ]] || die "valor invalido para --top: $TOP_N"

  case "$PROCS_MODE" in
    all|compute|off) ;;
    *) die "modo invalido para --procs: $PROCS_MODE (use all, compute ou off)" ;;
  esac

  if [[ -n "$FILTER_RAW" ]] && (( ! WANT_PROC )); then
    die "--filter so faz sentido com a coleta de processos ativa"
  fi

  INTERVAL_MS=$(LC_ALL=C awk -v i="$INTERVAL" 'BEGIN { printf "%d", i * 1000 }')
  (( INTERVAL_MS >= 100 )) || die "intervalo minimo e 0.1s"
}
