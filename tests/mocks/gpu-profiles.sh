# shellcheck shell=bash
#
# gpu-profiles.sh - os dados de hardware que os mocks reproduzem.
#
# Dois niveis por fabricante, escolhidos para exercitar caminhos diferentes do
# codigo, e nao so para variar numeros:
#
#   moderna - reporta tudo. E o caso facil: toda coluna do CSV preenchida.
#   antiga  - nao reporta uma parte. E o caso que importa, porque e onde o
#             contrato "metrica ausente vira celula vazia, nunca zero" ou
#             funciona ou quebra.
#
# O que cada nivel deixa de fora nao e invencao: e o que aquela geracao de fato
# nao expoe.
#
#   NVIDIA  GTX 1050 (Pascal, 2016): nvidia-smi devolve "[N/A]" em power.draw
#           nas placas sem o sensor. E o unico campo ausente - o resto da
#           consulta funciona igual ao de uma placa nova.
#   AMD     Polaris (RX 560, 2016): sem mem_busy_percent no amdgpu, como a
#           Vega desta maquina; e com power1_average em vez de power1_input,
#           que e a variante que o backend tambem precisa achar.
#   Intel   HD 630 (Kaby Lake, 2017): integrada, entao sem lmem_* (a memoria
#           e a RAM do sistema) e sem hwmon de potencia. So clock e, as vezes,
#           temperatura.
#
# Cada perfil e uma funcao que exporta as variaveis que os mocks consomem.

# --- NVIDIA ---------------------------------------------------------------

# RTX 4070 (Ada, 2023): 12 GiB, reporta potencia e os dois clocks.
profile_nvidia_moderna() {
  MOCK_GPU_NAME="NVIDIA GeForce RTX 4070"
  MOCK_GPU_BUS="00000000:01:00.0"
  MOCK_VRAM_TOTAL=12282
  MOCK_VRAM_USED=3204
  MOCK_UTIL_GPU=78
  MOCK_UTIL_MEM=41
  MOCK_TEMP=63
  MOCK_POWER="182.45"      # reporta potencia
  MOCK_CLK_SM=2610
  MOCK_CLK_MEM=10501
}

# GTX 1050 (Pascal, 2016): 2 GiB e, nesta variante, sem sensor de potencia -
# o nvidia-smi devolve "[N/A]", que o backend precisa virar celula vazia.
profile_nvidia_antiga() {
  MOCK_GPU_NAME="NVIDIA GeForce GTX 1050"
  MOCK_GPU_BUS="00000000:01:00.0"
  MOCK_VRAM_TOTAL=2048
  MOCK_VRAM_USED=764
  MOCK_UTIL_GPU=45
  MOCK_UTIL_MEM=22
  MOCK_TEMP=58
  MOCK_POWER="[N/A]"       # sem sensor: o caso que exercita o vazio
  MOCK_CLK_SM=1455
  MOCK_CLK_MEM=3504
}

# --- AMD ------------------------------------------------------------------
#
# Valores em unidades de sysfs: VRAM em bytes, temperatura em milesimos de
# grau, potencia em microwatts, clock em Hz. A conversao e do backend.

# RX 7800 XT (RDNA 3, 2023): 16 GiB, expoe mem_busy_percent e power1_input.
profile_amd_moderna() {
  MOCK_GPU_NAME="Radeon RX 7800 XT"
  MOCK_PCI_ID="0x747e"
  MOCK_VRAM_TOTAL=17179869184     # 16 GiB
  MOCK_VRAM_USED=5368709120       # 5 GiB
  MOCK_BUSY=82
  MOCK_MEM_BUSY=57                # expoe mem_busy_percent
  MOCK_TEMP=68000                 # 68 C
  MOCK_POWER=241000000            # 241 W
  MOCK_POWER_FILE="power1_input"
  MOCK_CLK_SM=2430000000          # 2430 MHz
  MOCK_CLK_MEM="2: 2425Mhz *"
}

