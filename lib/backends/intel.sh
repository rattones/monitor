# shellcheck shell=bash
#
# intel.sh - backend Intel (i915/xe), via sysfs.
#
# ###########################################################################
# ATENCAO: ESCRITO SO A PARTIR DE DOCUMENTACAO - NUNCA RODOU EM HARDWARE.
#
# Nao ha GPU Intel na maquina de desenvolvimento, entao nada aqui foi
# verificado contra um device real: nem os caminhos, nem as unidades, nem o
# formato dos arquivos. Compare com lib/backends/amd.sh, cujos caminhos foram
# conferidos um a um contra o sysfs de uma Radeon Vega.
#
# O que conferir na primeira vez que isto rodar numa maquina Intel:
#
#   1. intel_probe encontra a placa? (DRIVER=i915 ou xe em card<N>/device/uevent)
#   2. Os caminhos de INTEL_CARDS apontam para arquivos que existem?
#      Rode com --debug-paths (abaixo) para imprimi-los sem coletar.
#   3. As unidades batem? Compare uma linha do CSV com os valores crus:
#        cat /sys/class/drm/card<N>/gt_cur_freq_mhz
#        cat /sys/class/drm/card<N>/device/hwmon/hwmon<N>/{temp1_input,power1_input}
#   4. Numa integrada, as colunas vram_* devem sair VAZIAS, nao zeradas.
#   5. gpu_util_pct provavelmente sai vazio (ver "OCUPACAO" abaixo).
#
# ###########################################################################
#
# ---------------------------------------------------------------------------
# DE ONDE VEM CADA METRICA (segundo a documentacao do i915/xe)
# ---------------------------------------------------------------------------
#
# Em /sys/class/drm/card<N>/, direto no card e nao no device/:
#
#   gt_cur_freq_mhz         -> sm_clock_mhz     (ja em MHz, sem conversao)
#   gt_act_freq_mhz         -> sm_clock_mhz     (alternativa: frequencia real)
#
# Em /sys/class/drm/card<N>/device/hwmon/hwmon<N>/ (quando existe):
#
#   temp1_input             -> temp_c           (milesimos de grau)
#   power1_input            -> power_w          (microwatts)
#   power1_average          -> power_w          (microwatts, alternativa)
#
# VRAM: so faz sentido em placas dedicadas (Arc, Flex), onde o driver expoe
# lmem_total_bytes / lmem_avail_bytes. Numa integrada a memoria e a RAM do
# sistema, e as colunas vram_* ficam vazias de proposito - preenche-las com o
# total da RAM diria algo que nao e verdade sobre a placa.
#
# ---------------------------------------------------------------------------
# OCUPACAO: A PARTE QUE O SYSFS NAO DA
# ---------------------------------------------------------------------------
#
# Nao existe um "gpu_busy_percent" como o do amdgpu. A ocupacao do nucleo vem
# dos contadores de perf do i915 (i915_pmu), que o intel_gpu_top le e que
# exigem CAP_PERFMON ou um perf_event_paranoid permissivo.
#
# Este backend NAO usa intel_gpu_top de proposito: seria uma dependencia
# externa, com privilegio e com saida propria para parsear. Le so o que o sysfs
# oferece sem privilegio, e deixa gpu_util_pct vazio quando nao ha fonte. Pelo
# contrato de colunas isso e legitimo - vazio e a ausencia de medida, nao zero.
#
# Se a ocupacao vier a ser necessaria, o caminho e ler "intel_gpu_top -J" (saida
# JSON) como produtor externo, no molde do nvidia-smi em nvidia.sh: nesse caso
# GPU_SRC_PID passa a ser preenchido e o stop() fecha pela fonte.
#
# ---------------------------------------------------------------------------
# VRAM POR PROCESSO
# ---------------------------------------------------------------------------
#
# Mesma situacao da AMD: sem equivalente ao "nvidia-smi -q -d PIDS". A via
# viavel e o fdinfo dos descritores de /dev/dri/* (linhas "drm-memory-*" ou
# "drm-total-*"), que e como o nvtop resolve, sem root. Por isso
# intel_supports_procs retorna 1: recusar o subcomando "proc" com uma mensagem
# clara e melhor do que gerar um CSV vazio.

