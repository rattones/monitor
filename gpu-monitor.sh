#!/usr/bin/env bash
#
# gpu-monitor.sh - amostra o uso da GPU NVIDIA (incluindo VRAM) e grava em CSV,
# com atribuicao da VRAM por processo num segundo CSV.
#
# Uso rapido:   ./gpu-monitor.sh                 # 1 amostra/s ate Ctrl+C
#               ./gpu-monitor.sh -d 300          # monitora por 5 minutos
#               ./gpu-monitor.sh -i 0.5 -o x.csv # 2 amostras/s em x.csv

set -uo pipefail

VERSION="1.1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

INTERVAL=1        # segundos entre amostras
DURATION=0        # 0 = roda ate Ctrl+C
OUTPUT=""         # padrao: logs/gpu-<data>.csv
GPU_IDX=""        # padrao: todas as GPUs
QUIET=0
PROCS_MODE="all"  # all | compute | off
TOP_N=5           # quantos processos no resumo final
DISK_MODE="all"   # all | off | lista de dispositivos
FILTER_RAW=""     # como o usuario escreveu, so para exibir
FILTER_PIDS=""    # ";1598;2951;" - delimitado, para busca exata por PID
FILTER_NAMES=""   # ";chrome;xorg;" - minusculas, para busca no nome do executavel
FILTER_CMDS=""    # subconjunto dos alvos que so fazem sentido na linha completa

usage() {
  cat <<EOF
gpu-monitor.sh v$VERSION - monitor de uso de GPU/VRAM NVIDIA com saida CSV

Uso: ${0##*/} [opcoes]

  -i, --interval SEG   Intervalo entre amostras (padrao: 1; aceita fracao, min 0.1)
  -d, --duration SEG   Duracao total em segundos (padrao: 0 = ate Ctrl+C)
  -o, --output ARQ     Arquivo CSV de saida (padrao: $SCRIPT_DIR/logs/gpu-AAAAMMDD-HHMMSS.csv)
  -g, --gpu IDX        Monitora apenas a GPU de indice IDX (padrao: todas)
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
  -D, --disk MODO      Monitora I/O e temperatura de disco (padrao: all)
                         all     - todos os discos fisicos
                         off     - nao coleta disco
                         LISTA   - dispositivos separados por virgula
                                   (ex: -D nvme0n1 ou -D sda,sdb)
  -t, --top N          Quantos processos no resumo final (padrao: 5; 0 desliga)
  -q, --quiet          Nao imprime nada na tela, so grava os CSVs
  -h, --help           Mostra esta ajuda

Saidas:
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
  write_iops         operacoes de escrita por segundo
  util_pct           % de tempo com pelo menos uma requisicao em voo
  temp_c             temperatura do disco (vazio se nao houver sensor)

Os arquivos se juntam pelo segundo do timestamp (e pelo gpu_index, entre os dois
primeiros). A soma de used_vram_mib e menor que vram_used_mib, porque o driver e
o contexto de video tambem reservam memoria fora dos processos. As taxas de disco
sao deltas entre amostras, entao a primeira leitura serve de base e a primeira
linha de <saida>-disk.csv sai um intervalo depois do inicio.

Os CSVs recebem flush a cada amostra, entao podem ser lidos/plotados enquanto
a coleta ainda esta rodando.
EOF
}

die() { printf 'erro: %s\n' "$1" >&2; exit 1; }

# Acumula alvos de -f/--filter. PIDs viram uma string delimitada por ";" para
# comparacao exata; nomes vao em minusculas, para casar por trecho no awk.
add_filter() {
  local raw="${1-}" item kind
  [[ -n "$raw" ]] || die "--filter exige ao menos um PID ou nome"
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
    [[ -n "$item" ]] || die "alvo vazio em --filter"

    if [[ "$kind" == auto ]]; then
      [[ "$item" =~ ^[0-9]+$ ]] && kind=pid || kind=name
    fi

    if [[ "$kind" == pid ]]; then
      [[ "$item" =~ ^[0-9]+$ ]] || die "PID invalido em --filter: $item"
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
    [[ -n "$item" ]] || die "alvo vazio em --filter"
    case "$item" in
      */*|*' '*) wide=1 ;;
    esac

    item="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')"
    FILTER_NAMES="${FILTER_NAMES:-;}$item;"
    (( wide )) && FILTER_CMDS="${FILTER_CMDS:-;}$item;"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval) INTERVAL="${2:-}"; shift 2 ;;
    -d|--duration) DURATION="${2:-}"; shift 2 ;;
    -o|--output)   OUTPUT="${2:-}";   shift 2 ;;
    -g|--gpu)      GPU_IDX="${2:-}";  shift 2 ;;
    -p|--procs)    PROCS_MODE="${2:-}"; shift 2 ;;
    -D|--disk)     DISK_MODE="${2:-}"; shift 2 ;;
    -f|--filter)   add_filter "${2:-}"; shift 2 ;;
    -t|--top)      TOP_N="${2:-}";    shift 2 ;;
    -q|--quiet)    QUIET=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "opcao desconhecida: $1 (use --help)" ;;
  esac
done

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi nao encontrado - driver NVIDIA instalado?"
nvidia-smi -L >/dev/null 2>&1 || die "nvidia-smi nao conseguiu falar com o driver"

[[ "$INTERVAL" =~ ^[0-9]*\.?[0-9]+$ ]] || die "intervalo invalido: $INTERVAL"
[[ "$DURATION" =~ ^[0-9]*\.?[0-9]+$ ]] || die "duracao invalida: $DURATION"
[[ -z "$GPU_IDX" || "$GPU_IDX" =~ ^[0-9]+$ ]] || die "indice de GPU invalido: $GPU_IDX"
[[ "$TOP_N" =~ ^[0-9]+$ ]] || die "valor invalido para --top: $TOP_N"
case "$PROCS_MODE" in
  all|compute|off) ;;
  *) die "modo invalido para --procs: $PROCS_MODE (use all, compute ou off)" ;;
esac
if [[ -n "$FILTER_RAW" && "$PROCS_MODE" == off ]]; then
  die "--filter e --procs off se excluem: o filtro so age sobre os processos coletados"
fi

# Discos fisicos: /sys/block lista so dispositivos inteiros (particoes ficam
# dentro deles). dm-*/md-* espelham I/O de discos reais e contariam duas vezes.
list_disks() {
  local d n
  for d in /sys/block/*; do
    n="${d##*/}"
    case "$n" in loop*|ram*|zram*|dm-*|md*|sr*) continue ;; esac
    [[ -r "/sys/block/$n/stat" ]] && printf '%s\n' "$n"
  done
}

