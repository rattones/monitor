# shellcheck shell=bash
#
# amd.sh - backend AMD, via sysfs do driver amdgpu.  *** ESQUELETO ***
#
# Nada aqui coleta de verdade ainda: as funcoes existem para satisfazer o
# contrato de backend.sh e para guardar o que ja foi levantado sobre onde os
# dados moram. O _probe ja funciona, entao a autodeteccao ve este backend.
#
# ---------------------------------------------------------------------------
# DE ONDE VEM CADA METRICA
# ---------------------------------------------------------------------------
#
# Tudo em /sys/class/drm/card<N>/device/, legivel sem root:
#
#   gpu_busy_percent        -> gpu_util_pct     (% de tempo ocupado)
#   mem_info_vram_total     -> vram_total_mib   (bytes; dividir por 1048576)
#   mem_info_vram_used      -> vram_used_mib    (bytes)
#   mem_busy_percent        -> mem_util_pct     (nem toda placa expoe)
#
# E em device/hwmon/hwmon<N>/:
#
#   temp1_input             -> temp_c           (milesimos de grau)
#   power1_average          -> power_w          (microwatts; APU costuma nao ter)
#   freq1_input             -> sm_clock_mhz     (Hz)
#   freq2_input             -> mem_clock_mhz    (Hz, quando existe)
#
# Medido numa Radeon Vega (Cezanne, APU) em 2026-09-16: gpu_busy_percent,
# mem_info_vram_{total,used}, temp1_input e freq1_input existem; mem_busy_percent
# e power1_average nao. Placas dedicadas costumam ter os dois, entao trate cada
# metrica como opcional e escreva celula vazia quando o arquivo nao existir.
#
# ---------------------------------------------------------------------------
# COMO A COLETA DEVE FUNCIONAR
# ---------------------------------------------------------------------------
#
# Nao ha um "nvidia-smi -lms" aqui: sysfs sao arquivos, nao um fluxo. O modelo a
# seguir e o de disk.sh, que ja resolve exatamente esse problema - um awk que
# cadencia o proprio loop dormindo ate o proximo instante-alvo, em vez de dormir
# um intervalo cheio depois do trabalho (o que acumularia drift e desalinharia
# as amostras das outras coletas). Como nao ha produtor externo, GPU_SRC_PID
# fica vazio e so GPU_AWK_PID e preenchido.
#
# ---------------------------------------------------------------------------
# VRAM POR PROCESSO
# ---------------------------------------------------------------------------
#
# Nao ha equivalente ao "nvidia-smi -q -d PIDS". As duas vias conhecidas:
#
#   - /sys/kernel/debug/dri/<N>/amdgpu_gem_info, que lista as alocacoes por
#     processo, mas fica em debugfs e exige root;
#   - /proc/<pid>/fdinfo/<fd> dos descritores de /dev/dri/*, que trazem linhas
#     "drm-memory-vram:" por processo. E a via do nvtop e nao precisa de root,
#     mas exige varrer todos os PIDs a cada amostra.
#
# Por isso amd_supports_procs ainda retorna 1: e melhor recusar o subcomando
# "proc" com uma mensagem clara do que gerar um CSV vazio.

AMD_CARDS=""   # "0=/sys/class/drm/card2;..." - indice logico -> caminho do device

amd_name() { printf 'AMD'; }

# Uma GPU AMD e um card do DRM cujo driver e amdgpu. O numero do card muda entre
# boots, entao a identificacao e sempre pelo driver, nunca pelo numero.
amd_probe() {
  local c
  for c in /sys/class/drm/card[0-9]*; do
    [[ -r "$c/device/uevent" ]] || continue
    grep -q '^DRIVER=amdgpu$' "$c/device/uevent" 2>/dev/null && return 0
  done
  return 1
}

# Enquanto a VRAM por processo nao estiver implementada, dizer "nao sei fazer"
# e o comportamento correto: o core recusa o subcomando "proc" com explicacao.
amd_supports_procs() { return 1; }

amd_init() {
  die "backend AMD ainda nao implementado (so o esqueleto existe)"

  # TODO: varrer /sys/class/drm/card[0-9]*, manter os que tem DRIVER=amdgpu,
  # ordenar por bus id para o indice logico ser estavel entre execucoes, aplicar
  # --gpu quando informado, preencher AMD_CARDS e GPU_COUNT, e localizar o hwmon
  # de cada placa (device/hwmon/hwmon*) uma unica vez, como disk_temp_file faz.
}

amd_start_gpu() {
  die "backend AMD ainda nao implementado (so o esqueleto existe)"

  # TODO: um awk no molde de start_disk() - cadencia propria por instante-alvo,
  # lendo os arquivos de AMD_CARDS a cada amostra e escrevendo as colunas de
  # GPU_CSV_HEADER em $OUTPUT. Converter: bytes -> MiB, milesimos de grau -> C,
  # microwatts -> W, Hz -> MHz. Arquivo ausente vira celula vazia. Preencher
  # GPU_AWK_PID (GPU_SRC_PID fica vazio: nao ha produtor externo).
}

amd_start_proc() {
  die "backend AMD nao coleta VRAM por processo (use --procs off ou outro subcomando)"

  # TODO: varrer /proc/*/fdinfo/* procurando descritores de /dev/dri/* e somar
  # as linhas "drm-memory-vram:" por PID, como o nvtop faz. Respeitar
  # PROCS_MODE e os filtros, e escrever as colunas de PROCS_CSV_HEADER.
  # Quando isso existir, amd_supports_procs passa a retornar 0.
}

amd_list_procs() {
  : # TODO: sem coleta de processos, nao ha o que listar.
}