# Um registro por placa, separado por ";". Mesmo formato do backend AMD:
#   indice|nome|busy|memtotal|memused|membusy|temp|power|sclk|mclk
# Um campo vazio significa "esta placa nao expoe esta metrica".
INTEL_CARDS=""

intel_name() { printf 'Intel'; }

# Uma GPU Intel e um card do DRM cujo driver e i915 (ou xe, nas recentes). O
# numero do card muda entre boots, entao a identificacao e sempre pelo driver.
# O glob exclui os conectores (card1-DP-1, card2-eDP-2...), que tambem vivem em
# /sys/class/drm mas nao sao placas.
intel_probe() {
  local c
  for c in "$DRM_ROOT"/card[0-9]*; do
    [[ -r "$c/device/uevent" ]] || continue
    grep -qE '^DRIVER=(i915|xe)$' "$c/device/uevent" 2>/dev/null && return 0
  done
  return 1
}

# Enquanto a VRAM por processo nao estiver implementada, dizer "nao sei fazer"
# e o comportamento correto: o core recusa o subcomando "proc" com explicacao.
intel_supports_procs() { return 1; }

# Primeiro arquivo legivel da lista, ou vazio. Deixa o init resolver uma vez o
# que varia entre placas e geracoes, sem repetir o teste a cada amostra.
_intel_first_readable() {
  local f
  for f in "$@"; do
    [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  printf ''
}

# Nome legivel da placa, no mesmo espirito do backend AMD: curto o bastante para
# caber numa coluna e numa legenda. lspci e opcional; sem ele, cai para o PCI ID.
_intel_card_name() {
  local slot="$1" dev="$2" line="" name=""

  # So aceita a linha do lspci se ela descrever mesmo um adaptador de video: o
  # slot vem do sysfs e normalmente bate, mas um slot que aponte para outra
  # coisa (ou um sysfs simulado em teste) daria a uma GPU o nome de uma placa
  # de rede, sem nenhum sinal de erro.
  if command -v lspci >/dev/null 2>&1; then
    line=$(lspci -s "${slot#0000:}" 2>/dev/null \
           | grep -iE '(VGA compatible|3D|Display) controller' \
           | sed 's/^[^ ]* //; s/^[^:]*: //')
    line=${line% (rev *)}
    # Ultimo "[...]" da linha, quando houver: costuma ser o modelo comercial.
    if [[ "$line" == *'['*']'* ]]; then
      name=${line##*[}
      name=${name%]}
    fi
    [[ -n "$name" ]] || name=${line#Intel Corporation }
  fi

  [[ -n "$name" ]] || name="GPU $dev"

  # Virgulas partiriam a coluna do CSV; espaco duplo vira simples.
  name=$(printf '%s' "$name" | sed 's/,/ /g; s/  */ /g; s/^ *//; s/ *$//')

  case "$name" in
    Intel*|Arc*) printf '%s' "$name" ;;
    *)           printf 'Intel %s' "$name" ;;
  esac
}

