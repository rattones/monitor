#!/usr/bin/env bash
#
# monitor.sh - amostra o uso da GPU (incluindo VRAM), a VRAM por processo e
# o I/O/temperatura dos discos, gravando um CSV para cada um.
#
# Os tres coletores sao independentes e escolhidos por subcomando:
#
#   ./monitor.sh            # all: os tres (padrao)
#   ./monitor.sh gpu        # so as metricas da GPU
#   ./monitor.sh disk       # so o I/O de disco
#   ./monitor.sh proc       # so a VRAM por processo
#
# O codigo mora em lib/: cada modulo cuida de uma coisa, e o que e especifico de
# um fabricante de GPU fica em lib/backends/<nome>.sh, atras do contrato descrito
# em lib/backend.sh. Hoje so o backend NVIDIA coleta; AMD e Intel sao esqueletos.

set -uo pipefail

VERSION="3.2"

# readlink -f resolve a cadeia de symlinks ate o arquivo real: instalado, o
# comando em /usr/local/bin e um link, e sem isto o lib/ seria procurado ao
# lado do link, onde nao existe. LIB_DIR pode vir do ambiente para uma
# instalacao que separe o executavel das bibliotecas (ex.: /usr/lib/monitor).
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
LIB_DIR="${MONITOR_LIB_DIR:-$SCRIPT_DIR/lib}"

# A ordem importa: core.sh define o die() que os outros usam, e backend.sh
# define o backend_call() de que filter.sh e report.sh dependem.
for _m in core backend csv filter args disk report; do
  # shellcheck source=/dev/null
  . "$LIB_DIR/$_m.sh" || { printf 'erro: nao consegui carregar lib/%s.sh\n' "$_m" >&2; exit 1; }
done
unset _m

