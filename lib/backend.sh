# shellcheck shell=bash
#
# backend.sh - contrato entre o gpu-monitor e cada fabricante de GPU.
#
# Um backend e um arquivo em lib/backends/<nome>.sh que define as funcoes
# abaixo com o prefixo do proprio nome. O carregador confere se todas existem
# antes de aceitar o backend, entao um arquivo incompleto falha na hora de
# carregar, com a lista do que falta - e nao no meio de uma coleta.
#
# ---------------------------------------------------------------------------
# CONTRATO
# ---------------------------------------------------------------------------
#
# Toda funcao abaixo e obrigatoria. As de coleta recebem por variavel global
# o que ja foi resolvido (GPU_IDX, INTERVAL, INTERVAL_MS, DURATION, OUTPUT,
# PROCS_OUT, PROCS_MODE e os FILTER_*), e devem usar run_source para lancar
# processos externos - ver o comentario do exec em core.sh.
#
#   <be>_probe
#     Diz se este backend consegue rodar nesta maquina. Sem efeitos colaterais,
#     sem escrever nada, sem falar na tela. Retorna 0 se sim, 1 se nao.
#     E chamado durante a autodeteccao, entao precisa ser rapido e silencioso.
#
#   <be>_name
#     Imprime o nome legivel do fabricante ("NVIDIA", "AMD", "Intel"). Usado em
#     mensagens e no banner.
#
#   <be>_init
#     Prepara o que a coleta precisa: conferir o driver, resolver o alvo de
#     --gpu, montar os mapas de indice/nome. Chamado uma vez, antes de qualquer
#     coleta. Deve chamar die() com uma mensagem util se algo faltar.
#     Preenche GPU_COUNT com quantas GPUs foram encontradas.
#
#   <be>_supports_procs
#     Diz se este backend sabe atribuir VRAM a processos. Retorna 0 se sim,
#     1 se nao. Um backend pode coletar metricas da placa sem saber quem
#     consome a memoria - e o caso de varias GPUs fora da NVIDIA. Quando
#     retorna 1, o subcomando "proc" e recusado com uma mensagem explicativa
#     em vez de gerar um CSV vazio.
#
#   <be>_start_gpu
#     Lanca a coleta de metricas da placa. Escreve em $OUTPUT uma linha por GPU
#     por amostra, no formato de GPU_CSV_HEADER (ver csv.sh), e guarda os PIDs
#     que criar em GPU_SRC_PID (produtor) e GPU_AWK_PID (consumidor), para o
#     stop()/cleanup() do core saber o que encerrar.
#
#   <be>_start_proc
#     Lanca a coleta de VRAM por processo. Escreve em $PROCS_OUT no formato de
#     PROCS_CSV_HEADER, respeitando PROCS_MODE e os filtros. Guarda os PIDs em
#     PROC_SRC_PID e PROC_AWK_PID. So e chamada se <be>_supports_procs der 0.
#
#   <be>_list_procs
#     Imprime, um por linha, o nome dos processos com contexto na GPU agora.
#     Usada so para a dica quando um --filter nao casa com nada. Pode imprimir
#     nada se o backend nao souber responder.
#
# ---------------------------------------------------------------------------
# COLUNAS
# ---------------------------------------------------------------------------
#
# Todo backend escreve as mesmas colunas, na mesma ordem - e o que permite
# juntar coletas de maquinas diferentes no mesmo grafico. Metrica que o
# hardware nao reporta vira celula vazia, nunca "N/A" nem zero: zero e um
# valor medido, vazio e a ausencia de medida. As colunas opcionais existem
# porque nem toda GPU expoe tudo (uma APU AMD costuma nao ter power_w, e
# nem todo modelo reporta mem_util_pct).

# Funcoes que todo backend precisa definir, conferidas no carregamento.
BACKEND_REQUIRED_FUNCS=(
  probe
  name
  init
  supports_procs
  start_gpu
  start_proc
  list_procs
)

# Ordem da autodeteccao. O primeiro cujo _probe aceitar e o escolhido, entao a
# ordem importa numa maquina hibrida: a NVIDIA vem primeiro por ser a unica que
# hoje atribui VRAM por processo.
BACKEND_ORDER=(nvidia amd intel)

BACKEND=""        # nome do backend em uso, preenchido por backend_load
GPU_COUNT=0       # quantas GPUs o backend encontrou, preenchido por <be>_init

# PIDs dos processos lancados pelos backends. O core encerra por estes nomes,
# entao um backend novo so precisa preenche-los.
GPU_SRC_PID=""; GPU_AWK_PID=""
PROC_SRC_PID=""; PROC_AWK_PID=""

# Chama uma funcao do backend em uso: backend_call start_gpu -> nvidia_start_gpu
backend_call() {
  local fn="$1"; shift
  "${BACKEND}_${fn}" "$@"
}

# Carrega um backend pelo nome e confere o contrato. Falhar aqui, com a lista
# do que falta, e melhor do que descobrir a funcao ausente no meio da coleta.
backend_load() {
  # Em declaracoes separadas: num unico "local", o $be do lado direito ainda
  # seria o de fora do escopo (ou nada, sob set -u).
  local be="$1"
  local file="$LIB_DIR/backends/$be.sh"
  local fn missing=()

  [[ -r "$file" ]] || die "backend desconhecido: $be (procurei em $file)"
  # shellcheck source=/dev/null
  . "$file" || die "nao consegui carregar o backend $be"

  for fn in "${BACKEND_REQUIRED_FUNCS[@]}"; do
    declare -F "${be}_${fn}" >/dev/null || missing+=("${be}_${fn}")
  done
  (( ${#missing[@]} == 0 )) \
    || die "o backend $be nao implementa: ${missing[*]}"

  BACKEND="$be"
}

# Descobre qual backend serve para esta maquina. Carrega cada candidato so para
# perguntar ao _probe, na ordem de BACKEND_ORDER.
backend_detect() {
  local be
  for be in "${BACKEND_ORDER[@]}"; do
    [[ -r "$LIB_DIR/backends/$be.sh" ]] || continue
    # shellcheck source=/dev/null
    . "$LIB_DIR/backends/$be.sh" 2>/dev/null || continue
    declare -F "${be}_probe" >/dev/null || continue
    if "${be}_probe"; then
      backend_load "$be"
      return 0
    fi
  done
  return 1
}

# Lista os backends disponiveis, para a mensagem de erro e para --help.
backend_list() {
  local f be
  for f in "$LIB_DIR"/backends/*.sh; do
    [[ -r "$f" ]] || continue
    be="${f##*/}"; be="${be%.sh}"
    printf '%s\n' "$be"
  done
}