intel_init() {
  local c slot dev idx=0 hw name
  local busy memtot memused membusy temp power sclk mclk

  for c in "$DRM_ROOT"/card[0-9]*; do
    [[ -r "$c/device/uevent" ]] || continue
    grep -qE '^DRIVER=(i915|xe)$' "$c/device/uevent" 2>/dev/null || continue

    # O indice logico segue a ordem de enumeracao do sysfs, que e por bus id -
    # estavel entre execucoes na mesma maquina. --gpu seleciona por ele.
    if [[ -n "$GPU_IDX" && "$GPU_IDX" != "$idx" ]]; then
      idx=$((idx + 1))
      continue
    fi

    slot=$(grep -oP '(?<=^PCI_SLOT_NAME=).*' "$c/device/uevent" 2>/dev/null)
    dev=$(cat "$c/device/device" 2>/dev/null)
    name=$(_intel_card_name "$slot" "$dev")

    # Sem equivalente a gpu_busy_percent no sysfs: a ocupacao exige i915_pmu,
    # que este backend nao usa. A coluna sai vazia.
    busy=""
    membusy=""

    # VRAM so em placas dedicadas (Arc/Flex). Numa integrada estes arquivos nao
    # existem e as colunas ficam vazias, que e a resposta correta: a memoria
    # dela e a RAM do sistema, e nao VRAM da placa.
    memtot=$(_intel_first_readable "$c/lmem_total_bytes" "$c/device/lmem_total_bytes")
    memused=""
    if [[ -n "$memtot" ]]; then
      # O driver reporta o disponivel; o usado sai da subtracao, feita no awk.
      memused=$(_intel_first_readable "$c/lmem_avail_bytes" "$c/device/lmem_avail_bytes")
    fi

    # Frequencia: gt_cur_freq_mhz e a pedida, gt_act_freq_mhz a efetiva. Prefere
    # a efetiva quando existe, por ser a que de fato descreve o que aconteceu.
    sclk=$(_intel_first_readable \
      "$c/gt_act_freq_mhz" "$c/gt_cur_freq_mhz" \
      "$c/device/gt_act_freq_mhz" "$c/device/gt_cur_freq_mhz")

    # Clock de memoria: sem equivalente conhecido no i915/xe.
    mclk=""

    # O hwmon da placa: numerado pelo kernel, entao procura em vez de fixar.
    temp=""; power=""
    for hw in "$c"/device/hwmon/hwmon*; do
      [[ -d "$hw" ]] || continue
      temp=$(_intel_first_readable "$hw/temp1_input")
      power=$(_intel_first_readable "$hw/power1_average" "$hw/power1_input")
      [[ -n "$temp$power" ]] && break
    done

    INTEL_CARDS="${INTEL_CARDS:+$INTEL_CARDS;}$idx|$name|$busy|$memtot|$memused|$membusy|$temp|$power|$sclk|$mclk"
    GPU_COUNT=$((GPU_COUNT + 1))
    idx=$((idx + 1))
  done

  [[ -n "$INTEL_CARDS" ]] || die "nenhuma GPU Intel encontrada${GPU_IDX:+ no indice $GPU_IDX}"

  # Este backend nunca rodou em hardware: avisa uma vez, para quem vir uma
  # coluna estranha saber que o problema pode estar aqui, e nao na placa.
  if (( ! QUIET )); then
    printf 'aviso: o backend Intel nunca foi testado em hardware real.\n' >&2
    printf '       confira os valores contra o sysfs e reporte o que divergir.\n' >&2
    if [[ -z "$(printf '%s' "$INTEL_CARDS" | cut -d'|' -f3)" ]]; then
      printf '       gpu_util_pct sai vazio: a ocupacao exige i915_pmu (intel_gpu_top).\n' >&2
    fi
  fi
}

# Imprime os caminhos que o init resolveu, sem coletar nada. E o primeiro passo
# para conferir este backend numa maquina Intel: se um caminho sair vazio, a
# coluna correspondente vai sair vazia no CSV.
intel_debug_paths() {
  local rec
  printf 'placas encontradas: %s\n' "$GPU_COUNT"
  local IFS=';'
  for rec in $INTEL_CARDS; do
    IFS='|' read -r idx name busy memtot memused membusy temp power sclk mclk <<< "$rec"
    printf '\nGPU %s: %s\n' "$idx" "$name"
    printf '  gpu_util_pct   %s\n' "${busy:-<sem fonte: exige i915_pmu>}"
    printf '  mem_util_pct   %s\n' "${membusy:-<sem fonte>}"
    printf '  vram_total     %s\n' "${memtot:-<sem fonte: integrada?>}"
    printf '  vram_avail     %s\n' "${memused:-<sem fonte: integrada?>}"
    printf '  temp_c         %s\n' "${temp:-<sem fonte>}"
    printf '  power_w        %s\n' "${power:-<sem fonte>}"
    printf '  sm_clock_mhz   %s\n' "${sclk:-<sem fonte>}"
    printf '  mem_clock_mhz  %s\n' "${mclk:-<sem equivalente no i915/xe>}"
  done
}

