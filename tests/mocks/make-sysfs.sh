#!/usr/bin/env bash
#
# make-sysfs.sh - monta uma arvore /sys/class/drm falsa para os testes de AMD
# e Intel, com os arquivos que cada perfil de hardware expoe.
#
# O ponto do mock nao e so ter valores: e reproduzir quais arquivos EXISTEM.
# Um perfil antigo deixa de criar mem_busy_percent ou lmem_*, e e isso que
# exercita o caminho "metrica ausente vira celula vazia" do backend.
#
# Uso: make-sysfs.sh <destino> <perfil>
#        perfis: amd_moderna amd_antiga intel_moderna intel_antiga

set -uo pipefail

DEST="${1:?uso: make-sysfs.sh <destino> <perfil>}"
PROFILE="${2:?uso: make-sysfs.sh <destino> <perfil>}"
MOCK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$MOCK_DIR/gpu-profiles.sh"
"profile_$PROFILE" || { printf 'perfil desconhecido: %s\n' "$PROFILE" >&2; exit 1; }

CARD="$DEST/class/drm/card0"
rm -rf "$DEST"
mkdir -p "$CARD/device/hwmon/hwmon5"

w() { printf '%s\n' "$2" > "$1"; }

case "$PROFILE" in
  amd_*)
    w "$CARD/device/uevent" "DRIVER=amdgpu
PCI_SLOT_NAME=0000:03:00.0"
    w "$CARD/device/device" "$MOCK_PCI_ID"
    w "$CARD/device/gpu_busy_percent" "$MOCK_BUSY"
    w "$CARD/device/mem_info_vram_total" "$MOCK_VRAM_TOTAL"
    w "$CARD/device/mem_info_vram_used" "$MOCK_VRAM_USED"
    # So a geracao mais nova expoe isto: no perfil antigo o arquivo nao existe,
    # e a coluna mem_util_pct tem de sair vazia.
    [[ -n "$MOCK_MEM_BUSY" ]] && w "$CARD/device/mem_busy_percent" "$MOCK_MEM_BUSY"
    # pp_dpm_mclk lista os niveis e marca o ativo com "*".
    w "$CARD/device/pp_dpm_mclk" "0: 96Mhz
1: 456Mhz
$MOCK_CLK_MEM"
    w "$CARD/device/hwmon/hwmon5/name" "amdgpu"
    w "$CARD/device/hwmon/hwmon5/temp1_input" "$MOCK_TEMP"
    # O nome do arquivo de potencia muda entre placas: o backend procura os dois.
    w "$CARD/device/hwmon/hwmon5/$MOCK_POWER_FILE" "$MOCK_POWER"
    w "$CARD/device/hwmon/hwmon5/freq1_input" "$MOCK_CLK_SM"
    ;;

  intel_*)
    w "$CARD/device/uevent" "DRIVER=i915
PCI_SLOT_NAME=0000:03:00.0"
    w "$CARD/device/device" "$MOCK_PCI_ID"
    w "$CARD/$MOCK_FREQ_FILE" "$MOCK_FREQ"
    # VRAM so existe em placa dedicada. Numa integrada estes arquivos nao sao
    # criados, e as colunas vram_* tem de sair vazias - nao zeradas.
    if [[ -n "$MOCK_LMEM_TOTAL" ]]; then
      w "$CARD/lmem_total_bytes" "$MOCK_LMEM_TOTAL"
      w "$CARD/lmem_avail_bytes" "$MOCK_LMEM_AVAIL"
    fi
    w "$CARD/device/hwmon/hwmon5/name" "i915"
    [[ -n "$MOCK_TEMP" ]] && w "$CARD/device/hwmon/hwmon5/temp1_input" "$MOCK_TEMP"
    [[ -n "$MOCK_POWER" ]] && w "$CARD/device/hwmon/hwmon5/power1_input" "$MOCK_POWER"
    ;;

  nouveau_*)
    # Sem hwmon nenhum: e o que o nouveau com firmware GSP expoe. O render
    # node da placa aparece em device/drm/, e o no /dev falso ao lado da arvore.
    rm -rf "$CARD/device/hwmon"
    w "$CARD/device/uevent" "DRIVER=nouveau
PCI_SLOT_NAME=0000:01:00.0"
    w "$CARD/device/device" "$MOCK_PCI_ID"
    mkdir -p "$CARD/device/drm/renderD128" "$DEST/dev/dri"
    : > "$DEST/dev/dri/renderD128"
    ;;

  *)
    printf 'perfil sem regra de sysfs: %s\n' "$PROFILE" >&2; exit 1 ;;
esac

printf '%s\n' "$DEST/class/drm"