usage() {
  cat <<EOF
monitor.sh v$VERSION - monitor de GPU/VRAM, processos e disco, em CSV

Uso: ${0##*/} [subcomando] [opcoes]

Subcomandos:
  all      Coleta GPU, processos e disco (padrao quando nenhum e informado)
  gpu      So as metricas da GPU
  disk     So o I/O e a temperatura dos discos
  proc     So a VRAM atribuida a cada processo

Opcoes comuns:
  -i, --interval MS    Intervalo entre amostras, em milissegundos
                       (padrao: 500; inteiro, minimo 100)
  -d, --duration SEG   Duracao total em segundos (padrao: 0 = ate Ctrl+C)
  -o, --output ARQ     Arquivo CSV de saida
                       (padrao: $LOG_DIR/monitor-AAAAMMDD-HHMMSS.csv)
  -q, --quiet          Nao imprime nada na tela, so grava os CSVs
  -h, --help           Mostra esta ajuda
  -V, --version        Mostra a versao

Opcoes de GPU (subcomandos all, gpu, proc):
  -g, --gpu IDX        Monitora apenas a GPU de indice IDX (padrao: todas)
  -b, --backend NOME   Forca um backend (padrao: autodeteccao)
                       Disponiveis: $(backend_list | paste -sd" ")
                       So NVIDIA coleta hoje; AMD e Intel sao esqueletos.

Opcoes de processos (subcomandos all, proc):
  -p, --procs MODO     Atribuicao de VRAM por processo (padrao: all)
                         all     - processos de compute (C) e graficos (G)
                         compute - so contextos CUDA/compute (C)
                         off     - nao coleta processos
  -f, --filter ALVO    Monitora so estes processos; ALVO e um PID ou um nome,
                       varios separados por virgula, e a opcao pode repetir.
                       So digitos = PID; qualquer outra coisa = nome, que casa
                       por trecho e ignorando maiusculas. O nome e comparado com
                       o executavel e, quando o alvo traz caminho ou argumentos,
                       tambem com a linha de comando inteira.
                         -f chrome                        so o chrome
                         -f chrome,Xorg                   os dois
                         -f 1598 -f python3               PID 1598 e python3
                         -f /opt/google/chrome/chrome     caminho completo
                         -f "python3 train.py"            nome + argumentos
                         -f name:1234                     processo chamado "1234"
                       A virgula separa alvos: para um comando que tenha virgula
                       nos argumentos, filtre por um trecho sem virgula.
  -t, --top N          Quantos processos no resumo final (padrao: 5; 0 desliga)

Opcoes de disco (subcomandos all, disk):
  -D, --disk MODO      Monitora I/O e temperatura de disco (padrao: all)
                         all     - todos os discos fisicos
                         off     - nao coleta disco
                         LISTA   - dispositivos separados por virgula
                                   (ex: -D nvme0n1 ou -D sda,sdb)

Saidas (so os arquivos dos coletores ativos sao criados):
  <saida>.csv          uma linha por GPU por amostra (uso, VRAM, temperatura...)
  <saida>-procs.csv    uma linha por processo por amostra (VRAM atribuida ao PID)
  <saida>-disk.csv     uma linha por disco por amostra (leitura/escrita e temperatura)

Colunas de <saida>.csv:
  timestamp          ISO-8601 local, com milissegundos
  gpu_index          indice da GPU
  gpu_name           nome do modelo
  gpu_util_pct       % de tempo com kernels ativos (ocupacao do nucleo)
  mem_util_pct       % de tempo com o barramento de memoria em uso
  vram_total_mib     VRAM total
  vram_used_mib      VRAM em uso
  vram_free_mib      VRAM livre
  vram_used_pct      VRAM em uso, em % do total
  temp_c             temperatura do nucleo em C
  power_w            consumo em W (vazio se a GPU nao reporta)
  sm_clock_mhz       clock dos SMs
  mem_clock_mhz      clock da memoria

Colunas de <saida>-procs.csv:
  timestamp          ISO-8601 local (resolucao de 1s)
  gpu_index          indice da GPU
  pid                PID do processo
  type               C = compute (CUDA), G = graficos
  process_name       nome do executavel
  used_vram_mib      VRAM atribuida a esse processo

Colunas de <saida>-disk.csv:
  timestamp          ISO-8601 local (resolucao de 1s)
  device             nome do disco (nvme0n1, sda...)
  read_mb_s          leitura no intervalo, em MB/s
  write_mb_s         escrita no intervalo, em MB/s
  read_iops          operacoes de leitura por segundo
  write_iops         escritas por segundo
  util_pct           % de tempo com pelo menos uma requisicao em voo
  temp_c             temperatura do disco (vazio se nao houver sensor)

Uma metrica que o hardware nao reporta vira celula vazia, nunca zero: zero e um
valor medido, vazio e a ausencia de medida.

Os arquivos se juntam pelo segundo do timestamp (e pelo gpu_index, entre os dois
primeiros). A soma de used_vram_mib e menor que vram_used_mib, porque o driver e
o contexto de video tambem reservam memoria fora dos processos. As taxas de disco
sao deltas entre amostras, entao a primeira leitura serve de base e a primeira
linha de <saida>-disk.csv sai um intervalo depois do inicio.

Os CSVs recebem flush a cada amostra, entao podem ser lidos/plotados enquanto
a coleta ainda esta rodando.
EOF
}

# Escolhe o backend: o pedido em --backend, ou o primeiro que a autodeteccao
# aceitar. So os coletores de GPU precisam disso - um "disk" puro roda numa
# maquina sem GPU nenhuma, e por isso a escolha acontece aqui e nao no inicio.
setup_backend() {
  if [[ -n "$GPU_BACKEND" ]]; then
    backend_load "$GPU_BACKEND"
  else
    backend_detect || die "nenhuma GPU reconhecida (backends: $(backend_list | paste -sd' ')) - use --backend para forcar"
  fi

  backend_call init

  # Um backend que nao sabe atribuir VRAM por processo deve dizer isso antes da
  # coleta, em vez de gerar um CSV com so o cabecalho.
  if (( WANT_PROC )) && ! backend_call supports_procs; then
    die "o backend $(backend_call name) nao coleta VRAM por processo (use --procs off ou o subcomando gpu)"
  fi
}

main() {
  parse_args "$@"
  resolve_targets
  validate_args

  (( WANT_GPU || WANT_PROC )) && setup_backend
  (( WANT_DISK )) && resolve_disks

  setup_outputs

  trap cleanup EXIT
  trap stop INT TERM

  print_banner

  (( WANT_GPU ))  && backend_call start_gpu
  (( WANT_PROC )) && backend_call start_proc
  (( WANT_DISK )) && start_disk

  # Os awks rodam em background e o shell espera: assim um sinal e tratado na
  # hora, em vez de ficar pendurado ate um pipeline em foreground terminar.
  wait_for "$GPU_AWK_PID";  GPU_AWK_PID=""
  wait_for "$PROC_AWK_PID"; PROC_AWK_PID=""
  wait_for "$DISK_PID";     DISK_PID=""

  [[ -n "$GPU_SRC_PID"  ]] && { wait "$GPU_SRC_PID"  2>/dev/null; GPU_SRC_PID=""; }
  [[ -n "$PROC_SRC_PID" ]] && { wait "$PROC_SRC_PID" 2>/dev/null; PROC_SRC_PID=""; }

  (( WANT_GPU )) && backend_try report_gpu
  (( WANT_PROC )) && warn_empty_filter
  (( ! QUIET && WANT_PROC )) && summarize_proc
  (( ! QUIET && WANT_DISK )) && summarize_disk

  print_footer
  return 0
}

main "$@"
