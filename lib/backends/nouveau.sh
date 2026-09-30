# shellcheck shell=bash
#
# nouveau.sh - backend NVIDIA com a pilha livre: driver nouveau no kernel e NVK
# (Mesa) no Vulkan. O backend "nvidia" continua sendo o do driver da NVIDIA, via
# nvidia-smi; este e o que serve quando o nvidia-smi nao existe porque a placa
# esta no nouveau.
#
# Segue o molde do backend nvidia, e nao o do amd: um produtor externo cadencia
# as amostras e escreve num FIFO, e um awk formata as linhas do CSV. O produtor
# aqui e o lib/helpers/nouveau-sampler.sh, no papel do "nvidia-smi -lms": ele le
# a VRAM pelo vulkaninfo - veja o cabecalho dele para o porque e para a conta.
#
# ---------------------------------------------------------------------------
# DE ONDE VEM CADA METRICA
# ---------------------------------------------------------------------------
#
#   vulkaninfo, heap DEVICE_LOCAL: size            -> vram_total_mib
#   vulkaninfo, heap DEVICE_LOCAL: size - budget/0,9 -> vram_used_mib (estimativa)
#
# E so. Medido numa RTX 3050 Laptop (GA107, PCI 10de:25e2) com Linux 7.0 em
# 2026-09-29: com o firmware GSP o nouveau nao cria hwmon (sem temperatura nem
# potencia), nao tem gpu_busy_percent, nao expoe clocks e nao preenche as linhas
# drm-* do fdinfo. Essas colunas saem vazias - nunca zero.
#
# Cada leitura custa ~0,2 s e cria um dispositivo Vulkan na placa, entao a VRAM
# e lida no maximo a cada MONITOR_NOUVEAU_MIN_MS (padrao 2000): com -i menor, o
# CSV da GPU tem menos linhas que os outros, e nao linhas repetidas.
#
# ---------------------------------------------------------------------------
# VRAM POR PROCESSO
# ---------------------------------------------------------------------------
#
# Nao ha fonte: sem fdinfo e sem debugfs legivel, a VRAM nao e atribuivel a
# processos. nouveau_supports_procs retorna 1.

NOUVEAU_CARDS=""       # "0 1" - indices das placas selecionadas
NOUVEAU_NAMES=""       # "0=NVIDIA GeForce RTX 3050 Mobile;..." - indice -> nome
NOUVEAU_GPU_SKIP=0
NOUVEAU_MIN_MS="${MONITOR_NOUVEAU_MIN_MS:-2000}"

# Onde ficam os nos /dev/dri. Existe para a suite apontar para arquivos falsos.
NOUVEAU_DEV_ROOT="${MONITOR_DEV_ROOT:-/dev}"

nouveau_name() { printf 'NVIDIA (nouveau)'; }

# O produtor: o sampler do projeto, ou o que MONITOR_NOUVEAU_SAMPLER apontar - a
# suite troca por um script que emite linhas conhecidas, ja que nao ha placa.
_nouveau_sampler() {
  printf '%s' "${MONITOR_NOUVEAU_SAMPLER:-$LIB_DIR/helpers/nouveau-sampler.sh}"
}

# Precisa de uma placa no nouveau e do vulkaninfo. Sem ele o backend nao tem
# como ler nada, entao nem se oferece na autodeteccao.
nouveau_probe() {
  local c
  if [[ -z "${MONITOR_NOUVEAU_SAMPLER:-}" ]]; then
    command -v vulkaninfo >/dev/null 2>&1 || return 1
  fi
  for c in "$DRM_ROOT"/card[0-9]*; do
    [[ -r "$c/device/uevent" ]] || continue
    grep -q '^DRIVER=nouveau$' "$c/device/uevent" 2>/dev/null && return 0
  done
  return 1
}

nouveau_supports_procs() { return 1; }

# Nome no mesmo formato do nvidia-smi ("NVIDIA GeForce RTX 3050 ..."). O lspci
# devolve "NVIDIA Corporation GA107BM [GeForce RTX 3050 Mobile] (rev a1)": o
# modelo comercial e o ultimo trecho entre colchetes. Sem lspci, o PCI ID cru.
_nouveau_card_name() {
  local slot="$1" dev="$2" line="" name=""
  if command -v lspci >/dev/null 2>&1; then
    line=$(lspci -s "${slot#0000:}" 2>/dev/null \
           | grep -iE '(VGA compatible|3D|Display) controller' | head -1)
    line=${line% (rev *)}
    if [[ "$line" == *'['*']'* ]]; then
      name=${line##*[}
      name=${name%]}
    fi
  fi
  [[ -n "$name" ]] || name="GPU $dev"
  name=$(printf '%s' "$name" | sed 's/,/ /g; s/  */ /g; s/^ *//; s/ *$//')
  case "$name" in
    NVIDIA*) printf '%s' "$name" ;;
    *)       printf 'NVIDIA %s' "$name" ;;
  esac
}

