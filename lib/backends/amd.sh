# shellcheck shell=bash
#
# amd.sh - backend AMD, via sysfs do driver amdgpu.
#
# Nao ha um "nvidia-smi -lms" aqui: sysfs sao arquivos, nao um fluxo. Por isso o
# coletor segue o molde do disk.sh - um awk que cadencia o proprio loop dormindo
# ate o proximo instante-alvo, em vez de dormir um intervalo cheio depois do
# trabalho (o que acumularia drift e desalinharia as amostras das outras
# coletas). Como nao ha produtor externo, GPU_SRC_PID fica vazio.
#
# ---------------------------------------------------------------------------
# DE ONDE VEM CADA METRICA
# ---------------------------------------------------------------------------
#
# Em /sys/class/drm/card<N>/device/, tudo legivel sem root:
#
#   gpu_busy_percent        -> gpu_util_pct     (%)
#   mem_busy_percent        -> mem_util_pct     (%, nem toda placa expoe)
#   mem_info_vram_total     -> vram_total_mib   (bytes)
#   mem_info_vram_used      -> vram_used_mib    (bytes)
#   pp_dpm_mclk             -> mem_clock_mhz    (linha marcada com "*")
#
# E em device/hwmon/hwmon<N>/:
#
#   temp1_input             -> temp_c           (milesimos de grau)
#   power1_input            -> power_w          (microwatts)
#   power1_average          -> power_w          (microwatts, alternativa)
#   freq1_input             -> sm_clock_mhz     (Hz)
#
# Medido numa Radeon Vega (Cezanne, APU, PCI 1002:1638) em 2026-09-16: todos
# existem menos mem_busy_percent. Note que esta APU expoe power1_input, e nao
# power1_average - placas diferentes usam um ou outro, entao o init procura os
# dois. Cada metrica e opcional: arquivo ausente vira celula vazia, nunca zero.
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

# Um registro por placa, separado por ";". Cada registro traz os caminhos ja
# resolvidos, para o awk nao precisar procurar arquivo dentro do laco:
#   indice|nome|busy|memtotal|memused|membusy|temp|power|sclk|mclk
# Um campo vazio significa "esta placa nao expoe esta metrica".
AMD_CARDS=""

amd_name() { printf 'AMD'; }

# Uma GPU AMD e um card do DRM cujo driver e amdgpu. O numero do card muda entre
# boots, entao a identificacao e sempre pelo driver, nunca pelo numero. O glob
# exclui os conectores (card1-DP-1, card2-eDP-2...), que tambem vivem em
# /sys/class/drm mas nao sao placas.
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

# Primeiro arquivo legivel da lista, ou vazio. Deixa o init resolver uma vez o
# que varia entre placas (power1_input x power1_average) sem repetir o teste a
# cada amostra.
_amd_first_readable() {
  local f
  for f in "$@"; do
    [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  printf ''
}

# Nome legivel da placa, no mesmo espirito do que o nvidia-smi devolve: curto o
# bastante para caber numa coluna e numa legenda de grafico.
#
# O lspci devolve a linha inteira do fabricante:
#   "Advanced Micro Devices, Inc. [AMD/ATI] Cezanne [Radeon Vega Series ...]"
# O que identifica a placa e o ultimo trecho entre colchetes, entao e ele que
# vira o nome ("Radeon Vega Series ..."), prefixado por "AMD".
#
# lspci e opcional: sem ele, ou sem a base pci.ids, cai para o PCI ID cru, que
# ainda identifica o modelo para quem for pesquisar.
_amd_card_name() {
  local slot="$1" dev="$2" line="" name=""

  if command -v lspci >/dev/null 2>&1; then
    line=$(lspci -s "${slot#0000:}" 2>/dev/null | sed 's/^[^ ]* //; s/^[^:]*: //')
    line=${line% (rev *)}
    # Ultimo "[...]" da linha: o modelo comercial.
    if [[ "$line" == *'['*']'* ]]; then
      name=${line##*[}
      name=${name%]}
    fi
    # Sem colchetes, usa a linha toda sem o nome do fabricante.
    [[ -n "$name" ]] || name=${line#Advanced Micro Devices Inc. }
  fi

  [[ -n "$name" ]] || name="GPU $dev"

  # Virgulas partiriam a coluna do CSV; espaco duplo vira simples.
  name=$(printf '%s' "$name" | sed 's/,/ /g; s/  */ /g; s/^ *//; s/ *$//')

  # "AMD" na frente, a menos que o modelo ja diga de quem e.
  case "$name" in
    AMD*|Radeon*) printf '%s' "$name" ;;
    *)            printf 'AMD %s' "$name" ;;
  esac
}