# Onde fica a temperatura de um disco: NVMe pendura um hwmon no proprio device,
# SATA depende do modulo drivetemp. Sem nenhum dos dois, a coluna fica vazia.
disk_temp_file() {
  local dev="$1" f real h
  for f in "/sys/block/$dev/device/hwmon"*/temp1_input \
           "/sys/block/$dev/device/hwmon/hwmon"*/temp1_input; do
    [[ -r "$f" ]] && { printf '%s' "$f"; return; }
  done
  real=$(readlink -f "/sys/block/$dev/device" 2>/dev/null) || return
  [[ -n "$real" ]] || return
  for h in /sys/class/hwmon/hwmon*; do
    [[ -r "$h/temp1_input" ]] || continue
    [[ "$(readlink -f "$h/device" 2>/dev/null)" == "$real" ]] && {
      printf '%s' "$h/temp1_input"; return; }
  done
}

INTERVAL_MS=$(LC_ALL=C awk -v i="$INTERVAL" 'BEGIN { printf "%d", i * 1000 }')
(( INTERVAL_MS >= 100 )) || die "intervalo minimo e 0.1s"

# Alvo: uma GPU especifica ou todas.
SMI_TARGET=()
[[ -n "$GPU_IDX" ]] && SMI_TARGET=(-i "$GPU_IDX")

# Um indice invalido faz o nvidia-smi imprimir "No devices were found" no
# proprio stdout, entao checar so se a saida esta vazia nao basta: o codigo de
# retorno e o filtro de indice numerico e que separam GPU real de mensagem.
if ! GPU_LIST=$(nvidia-smi "${SMI_TARGET[@]}" --query-gpu=index,name,gpu_bus_id --format=csv,noheader 2>&1); then
  die "nvidia-smi nao conseguiu listar a GPU${GPU_IDX:+ de indice $GPU_IDX}: $GPU_LIST"
fi