# RX 560 (Polaris, 2016): 4 GiB, sem mem_busy_percent e com power1_average -
# a variante de nome que o backend tambem precisa encontrar.
profile_amd_antiga() {
  MOCK_GPU_NAME="Radeon RX 560 Series"
  MOCK_PCI_ID="0x67ef"
  MOCK_VRAM_TOTAL=4294967296      # 4 GiB
  MOCK_VRAM_USED=1073741824       # 1 GiB
  MOCK_BUSY=51
  MOCK_MEM_BUSY=""                # ausente nesta geracao
  MOCK_TEMP=72000                 # 72 C
  MOCK_POWER=78000000             # 78 W
  MOCK_POWER_FILE="power1_average" # o outro nome de arquivo
  MOCK_CLK_SM=1275000000          # 1275 MHz
  MOCK_CLK_MEM="1: 1750Mhz *"
}

# --- Intel ----------------------------------------------------------------

# Arc A770 (Alchemist, 2022): dedicada, entao tem lmem_* e hwmon completo.
profile_intel_moderna() {
  MOCK_GPU_NAME="Intel Arc A770"
  MOCK_PCI_ID="0x56a0"
  MOCK_LMEM_TOTAL=17179869184     # 16 GiB
  MOCK_LMEM_AVAIL=12884901888     # 12 GiB livres -> 4 GiB usados
  MOCK_TEMP=61000                 # 61 C
  MOCK_POWER=190000000            # 190 W
  MOCK_FREQ=2100                  # ja em MHz no i915
  MOCK_FREQ_FILE="gt_act_freq_mhz"
}

# HD Graphics 630 (Kaby Lake, 2017): integrada. Sem lmem_* (a memoria e a RAM
# do sistema) e sem potencia; so o clock, e temperatura quando ha hwmon.
profile_intel_antiga() {
  MOCK_GPU_NAME="HD Graphics 630"
  MOCK_PCI_ID="0x5912"
  MOCK_LMEM_TOTAL=""              # integrada: nao existe
  MOCK_LMEM_AVAIL=""
  MOCK_TEMP=54000                 # 54 C
  MOCK_POWER=""                   # sem sensor de potencia
  MOCK_FREQ=1150
  MOCK_FREQ_FILE="gt_cur_freq_mhz" # so a frequencia pedida, sem gt_act_*
}

# --- NVIDIA no nouveau (NVK) ------------------------------------------------
#
# Valores em bytes, como o sampler recebe do vulkaninfo. O nouveau com GSP nao
# tem hwmon, busy nem clocks: essas colunas saem vazias em qualquer placa.

# RTX 3050 Laptop (GA107, 2021), medida nesta maquina: 4 GiB, NVK com
# VK_EXT_memory_budget, entao a VRAM usada existe.
profile_nouveau_moderna() {
  MOCK_GPU_NAME="GeForce RTX 3050 Mobile"
  MOCK_PCI_ID="0x25e2"
  MOCK_VRAM_TOTAL=4294967296      # 4 GiB
  MOCK_VRAM_USED=805306368        # 768 MiB
}

# GTX 1050 (Pascal, 2016) num Mesa sem o budget: o vulkaninfo nao mostra o
# heap com budget, e a VRAM inteira tem de sair vazia - nao zero.
profile_nouveau_antiga() {
  MOCK_GPU_NAME="GeForce GTX 1050"
  MOCK_PCI_ID="0x1c81"
  MOCK_VRAM_TOTAL=""
  MOCK_VRAM_USED=""
}

# --- processos na GPU ------------------------------------------------------
#
# Usados pelo mock do nvidia-smi -q -d PIDS. Os tipos cobrem os tres casos que
# o backend trata de forma diferente: G (grafico), C (compute) e C+G (ambos),
# que o modo --procs compute precisa manter.
MOCK_PROCS=(
  "1615|G|/usr/lib/xorg/Xorg|61"
  "4892|G|/opt/google/chrome/chrome --type=gpu-process|185"
  "60282|C+G|/usr/games/dota2|1404"
  "77001|C|/usr/bin/python3 train.py --batch 64|2048"
)
