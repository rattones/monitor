# shellcheck shell=bash
#
# filter.sh - alvos de -f/--filter.
#
# O parsing acontece aqui, no shell; a comparacao acontece dentro do awk de
# cada backend, que recebe FILTER_PIDS/FILTER_NAMES/FILTER_CMDS como strings
# delimitadas por ";". Esse formato existe para o awk poder testar um alvo com
# index() em vez de percorrer um array a cada linha.

FILTER_RAW=""     # como o usuario escreveu, so para exibir
FILTER_PIDS=""    # ";1598;2951;" - delimitado, para busca exata por PID
FILTER_NAMES=""   # ";chrome;xorg;" - minusculas, para busca no nome do executavel
FILTER_CMDS=""    # subconjunto dos alvos que so fazem sentido na linha completa

# Acumula alvos de -f/--filter. PIDs viram uma string delimitada por ";" para
# comparacao exata; nomes vao em minusculas, para casar por trecho no awk.
add_filter() {
  local raw="${1-}" item kind
  [[ -n "$raw" ]] || die "$(msg filter_needs_target)"
  FILTER_RAW="${FILTER_RAW:+$FILTER_RAW,}$raw"

  local IFS=,
  for item in $raw; do
    item="$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$item" ]] || continue

    kind=auto
    case "$item" in
      pid:*)  kind=pid;  item="${item#pid:}" ;;
      name:*) kind=name; item="${item#name:}" ;;
    esac
    [[ -n "$item" ]] || die "$(msg filter_empty_target)"

    if [[ "$kind" == auto ]]; then
      [[ "$item" =~ ^[0-9]+$ ]] && kind=pid || kind=name
    fi

    if [[ "$kind" == pid ]]; then
      [[ "$item" =~ ^[0-9]+$ ]] || die "$(msg filter_bad_pid "$item")"
      FILTER_PIDS="${FILTER_PIDS:-;}$item;"
      continue
    fi

    # Um alvo com caminho ou com argumentos nunca casaria so com o nome do
    # executavel: e comparado tambem com a linha de comando inteira. A tabela
    # do nvidia-smi abrevia nomes longos com reticencias, entao um alvo colado
    # de la ("...rack-uuid=123") vale pelo trecho que sobrou.
    local wide=0
    case "$item" in
      ...*) item="${item#...}"; wide=1 ;;
    esac
    case "$item" in
      *...) item="${item%...}"; wide=1 ;;
    esac
    [[ -n "$item" ]] || die "$(msg filter_empty_target)"
    case "$item" in
      */*|*' '*) wide=1 ;;
    esac

    item="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')"
    FILTER_NAMES="${FILTER_NAMES:-;}$item;"
    (( wide )) && FILTER_CMDS="${FILTER_CMDS:-;}$item;"
  done
}

# Um filtro que nao casou com nada gera um CSV so com cabecalho, o que parece
# coleta quebrada: avisa e mostra quem estava na GPU, para corrigir o alvo.
# Quem sabe responder "quem esta na GPU agora" e o backend.
warn_empty_filter() {
  [[ -n "$FILTER_RAW" ]] || return 0
  (( $(wc -l < "$PROCS_OUT") <= PROCS_SKIP )) || return 0

  printf '\naviso: nenhum processo casou com o filtro "%s".\n' "$FILTER_RAW" >&2
  local seen
  seen=$(backend_call list_procs 2>/dev/null | sort -u | paste -sd" ")
  [[ -n "$seen" ]] && printf 'processos na GPU agora: %s\n' "$seen" >&2
  return 0
}