nouveau_init() {
  local c slot dev node n idx=0 name

  if [[ -z "${MONITOR_NOUVEAU_SAMPLER:-}" ]]; then
    command -v vulkaninfo >/dev/null 2>&1 || die "$(msg nouveau_no_vulkaninfo)"
  fi
  [[ "$NOUVEAU_MIN_MS" =~ ^[0-9]+$ ]] \
    || die "$(msg sys_bad_env MONITOR_NOUVEAU_MIN_MS "$NOUVEAU_MIN_MS")"

  for c in "$DRM_ROOT"/card[0-9]*; do
    [[ -r "$c/device/uevent" ]] || continue
    grep -q '^DRIVER=nouveau$' "$c/device/uevent" 2>/dev/null || continue

    # Indice pela ordem do sysfs (por bus id), como no backend amd.
    if [[ -n "$GPU_IDX" && "$GPU_IDX" != "$idx" ]]; then
      idx=$((idx + 1))
      continue
    fi

    # O render node da placa: e por ele que o Vulkan (e o vulkaninfo) fala com
    # o driver. Sem acesso, a leitura falharia calada a cada amostra.
    node=""
    for n in "$c"/device/drm/renderD*; do
      [[ -e "$n" ]] && { node="$NOUVEAU_DEV_ROOT/dri/${n##*/}"; break; }
    done
    [[ -n "$node" ]] || die "$(msg nouveau_no_render "${c##*/}")"
    [[ -r "$node" && -w "$node" ]] || die "$(msg nouveau_no_access "$node")"

    slot=$(grep -oP '(?<=^PCI_SLOT_NAME=).*' "$c/device/uevent" 2>/dev/null)
    dev=$(cat "$c/device/device" 2>/dev/null)
    name=$(_nouveau_card_name "$slot" "$dev")

    NOUVEAU_CARDS="${NOUVEAU_CARDS:+$NOUVEAU_CARDS }$idx"
    NOUVEAU_NAMES="${NOUVEAU_NAMES:+$NOUVEAU_NAMES;}$idx=$name"
    GPU_COUNT=$((GPU_COUNT + 1))
    idx=$((idx + 1))
  done

  [[ -n "$NOUVEAU_CARDS" ]] \
    || die "$(msg nouveau_no_gpu "${GPU_IDX:+$(msg nvidia_at_index "$GPU_IDX")}")"
}

nouveau_start_gpu() {
  make_fifo gpumon; local fifo="$FIFO_PATH"

  NOUVEAU_GPU_SKIP=$(wc -l < "$OUTPUT" 2>/dev/null || printf 0)

  # shellcheck disable=SC2086  # um argumento por indice
  run_source bash "$(_nouveau_sampler)" "$INTERVAL_MS" "$NOUVEAU_MIN_MS" $NOUVEAU_CARDS \
    > "$fifo" 2>/dev/null &
  GPU_SRC_PID=$!

  # LC_ALL=C: o %.1f do vram_used_pct com virgula decimal partiria a coluna.
  LC_ALL=C awk -v out="$OUTPUT" -v names="$NOUVEAU_NAMES" -v quiet="$QUIET" \
               -v m_samples="$(msg_raw awk_samples)" '
  BEGIN {
    FS = ","
    n = split(names, pairs, ";")
    for (k = 1; k <= n; k++) {
      p = index(pairs[k], "=")
      gname[substr(pairs[k], 1, p - 1)] = substr(pairs[k], p + 1)
    }
  }

  # bytes -> MiB, preservando o vazio de um parametro que o kernel nao respondeu.
  function mib(v) { return (v == "") ? "" : sprintf("%.0f", v / 1048576) }

  NF >= 4 {
    ts = $1; idx = $2
    vtot = mib($3); vused = mib($4)
    vfree = ""; vpct = ""
    if (vtot != "" && vused != "") {
      vfree = vtot - vused
      vpct  = (vtot + 0 > 0) ? sprintf("%.1f", vused * 100.0 / vtot) : ""
    }
    name = (idx in gname) ? gname[idx] : "GPU" idx

    # Mesmas 13 colunas do nvidia-smi. Uso, temperatura, potencia e clocks o
    # nouveau nao informa: celula vazia, e nao zero.
    printf("%s,%s,%s,,,%s,%s,%s,%s,,,,\n",
           ts, idx, name, vtot, vused, vfree, vpct) >> out
    fflush(out)
    rows++

    if (!quiet) {
      printf("%s  GPU%s  util   -%%   vram %5s/%s MiB (%4s%%)   temp   - C        - W\n",
             substr(ts, 12, 8), idx,
             (vused == "" ? "-" : vused), (vtot == "" ? "-" : vtot),
             (vpct == "" ? "-" : vpct))
      fflush("")
    }
  }

  END {
    if (!quiet) printf("\n" m_samples "\n", rows) > "/dev/stderr"
  }
  ' < "$fifo" &
  GPU_AWK_PID=$!
}

nouveau_start_proc() {
  die "$(msg backend_no_procs "$(nouveau_name)")"
}

nouveau_list_procs() {
  : # Sem atribuicao de VRAM a processos, nao ha o que listar.
}