# Nome e bus id nao mudam durante a coleta: le uma vez e repassa aos awks como
# mapas "chave=valor;chave=valor", evitando campos de texto dentro do loop.
NAMES=$(printf '%s\n' "$GPU_LIST" \
        | awk -F', *' '$1 ~ /^[0-9]+$/ { printf "%s%s=%s", sep, $1, $2; sep=";" }')
[[ -n "$NAMES" ]] || die "nenhuma GPU encontrada${GPU_IDX:+ no indice $GPU_IDX}"
# A secao de processos identifica a placa por bus id, nao por indice.
BUSMAP=$(printf '%s\n' "$GPU_LIST" \
         | awk -F', *' '$1 ~ /^[0-9]+$/ { printf "%s%s=%s", sep, toupper($3), $1; sep=";" }')

if [[ -z "$OUTPUT" ]]; then
  mkdir -p "$SCRIPT_DIR/logs" || die "nao consegui criar $SCRIPT_DIR/logs"
  OUTPUT="$SCRIPT_DIR/logs/gpu-$(date +%Y%m%d-%H%M%S).csv"
fi
mkdir -p "$(dirname -- "$OUTPUT")" || die "nao consegui criar $(dirname -- "$OUTPUT")"
PROCS_OUT="${OUTPUT%.csv}-procs.csv"
DISK_OUT="${OUTPUT%.csv}-disk.csv"