amd_init() {
  local c slot dev idx=0 hw name
  local busy memtot memused membusy temp power sclk mclk

  for c in /sys/class/drm/card[0-9]*; do
    [[ -r "$c/device/uevent" ]] || continue
    grep -q '^DRIVER=amdgpu$' "$c/device/uevent" 2>/dev/null || continue

    # O indice logico segue a ordem de enumeracao do sysfs, que e por bus id -
    # estavel entre execucoes na mesma maquina. --gpu seleciona por ele.
    if [[ -n "$GPU_IDX" && "$GPU_IDX" != "$idx" ]]; then
      idx=$((idx + 1))
      continue
    fi

    slot=$(grep -oP '(?<=^PCI_SLOT_NAME=).*' "$c/device/uevent" 2>/dev/null)
    dev=$(cat "$c/device/device" 2>/dev/null)
    name=$(_amd_card_name "$slot" "$dev")

    busy=$(_amd_first_readable "$c/device/gpu_busy_percent")
    membusy=$(_amd_first_readable "$c/device/mem_busy_percent")
    memtot=$(_amd_first_readable "$c/device/mem_info_vram_total")
    memused=$(_amd_first_readable "$c/device/mem_info_vram_used")
    mclk=$(_amd_first_readable "$c/device/pp_dpm_mclk")

    # O hwmon da placa: numerado pelo kernel, entao procura em vez de fixar.
    temp=""; power=""; sclk=""
    for hw in "$c"/device/hwmon/hwmon*; do
      [[ -d "$hw" ]] || continue
      temp=$(_amd_first_readable "$hw/temp1_input")
      # Placas diferentes expoem um ou outro: esta APU tem power1_input,
      # varias dedicadas tem power1_average.
      power=$(_amd_first_readable "$hw/power1_average" "$hw/power1_input")
      sclk=$(_amd_first_readable "$hw/freq1_input")
      [[ -n "$temp$power$sclk" ]] && break
    done

    AMD_CARDS="${AMD_CARDS:+$AMD_CARDS;}$idx|$name|$busy|$memtot|$memused|$membusy|$temp|$power|$sclk|$mclk"
    GPU_COUNT=$((GPU_COUNT + 1))
    idx=$((idx + 1))
  done

  [[ -n "$AMD_CARDS" ]] || die "nenhuma GPU AMD encontrada${GPU_IDX:+ no indice $GPU_IDX}"
}

