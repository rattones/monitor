# shellcheck shell=bash
#
# args.sh - subcomando, opcoes e validacao.

CMD="all"         # all | gpu | disk | proc | sys
INTERVAL_MS=500   # milissegundos entre amostras - a unidade de -i
DURATION=0        # 0 = roda ate Ctrl+C
OUTPUT=""         # padrao: logs/monitor-<data>.csv
GPU_IDX=""        # padrao: todas as GPUs
QUIET=0
PROCS_MODE="all"  # all | compute | off
TOP_N=5           # quantos processos no resumo final
DISK_MODE="all"   # all | off | lista de dispositivos
SYS_MODE="all"    # all | off
PERF_ON=0         # -P: perf record nos PIDs de -f
GPU_BACKEND=""    # vazio = autodeteccao

WANT_GPU=0; WANT_DISK=0; WANT_PROC=0; WANT_SYS=0

# O intervalo em segundos, derivado de INTERVAL_MS. Quem cadencia por sleep
# (o awk do disco) precisa de segundos com fracao; quem passa o valor adiante
# (o -lms do nvidia-smi) usa INTERVAL_MS direto.
INTERVAL_S=""

parse_args() {
  # O subcomando, quando existe, vem primeiro. Sem ele o padrao e "all", para
  # nao quebrar quem ja chama o script so com opcoes.
  case "${1-}" in
    all|gpu|disk|proc|sys) CMD="$1"; shift ;;
  esac

  # "$1" e o nome da opcao; exigir o valor aqui evita o loop infinito de um
  # "shift 2" que nao desloca nada quando a opcao e o ultimo argumento.
  local need='[[ $# -ge 2 ]] || die "$(msg args_need_value "$1")"'

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--interval) eval "$need"; INTERVAL_MS="$2"; shift 2 ;;
      -d|--duration) eval "$need"; DURATION="$2"; shift 2 ;;
      -o|--output)   eval "$need"; OUTPUT="$2";   shift 2 ;;
      -g|--gpu)      eval "$need"; GPU_IDX="$2";  shift 2 ;;
      -p|--procs)    eval "$need"; PROCS_MODE="$2"; shift 2 ;;
      -D|--disk)     eval "$need"; DISK_MODE="$2";  shift 2 ;;
      -S|--sys)      eval "$need"; SYS_MODE="$2";   shift 2 ;;
      -P|--perf)     PERF_ON=1; shift ;;
      -f|--filter)   eval "$need"; add_filter "$2"; shift 2 ;;
      -t|--top)      eval "$need"; TOP_N="$2";    shift 2 ;;
      -b|--backend)  eval "$need"; GPU_BACKEND="$2"; shift 2 ;;
      -q|--quiet)    QUIET=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      -V|--version)  printf 'monitor %s\n' "$VERSION"; exit 0 ;;
      all|gpu|disk|proc|sys) die "$(msg args_subcmd_order "${0##*/}" "$1")" ;;
      *) die "$(msg args_unknown_opt "$1")" ;;
    esac
  done
}

# Traduz subcomando + modos para os interruptores que o resto do script usa.
# -p off e -D off continuam valendo dentro de "all", entao ha duas formas de
# desligar um coletor: nao pedi-lo no subcomando, ou desliga-lo pela opcao.
resolve_targets() {
  case "$CMD" in
    all)  WANT_GPU=1; WANT_DISK=1; WANT_PROC=1; WANT_SYS=1 ;;
    gpu)  WANT_GPU=1 ;;
    disk) WANT_DISK=1 ;;
    proc) WANT_PROC=1 ;;
    sys)  WANT_SYS=1 ;;
  esac
  [[ "$PROCS_MODE" == off ]] && WANT_PROC=0
  [[ "$DISK_MODE"  == off ]] && WANT_DISK=0
  [[ "$SYS_MODE"   == off ]] && WANT_SYS=0

  # Um subcomando cujo unico coletor foi desligado pela opcao nao coletaria
  # nada: melhor dizer isso do que criar um CSV vazio.
  (( WANT_GPU || WANT_DISK || WANT_PROC || WANT_SYS )) \
    || die "$(msg args_nothing_to_collect "$CMD")"
}

validate_args() {
  # -i e em milissegundos inteiros. Um valor fracionario quase sempre significa
  # que a pessoa esperava segundos ("-i 0.5"), entao a mensagem sugere a
  # traducao em vez de so recusar o formato.
  if [[ "$INTERVAL_MS" =~ ^[0-9]*\.[0-9]+$ ]]; then
    local as_ms
    as_ms=$(LC_ALL=C awk -v v="$INTERVAL_MS" 'BEGIN { printf "%d", v * 1000 }')
    die "$(msg args_interval_ms "$as_ms" "$INTERVAL_MS")"
  fi
  [[ "$INTERVAL_MS" =~ ^[0-9]+$ ]] || die "$(msg args_interval_invalid "$INTERVAL_MS")"
  [[ "$DURATION" =~ ^[0-9]*\.?[0-9]+$ ]] || die "$(msg args_duration_invalid "$DURATION")"
  [[ -z "$GPU_IDX" || "$GPU_IDX" =~ ^[0-9]+$ ]] || die "$(msg args_gpu_idx_invalid "$GPU_IDX")"
  [[ "$TOP_N" =~ ^[0-9]+$ ]] || die "$(msg args_top_invalid "$TOP_N")"

  case "$PROCS_MODE" in
    all|compute|off) ;;
    *) die "$(msg args_procs_mode "$PROCS_MODE")" ;;
  esac

  case "$SYS_MODE" in
    all|off) ;;
    *) die "$(msg args_sys_mode "$SYS_MODE")" ;;
  esac

  # O filtro serve a dois coletores: o de processos filtra a VRAM, o de sistema
  # segue as threads dos PIDs. Sem nenhum dos dois, ele nao teria efeito.
  if [[ -n "$FILTER_RAW" ]] && (( ! WANT_PROC && ! WANT_SYS && ! PERF_ON )); then
    die "$(msg args_filter_needs_procs)"
  fi

  (( INTERVAL_MS >= 100 )) || die "$(msg args_interval_min "$INTERVAL_MS")"

  # Segundos com fracao, para quem cadencia por sleep. LC_ALL=C: num locale
  # pt_BR o %.3f sairia com virgula decimal e o "sleep 0,5" do awk falharia.
  INTERVAL_S=$(LC_ALL=C awk -v ms="$INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')
}