DISK_DEVS=""; DISK_TEMPS=""
if [[ "$DISK_MODE" != off ]]; then
  if [[ "$DISK_MODE" == all ]]; then
    mapfile -t _disks < <(list_disks)
    (( ${#_disks[@]} )) || die "nenhum disco fisico encontrado (use --disk off)"
  else
    IFS=, read -ra _disks <<< "$DISK_MODE"
  fi
  for _d in "${_disks[@]}"; do
    _d="$(printf '%s' "$_d" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$_d" ]] || continue
    [[ -r "/sys/block/$_d/stat" ]] || die "disco desconhecido: $_d (veja lsblk -d)"
    DISK_DEVS="${DISK_DEVS:+$DISK_DEVS;}$_d"
    DISK_TEMPS="${DISK_TEMPS:+$DISK_TEMPS;}$_d=$(disk_temp_file "$_d")"
  done
  [[ -n "$DISK_DEVS" ]] || die "nenhum disco selecionado em --disk"
fi

HEADER="timestamp,gpu_index,gpu_name,gpu_util_pct,mem_util_pct,vram_total_mib,vram_used_mib,vram_free_mib,vram_used_pct,temp_c,power_w,sm_clock_mhz,mem_clock_mhz"
PROCS_HEADER="timestamp,gpu_index,pid,type,process_name,used_vram_mib"
# So escreve cabecalho em arquivo novo/vazio, para permitir append entre sessoes.
[[ -s "$OUTPUT" ]] || printf '%s\n' "$HEADER" > "$OUTPUT" || die "nao consegui escrever em $OUTPUT"

PROCS_SKIP=0
if [[ "$PROCS_MODE" != off ]]; then
  [[ -s "$PROCS_OUT" ]] || printf '%s\n' "$PROCS_HEADER" > "$PROCS_OUT" \
    || die "nao consegui escrever em $PROCS_OUT"
  # Marca onde esta sessao comeca, para o resumo final nao somar coletas antigas.
  PROCS_SKIP=$(wc -l < "$PROCS_OUT")
fi

DISK_HEADER="timestamp,device,read_mb_s,write_mb_s,read_iops,write_iops,util_pct,temp_c"
if [[ "$DISK_MODE" != off ]]; then
  [[ -s "$DISK_OUT" ]] || printf '%s\n' "$DISK_HEADER" > "$DISK_OUT" \
    || die "nao consegui escrever em $DISK_OUT"
  DISK_SKIP=$(wc -l < "$DISK_OUT")
fi

FIFO=$(mktemp -u -t gpumon.XXXXXXXX)
PFIFO=$(mktemp -u -t gpumonp.XXXXXXXX)
mkfifo "$FIFO" || die "nao consegui criar o FIFO"
[[ "$PROCS_MODE" == off ]] || mkfifo "$PFIFO" || die "nao consegui criar o FIFO de processos"

NVSMI_PID=""; PROCS_PID=""; AWK_PID=""; AWK_PROCS_PID=""; DISK_PID=""
cleanup() {
  for p in "$NVSMI_PID" "$PROCS_PID" "$AWK_PID" "$AWK_PROCS_PID" "$DISK_PID"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  rm -f "$FIFO" "$PFIFO"
  return 0
}
trap cleanup EXIT

# Ctrl+C/TERM encerram apenas as fontes de dados: os FIFOs chegam a EOF, os awks
# drenam o que ja foi lido, imprimem o resumo e saem por conta propria. Matar os
# awks aqui truncaria a ultima amostra e perderia a contagem final.
stop() {
  [[ -n "$NVSMI_PID" ]] && kill "$NVSMI_PID" 2>/dev/null
  [[ -n "$PROCS_PID" ]] && kill "$PROCS_PID" 2>/dev/null
  # O coletor de disco nao tem produtor para fechar, entao e encerrado direto:
  # cada linha ja foi gravada com flush, nada fica pela metade.
  [[ -n "$DISK_PID" ]] && kill "$DISK_PID" 2>/dev/null
  return 0
}
trap stop INT TERM

FIELDS="timestamp,index,utilization.gpu,utilization.memory,memory.total,memory.used,memory.free,temperature.gpu,power.draw,clocks.sm,clocks.mem"

# -lms deixa o proprio nvidia-smi cadenciar as amostras: uma unica sessao NVML,
# sem o custo e o drift de reabrir o driver a cada iteracao.
smi_cmd=(nvidia-smi "${SMI_TARGET[@]}" --query-gpu="$FIELDS" --format=csv,noheader,nounits -lms "$INTERVAL_MS")
# --query-compute-apps so enxerga contextos CUDA; num desktop tipico a VRAM toda
# esta em processos graficos (Xorg, navegador, jogo), que ele reporta como vazio.
# -q -d PIDS traz as duas familias com o tipo explicito, e o modo "compute"
# filtra por type == C para reproduzir exatamente o recorte do --query-compute-apps.
procs_cmd=(nvidia-smi "${SMI_TARGET[@]}" -q -d PIDS -lms "$INTERVAL_MS")

if LC_ALL=C awk -v d="$DURATION" 'BEGIN { exit !(d > 0) }'; then
  timeout "$DURATION" "${smi_cmd[@]}" > "$FIFO" 2>/dev/null &
  NVSMI_PID=$!
  if [[ "$PROCS_MODE" != off ]]; then
    LC_ALL=C timeout "$DURATION" "${procs_cmd[@]}" > "$PFIFO" 2>/dev/null &
    PROCS_PID=$!
  fi
else
  "${smi_cmd[@]}" > "$FIFO" 2>/dev/null &
  NVSMI_PID=$!
  if [[ "$PROCS_MODE" != off ]]; then
    LC_ALL=C "${procs_cmd[@]}" > "$PFIFO" 2>/dev/null &
    PROCS_PID=$!
  fi
fi

if (( ! QUIET )); then
  printf 'gravando em: %s\n' "$OUTPUT"
  [[ "$PROCS_MODE" == off ]] || printf 'processos em: %s (%s%s)\n' \
    "$PROCS_OUT" "$PROCS_MODE" "${FILTER_RAW:+, filtro: $FILTER_RAW}"
  [[ "$DISK_MODE" == off ]] || printf 'disco em: %s (%s)\n' \
    "$DISK_OUT" "${DISK_DEVS//;/, }"
  printf 'intervalo: %ss | duracao: %s | Ctrl+C para parar\n\n' \
    "$INTERVAL" "$( [[ "$DURATION" == 0 ]] && echo ilimitada || echo "${DURATION}s" )"
fi

# --- pipeline 1: metricas da GPU -------------------------------------------
# LC_ALL=C: sem isso um locale pt_BR faz o %.1f do awk emitir virgula decimal,
# o que parte a coluna vram_used_pct em duas no CSV.
LC_ALL=C awk -v out="$OUTPUT" -v names="$NAMES" -v quiet="$QUIET" '
BEGIN {
  FS = " *, *"
  n = split(names, pairs, ";")
  for (k = 1; k <= n; k++) {
    p = index(pairs[k], "=")
    gname[substr(pairs[k], 1, p - 1)] = substr(pairs[k], p + 1)
  }
}

# Campos indisponiveis viram celula vazia em vez de "[N/A]".
function num(v) { return (v ~ /N\/A/) ? "" : v }

{
  ts = $1; gsub("/", "-", ts); sub(" ", "T", ts)
  idx   = $2
  ugpu  = num($3); umem = num($4)
  vtot  = num($5); vused = num($6); vfree = num($7)
  temp  = num($8); pwr  = num($9)
  csm   = num($10); cmem = num($11)

  vpct = (vtot + 0 > 0) ? vused * 100.0 / vtot : 0
  name = (idx in gname) ? gname[idx] : "GPU" idx

  printf("%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%s,%s,%s,%s\n",
         ts, idx, name, ugpu, umem, vtot, vused, vfree, vpct, temp, pwr, csm, cmem) >> out
  fflush(out)
  rows++

  if (!quiet) {
    printf("%s  GPU%s  util %3s%%   vram %5s/%s MiB (%4.1f%%)   temp %3s C   %6s W\n",
           substr(ts, 12, 8), idx, ugpu, vused, vtot, vpct, temp, (pwr == "" ? "-" : pwr))
    fflush("")
  }
}

END {
  if (!quiet) printf("\n%d amostras gravadas.\n", rows) > "/dev/stderr"
}
' < "$FIFO" &
AWK_PID=$!

# --- pipeline 2: VRAM por processo -----------------------------------------
if [[ "$PROCS_MODE" != off ]]; then
  LC_ALL=C awk -v out="$PROCS_OUT" -v busmap="$BUSMAP" -v mode="$PROCS_MODE" \
               -v fpids="$FILTER_PIDS" -v fnames="$FILTER_NAMES" \
               -v fcmds="$FILTER_CMDS" '
  BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
    for (i = 1; i <= 12; i++) mon[mn[i]] = sprintf("%02d", i)
    n = split(busmap, pairs, ";")
    for (k = 1; k <= n; k++) {
      p = index(pairs[k], "=")
      busidx[substr(pairs[k], 1, p - 1)] = substr(pairs[k], p + 1)
    }
    nnames = split(fnames, fname, ";")
    ncmds = split(fcmds, fcmd, ";")
    has_filter = (fpids != "" || fnames != "")
  }

  # Sem filtro, tudo passa. Com filtro, basta casar um alvo: PID exato (as
  # bordas ";" impedem que 159 case com 1598), trecho do nome do executavel ou
  # - so para alvos com caminho/argumentos - trecho da linha de comando inteira.
  # Restringir a busca ampla a esses alvos evita que um "-f gpu" recolha todo
  # processo que por acaso tenha "--type=gpu-process" entre os argumentos.
  function keep(pid, exe, cmd,   i, lexe, lcmd) {
    if (!has_filter) return 1
    if (fpids != "" && index(fpids, ";" pid ";")) return 1

    lexe = tolower(exe)
    for (i = 1; i <= nnames; i++)
      if (fname[i] != "" && index(lexe, fname[i])) return 1

    lcmd = tolower(cmd)
    for (i = 1; i <= ncmds; i++)
      if (fcmd[i] != "" && index(lcmd, fcmd[i])) return 1

    return 0
  }

  # "Tue Sep 15 21:27:08 2026" -> "2026-09-15T21:27:08"
  function iso(s,   a, c) {
    c = split(s, a, / +/)
    if (c < 5 || !(a[2] in mon)) return s
    return sprintf("%s-%s-%02dT%s", a[5], mon[a[2]], a[3], a[4])
  }

  # Valor de uma linha "Rotulo : valor" (o rotulo nunca contem ":").
  function val(s) { sub(/^[^:]*:[ ]*/, "", s); return s }

  /^Timestamp/ { ts = iso(val($0)); next }

  # Cabecalho de placa: "GPU 00000000:01:00.0"
  /^GPU [0-9A-Fa-f]+:/ {
    bus = toupper($2)
    # Placa fora do mapa (inconsistencia ou hot-plug): melhor descartar do que
    # atribuir os processos dela a um indice que nao e o dono da memoria.
    unknown_gpu = !(bus in busidx)
    idx = unknown_gpu ? "" : busidx[bus]
    next
  }

  /^ +Process ID +:/ { pid = val($0); ptype = ""; pname = ""; next }
  /^ +Type +:/       { ptype = val($0); next }
  /^ +Name +:/       { pname = val($0); next }

  # "Used GPU Memory" fecha o bloco do processo - so aqui os quatro campos existem.
  /^ +Used GPU Memory +:/ {
    mem = val($0)
    if (unknown_gpu || pid == "" || mem ~ /N\/A|Not available/) next
    # O tipo pode ser "C", "G" ou "C+G" (o processo tem os dois contextos):
    # comparar com "C" exato descartaria justamente quem usa CUDA e video juntos.
    if (mode == "compute" && ptype !~ /C/) next

    sub(/ *MiB$/, "", mem)
    # A linha de comando completa (chrome, discord) tem centenas de caracteres e
    # virgulas: o executavel basta para identificar quem consome, o PID desambigua.
    split(pname, w, " ")
    exe = w[1]; sub(/.*\//, "", exe); gsub(/[",]/, "_", exe)

    if (!keep(pid, exe, pname)) next

    printf("%s,%s,%s,%s,%s,%s\n", ts, idx, pid, ptype, exe, mem) >> out
    fflush(out)
  }
  ' < "$PFIFO" &
  AWK_PROCS_PID=$!
fi

# --- pipeline 3: I/O e temperatura de disco --------------------------------
# Aqui nao ha produtor externo: /proc e /sys sao arquivos, entao o proprio awk
# cadencia o loop. Os contadores do kernel sao cumulativos desde o boot, e o que
# interessa e a taxa - por isso a primeira leitura vira base e so a partir da
# segunda sai linha no CSV.
if [[ "$DISK_MODE" != off ]]; then
  LC_ALL=C awk -v out="$DISK_OUT" -v devs="$DISK_DEVS" -v temps="$DISK_TEMPS" \
               -v iv="$INTERVAL" -v dur="$DURATION" '
  function uptime(   l, a) {
    getline l < "/proc/uptime"; close("/proc/uptime")
    split(l, a, " ")
    return a[1] + 0
  }

  function now(   cmd, t) {
    cmd = "date +%Y-%m-%dT%H:%M:%S"
    cmd | getline t
    close(cmd)
    return t
  }

  # Contadores cumulativos por disco: leituras, setores lidos, escritas,
  # setores escritos e ms com requisicao em voo (campos 4, 6, 8, 10 e 13).
  function snap(arr,   line, f, n) {
    delete arr
    while ((getline line < "/proc/diskstats") > 0) {
      n = split(line, f)
      if (n < 13 || !(f[3] in want)) continue
      arr[f[3]] = f[4] " " f[6] " " f[8] " " f[10] " " f[13]
    }
    close("/proc/diskstats")
  }

  # hwmon reporta em milesimos de grau; disco sem sensor fica com celula vazia.
  function tempc(d,   path, v) {
    path = tfile[d]
    if (path == "") return ""
    if ((getline v < path) <= 0) { close(path); return "" }
    close(path)
    return sprintf("%.1f", v / 1000)
  }

  BEGIN {
    nd = split(devs, dev, ";")
    for (i = 1; i <= nd; i++) want[dev[i]] = 1
    nt = split(temps, pair, ";")
    for (i = 1; i <= nt; i++) {
      p = index(pair[i], "=")
      tfile[substr(pair[i], 1, p - 1)] = substr(pair[i], p + 1)
    }

    snap(prev)
    t_prev = uptime(); t0 = t_prev; target = t0

    while (1) {
      # Dorme ate o proximo instante-alvo em vez de um intervalo cheio: ler
      # /proc e chamar date custa tempo, e dormir "iv" depois disso empurraria
      # cada amostra para frente ate as linhas deixarem de bater com as da GPU.
      target += iv
      slp = target - uptime()
      if (slp > 0) system("sleep " slp)

      t = uptime(); dt = t - t_prev
      ts = now()
      snap(cur)

      if (dt > 0) {
        for (i = 1; i <= nd; i++) {
          d = dev[i]
          if (!(d in cur) || !(d in prev)) continue
          split(prev[d], a); split(cur[d], b)
          dr = b[1] - a[1]; dsr = b[2] - a[2]
          dw = b[3] - a[3]; dsw = b[4] - a[4]
          dms = b[5] - a[5]
          # Contador reiniciado (disco reconectado): sem base confiavel, pula.
          if (dr < 0 || dsr < 0 || dw < 0 || dsw < 0 || dms < 0) continue

          util = dms / 10 / dt              # ms de I/O -> % do intervalo
          if (util > 100) util = 100        # NVMe soma filas paralelas

          # diskstats conta em setores de 512 B, independente do bloco fisico.
          printf("%s,%s,%.2f,%.2f,%.0f,%.0f,%.1f,%s\n", ts, d,
                 dsr * 512 / 1048576 / dt, dsw * 512 / 1048576 / dt,
                 dr / dt, dw / dt, util, tempc(d)) >> out
        }
        fflush(out)
      }

      for (d in cur) prev[d] = cur[d]
      t_prev = t
      if (dur > 0 && t - t0 >= dur - 0.05) break
    }
  }
  ' &
  DISK_PID=$!
fi

# Os awks rodam em background e o shell espera: assim um sinal e tratado na hora,
# em vez de ficar pendurado ate um pipeline em foreground terminar. O wait e
# interrompido pelo sinal, entao reespera ate os awks realmente sairem.
for pid_var in AWK_PID AWK_PROCS_PID DISK_PID; do
  pid="${!pid_var}"
  [[ -n "$pid" ]] || continue
  while kill -0 "$pid" 2>/dev/null; do
    wait "$pid" 2>/dev/null
  done
done
AWK_PID=""; AWK_PROCS_PID=""; DISK_PID=""

wait "$NVSMI_PID" 2>/dev/null; NVSMI_PID=""
[[ -n "$PROCS_PID" ]] && { wait "$PROCS_PID" 2>/dev/null; PROCS_PID=""; }

# Um filtro que nao casou com nada gera um CSV so com cabecalho, o que parece
# coleta quebrada: avisa e mostra quem estava na GPU, para corrigir o alvo.
if [[ -n "$FILTER_RAW" && "$PROCS_MODE" != off ]] \
   && (( $(wc -l < "$PROCS_OUT") <= PROCS_SKIP )); then
  printf '\naviso: nenhum processo casou com o filtro "%s".\n' "$FILTER_RAW" >&2
  seen=$(nvidia-smi "${SMI_TARGET[@]}" -q -d PIDS 2>/dev/null \
         | awk '/^ +Name +:/ { n = $0; sub(/^[^:]*:[ ]*/, "", n); split(n, w, " ")
                               sub(/.*\//, "", w[1]); print w[1] }' \
         | sort -u | paste -sd" ")
  [[ -n "$seen" ]] && printf 'processos na GPU agora: %s\n' "$seen" >&2
fi

# --- resumo: quem consumiu a VRAM ------------------------------------------
if (( ! QUIET )) && [[ "$PROCS_MODE" != off ]] && (( TOP_N > 0 )) && [[ -s "$PROCS_OUT" ]]; then
  LC_ALL=C awk -F, -v skip="$PROCS_SKIP" -v top="$TOP_N" '
  NR <= skip { next }
  {
    key = $3 " " $5 " " $4
    sum[key] += $6; cnt[key]++
    if ($6 + 0 > peak[key]) peak[key] = $6 + 0
  }
  END {
    if (!length(sum)) exit
    printf("\ntop %d processos por VRAM (media / pico):\n", top)
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
fi

# --- resumo: disco ---------------------------------------------------------
if (( ! QUIET )) && [[ "$DISK_MODE" != off ]] && [[ -s "$DISK_OUT" ]]; then
  LC_ALL=C awk -F, -v skip="${DISK_SKIP:-1}" '
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
    print "\ndisco (media / pico):"
    for (d in n) {
      t = (tn[d] ? sprintf("%.1f / %.1f C", ts[d] / tn[d], tp[d]) : "sem sensor")
      printf("  %-10s leitura %6.1f / %6.1f MB/s   escrita %6.1f / %6.1f MB/s   temp %s\n",
             d, rs[d] / n[d], rp[d], ws[d] / n[d], wp[d], t)
    }
  }
  ' "$DISK_OUT"
fi

(( QUIET )) || {
  printf '\nCSV: %s\n' "$OUTPUT"
  [[ "$PROCS_MODE" == off ]] || printf 'CSV processos: %s\n' "$PROCS_OUT"
  [[ "$DISK_MODE" == off ]] || printf 'CSV disco: %s\n' "$DISK_OUT"
}
