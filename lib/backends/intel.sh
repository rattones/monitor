# shellcheck shell=bash
#
# intel.sh - backend Intel (i915/xe).  *** ESQUELETO ***
#
# Nada aqui coleta de verdade ainda: as funcoes existem para satisfazer o
# contrato de backend.sh e para guardar o que ja foi levantado. O _probe ja
# funciona, entao a autodeteccao ve este backend.
#
# AVISO: diferente do backend AMD, nada disto foi verificado em hardware real -
# nao ha GPU Intel na maquina de desenvolvimento. Os caminhos abaixo vem da
# documentacao e precisam ser conferidos antes de virar codigo.
#
# ---------------------------------------------------------------------------
# POR QUE E O MAIS TRABALHOSO DOS TRES
# ---------------------------------------------------------------------------
#
# Nao existe um "gpu_busy_percent" universal como o do amdgpu. O que ha varia
# bastante entre gerações e entre os drivers i915 (mais antigo) e xe (recente):
#
#   - Ocupacao do nucleo: a fonte usual sao os contadores de perf do i915
#     (i915_pmu), que o intel_gpu_top le. Exige CAP_PERFMON ou
#     perf_event_paranoid permissivo, entao pode falhar sem privilegio.
#   - VRAM: so faz sentido em placas dedicadas (Arc, Flex). Numa integrada a
#     memoria e a RAM do sistema, e as colunas vram_* devem ficar vazias em vez
#     de repetir o total da RAM, que nao e a mesma coisa.
#   - Temperatura e potencia: quando existem, aparecem em
#     /sys/class/drm/card<N>/device/hwmon/hwmon<N>/, como no amdgpu.
#   - Frequencia: /sys/class/drm/card<N>/gt_cur_freq_mhz (i915) ja vem em MHz.
#
# Antes de implementar, decidir se o backend depende do binario intel_gpu_top
# (pacote intel-gpu-tools, tem saida -J em JSON) ou se le so o que sysfs oferece
# sem privilegio. A segunda via e mais portavel e nao exige instalar nada, mas
# nao entrega ocupacao do nucleo em toda geracao - possivelmente deixando
# gpu_util_pct vazio, o que e aceitavel pelo contrato de colunas.
#
# ---------------------------------------------------------------------------
# VRAM POR PROCESSO
# ---------------------------------------------------------------------------
#
# Mesma situacao da AMD: sem equivalente ao "nvidia-smi -q -d PIDS". A via
# viavel e o fdinfo dos descritores de /dev/dri/* (linhas "drm-memory-*"),
# que e como o nvtop resolve. Por isso intel_supports_procs retorna 1 por
# enquanto.

INTEL_CARDS=""   # "0=/sys/class/drm/card1;..." - indice logico -> caminho do device

intel_name() { printf 'Intel'; }

# Uma GPU Intel e um card do DRM cujo driver e i915 (ou xe, nas recentes).
# O numero do card muda entre boots: identificar pelo driver, nunca pelo numero.
intel_probe() {
  local c
  for c in /sys/class/drm/card[0-9]*; do
    [[ -r "$c/device/uevent" ]] || continue
    grep -qE '^DRIVER=(i915|xe)$' "$c/device/uevent" 2>/dev/null && return 0
  done
  return 1
}

# Enquanto a VRAM por processo nao estiver implementada, dizer "nao sei fazer"
# e o comportamento correto: o core recusa o subcomando "proc" com explicacao.
intel_supports_procs() { return 1; }

intel_init() {
  die "backend Intel ainda nao implementado (so o esqueleto existe)"

  # TODO: varrer /sys/class/drm/card[0-9]*, manter os que tem DRIVER=i915 ou xe,
  # ordenar por bus id, aplicar --gpu, preencher INTEL_CARDS e GPU_COUNT.
  # Detectar aqui, uma vez so, quais metricas esta maquina oferece (hwmon
  # presente? gt_cur_freq_mhz legivel? i915_pmu acessivel?) e guardar o
  # resultado, em vez de testar a cada amostra.
}

intel_start_gpu() {
  die "backend Intel ainda nao implementado (so o esqueleto existe)"

  # TODO: mesmo molde de start_disk() - awk com cadencia propria por
  # instante-alvo. Escrever as colunas de GPU_CSV_HEADER, deixando vazias as
  # metricas que esta geracao nao expoe (numa integrada, as colunas vram_*).
  # Preencher GPU_AWK_PID; GPU_SRC_PID so se um produtor externo for usado.
}

intel_start_proc() {
  die "backend Intel nao coleta VRAM por processo (use --procs off ou outro subcomando)"

  # TODO: via fdinfo, como descrito no cabecalho. Quando existir,
  # intel_supports_procs passa a retornar 0.
}

intel_list_procs() {
  : # TODO: sem coleta de processos, nao ha o que listar.
}