intel_start_gpu() {
  # O CSV ja existe aqui (o core o abriu com o cabecalho): marcar o tamanho
  # agora faz o total do fim contar so esta sessao.
  INTEL_GPU_SKIP=$(wc -l < "$OUTPUT" 2>/dev/null || printf 0)

  LC_ALL=C awk -v out="$OUTPUT" -v cards="$INTEL_CARDS" -v quiet="$QUIET" \
               -v iv="$INTERVAL_S" -v dur="$DURATION" '
  function uptime(   l, a) {
    getline l < "/proc/uptime"; close("/proc/uptime")
    split(l, a, " ")
    return a[1] + 0
  }

  # Milissegundos junto do horario, para casar com o timestamp dos outros
  # backends. O %3N do GNU date trunca em 3 digitos, mas o do uutils coreutils
  # devolve os 9 de nanossegundos - cortar aqui deixa igual nos dois casos.
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

  function emit(i,   ts, busy, vtot, vavail, vused, vfree, vpct, mbusy, t, p, cs, cm) {
    ts = now()

    busy  = rd(f_busy[i])
    mbusy = rd(f_membusy[i])
    vtot  = rd(f_memtot[i])
    vavail = rd(f_memused[i])
    t     = rd(f_temp[i])
    p     = rd(f_power[i])
    cs    = rd(f_sclk[i])
    cm    = ""

    # Conversoes, preservando o vazio quando a metrica nao existe.
    # gt_*_freq_mhz ja vem em MHz: diferente do amdgpu, nao se divide por nada.
    vused = ""
    if (vtot != "") {
      # O driver reporta o disponivel, nao o usado.
      if (vavail != "") vused = sprintf("%.0f", (vtot - vavail) / 1048576)
      vtot = sprintf("%.0f", vtot / 1048576)
    }
    if (t != "") t = sprintf("%.0f", t / 1000)
    if (p != "") p = sprintf("%.2f", p / 1000000)

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

    # A primeira amostra sai imediatamente: cada leitura ja e um valor absoluto,
    # nao um delta que precise de uma base anterior.
    for (i = 1; i <= nc; i++) emit(i)

    t0 = uptime(); target = t0
    if (dur > 0 && dur <= 0.05) exit

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
  }
  ' &
  GPU_AWK_PID=$!
}

# Quantas linhas o CSV tinha antes desta sessao, para o total ser da coleta atual.
INTEL_GPU_SKIP=0

# Sem produtor externo, o awk e morto direto no Ctrl+C e um bloco END nunca
# chegaria a rodar (mawk nao tem handler de sinal). Por isso o total sai aqui,
# contando o que foi realmente gravado.
intel_report_gpu() {
  (( QUIET )) && return 0
  [[ -s "$OUTPUT" ]] || return 0
  local total
  total=$(( $(wc -l < "$OUTPUT") - INTEL_GPU_SKIP ))
  (( total > 0 )) || return 0
  printf '\n%d amostras gravadas.\n' "$total" >&2
  return 0
}

intel_start_proc() {
  die "backend Intel nao coleta VRAM por processo (use --procs off ou o subcomando gpu)"

  # TODO: via fdinfo dos descritores de /dev/dri/*, como descrito no cabecalho.
  # Quando existir, intel_supports_procs passa a retornar 0.
}

intel_list_procs() {
  : # Sem coleta de processos, nao ha o que listar.
}