amd_start_gpu() {
  # O CSV ja existe aqui (o core o abriu com o cabecalho): marcar o tamanho
  # agora faz o total do fim contar so esta sessao, e nao um arquivo que veio
  # de uma coleta anterior por append.
  AMD_GPU_SKIP=$(wc -l < "$OUTPUT" 2>/dev/null || printf 0)

  LC_ALL=C awk -v out="$OUTPUT" -v cards="$AMD_CARDS" -v quiet="$QUIET" \
               -v iv="$INTERVAL_S" -v dur="$DURATION" '
  function uptime(   l, a) {
    getline l < "/proc/uptime"; close("/proc/uptime")
    split(l, a, " ")
    return a[1] + 0
  }

  # Milissegundos junto do horario, para casar com o timestamp do backend NVIDIA.
  #
  # O %3N do GNU date trunca a fracao em 3 digitos, mas o do uutils coreutils
  # (Rust, padrao em algumas distros) devolve os 9 digitos de nanossegundos.
  # Cortar aqui deixa o formato igual nos dois casos.
  function now(   cmd, t, p) {
    cmd = "date +%Y-%m-%dT%H:%M:%S.%3N"
    cmd | getline t
    close(cmd)
    p = index(t, ".")
    if (p > 0) t = substr(t, 1, p + 3)
    return t
  }

  # Le um numero de um arquivo de sysfs. Caminho vazio (metrica que esta placa
  # nao expoe) ou leitura falha viram "", que o CSV grava como celula vazia -
  # zero seria uma medida, e nao a ausencia dela.
  function rd(path,   v, ok) {
    if (path == "") return ""
    ok = (getline v < path)
    close(path)
    if (ok <= 0) return ""
    return v
  }

  # pp_dpm_mclk lista os niveis e marca o ativo com "*":
  #   2: 400Mhz
  #   3: 1600Mhz *
  function active_clk(path,   line, n, f, v) {
    if (path == "") return ""
    v = ""
    while ((getline line < path) > 0) {
      if (line !~ /\*/) continue
      n = split(line, f, " ")
      if (n >= 2) { v = f[2]; sub(/[Mm][Hh]z$/, "", v) }
      break
    }
    close(path)
    return v
  }

  function emit(i,   ts, busy, vtot, vused, vfree, vpct, mbusy, t, p, cs, cm) {
    ts = now()

    busy  = rd(f_busy[i])
    mbusy = rd(f_membusy[i])
    vtot  = rd(f_memtot[i])
    vused = rd(f_memused[i])
    t     = rd(f_temp[i])
    p     = rd(f_power[i])
    cs    = rd(f_sclk[i])
    cm    = active_clk(f_mclk[i])

    # Conversoes para as unidades do CSV, preservando o vazio quando a metrica
    # nao existe: bytes -> MiB, milesimos de grau -> C, microwatts -> W, Hz -> MHz.
    if (vtot  != "") vtot  = sprintf("%.0f", vtot  / 1048576)
    if (vused != "") vused = sprintf("%.0f", vused / 1048576)
    if (t     != "") t     = sprintf("%.0f", t / 1000)
    if (p     != "") p     = sprintf("%.2f", p / 1000000)
    if (cs    != "") cs    = sprintf("%.0f", cs / 1000000)

    vfree = ""; vpct = ""
    if (vtot != "" && vused != "") {
      vfree = vtot - vused
      vpct  = (vtot + 0 > 0) ? sprintf("%.1f", vused * 100.0 / vtot) : ""
    }

    printf("%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
           ts, idx[i], name[i], busy, mbusy, vtot, vused, vfree, vpct,
           t, p, cs, cm) >> out
    fflush(out)
    rows++

    if (!quiet) {
      printf("%s  GPU%s  util %3s%%   vram %5s/%s MiB (%4s%%)   temp %3s C   %6s W\n",
             substr(ts, 12, 8), idx[i],
             (busy  == "" ? "-" : busy),
             (vused == "" ? "-" : vused),
             (vtot  == "" ? "-" : vtot),
             (vpct  == "" ? "-" : vpct),
             (t     == "" ? "-" : t),
             (p     == "" ? "-" : p))
      fflush("")
    }
  }

  BEGIN {
    nc = split(cards, rec, ";")
    for (i = 1; i <= nc; i++) {
      split(rec[i], c, "|")
      idx[i] = c[1]; name[i] = c[2]
      f_busy[i] = c[3]; f_memtot[i] = c[4]; f_memused[i] = c[5]
      f_membusy[i] = c[6]; f_temp[i] = c[7]; f_power[i] = c[8]
      f_sclk[i] = c[9]; f_mclk[i] = c[10]
    }

    # A primeira amostra sai imediatamente: diferente do disco, aqui cada leitura
    # ja e um valor absoluto, nao um delta que precise de uma base anterior.
    for (i = 1; i <= nc; i++) emit(i)

    t0 = uptime(); target = t0
    if (dur > 0 && dur <= 0.05) { finish(); exit }

    while (1) {
      # Dorme ate o proximo instante-alvo, e nao um intervalo cheio: ler sysfs e
      # chamar date custa tempo, e dormir "iv" depois disso empurraria cada
      # amostra para frente ate desalinhar das linhas do disco.
      target += iv
      slp = target - uptime()
      if (slp > 0) system("sleep " slp)

      for (i = 1; i <= nc; i++) emit(i)

      if (dur > 0 && uptime() - t0 >= dur - 0.05) break
    }
    finish()
  }

  function finish() { }
  ' &
  GPU_AWK_PID=$!
}

# Quantas linhas o CSV tinha antes desta sessao, para o total ser da coleta atual
# e nao somar um arquivo reaproveitado por append.
AMD_GPU_SKIP=0

# O awk do AMD nao tem produtor externo: no Ctrl+C ele e morto direto, e um
# bloco END nunca chegaria a rodar (mawk nao tem handler de sinal). Por isso o
# total sai aqui, contando o que foi realmente gravado - mesmo caminho que o
# core ja usa para os resumos de processo e disco.
amd_report_gpu() {
  (( QUIET )) && return 0
  [[ -s "$OUTPUT" ]] || return 0
  local total
  total=$(( $(wc -l < "$OUTPUT") - AMD_GPU_SKIP ))
  (( total > 0 )) || return 0
  printf '\n%d amostras gravadas.\n' "$total" >&2
  return 0
}

amd_start_proc() {
  die "backend AMD nao coleta VRAM por processo (use --procs off ou o subcomando gpu)"

  # TODO: varrer /proc/*/fdinfo/* procurando descritores de /dev/dri/* e somar
  # as linhas "drm-memory-vram:" por PID, como o nvtop faz. Respeitar
  # PROCS_MODE e os filtros, e escrever as colunas de PROCS_CSV_HEADER.
  # Quando isso existir, amd_supports_procs passa a retornar 0.
}

amd_list_procs() {
  : # Sem coleta de processos, nao ha o que listar.
}
