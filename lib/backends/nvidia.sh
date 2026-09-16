# shellcheck shell=bash
#
# nvidia.sh - backend NVIDIA, via nvidia-smi.
#
# E o unico backend que hoje atribui VRAM por processo: o nvidia-smi reporta
# isso direto, enquanto AMD e Intel exigem caminhos bem menos diretos (ver os
# comentarios em amd.sh e intel.sh).

NVIDIA_SMI_TARGET=()   # (-i IDX) quando --gpu foi usado
NVIDIA_NAMES=""        # "0=GeForce RTX 3050;1=..." - indice -> nome
NVIDIA_BUSMAP=""       # "00000000:01:00.0=0;..." - bus id -> indice

nvidia_name() { printf 'NVIDIA'; }

nvidia_probe() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi -L >/dev/null 2>&1
}

nvidia_supports_procs() { return 0; }

nvidia_init() {
  command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi nao encontrado - driver NVIDIA instalado?"
  nvidia-smi -L >/dev/null 2>&1 || die "nvidia-smi nao conseguiu falar com o driver"

  NVIDIA_SMI_TARGET=()
  [[ -n "$GPU_IDX" ]] && NVIDIA_SMI_TARGET=(-i "$GPU_IDX")

  # Um indice invalido faz o nvidia-smi imprimir "No devices were found" no
  # proprio stdout, entao checar so se a saida esta vazia nao basta: o codigo de
  # retorno e o filtro de indice numerico e que separam GPU real de mensagem.
  local list
  if ! list=$(nvidia-smi "${NVIDIA_SMI_TARGET[@]}" --query-gpu=index,name,gpu_bus_id \
              --format=csv,noheader 2>&1); then
    die "nvidia-smi nao conseguiu listar a GPU${GPU_IDX:+ de indice $GPU_IDX}: $list"
  fi

  # Nome e bus id nao mudam durante a coleta: le uma vez e repassa aos awks como
  # mapas "chave=valor;chave=valor", evitando campos de texto dentro do loop.
  NVIDIA_NAMES=$(printf '%s\n' "$list" \
    | awk -F', *' '$1 ~ /^[0-9]+$/ { printf "%s%s=%s", sep, $1, $2; sep=";" }')
  [[ -n "$NVIDIA_NAMES" ]] || die "nenhuma GPU encontrada${GPU_IDX:+ no indice $GPU_IDX}"

  # A secao de processos identifica a placa por bus id, nao por indice.
  NVIDIA_BUSMAP=$(printf '%s\n' "$list" \
    | awk -F', *' '$1 ~ /^[0-9]+$/ { printf "%s%s=%s", sep, toupper($3), $1; sep=";" }')

  GPU_COUNT=$(printf '%s\n' "$list" | awk -F', *' '$1 ~ /^[0-9]+$/' | wc -l)
}

NVIDIA_FIELDS="timestamp,index,utilization.gpu,utilization.memory,memory.total,memory.used,memory.free,temperature.gpu,power.draw,clocks.sm,clocks.mem"

nvidia_start_gpu() {
  make_fifo gpumon; local fifo="$FIFO_PATH"

  # -lms deixa o proprio nvidia-smi cadenciar as amostras: uma unica sessao NVML,
  # sem o custo e o drift de reabrir o driver a cada iteracao.
  run_source nvidia-smi "${NVIDIA_SMI_TARGET[@]}" --query-gpu="$NVIDIA_FIELDS" \
             --format=csv,noheader,nounits -lms "$INTERVAL_MS" > "$fifo" 2>/dev/null &
  GPU_SRC_PID=$!

  # LC_ALL=C: sem isso um locale pt_BR faz o %.1f do awk emitir virgula decimal,
  # o que parte a coluna vram_used_pct em duas no CSV.
  LC_ALL=C awk -v out="$OUTPUT" -v names="$NVIDIA_NAMES" -v quiet="$QUIET" '
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
  ' < "$fifo" &
  GPU_AWK_PID=$!
}

nvidia_start_proc() {
  make_fifo gpumonp; local fifo="$FIFO_PATH"

  # --query-compute-apps so enxerga contextos CUDA; num desktop tipico a VRAM toda
  # esta em processos graficos (Xorg, navegador, jogo), que ele reporta como vazio.
  # -q -d PIDS traz as duas familias com o tipo explicito, e o modo "compute"
  # filtra por type == C para reproduzir o recorte do --query-compute-apps.
  LC_ALL=C run_source nvidia-smi "${NVIDIA_SMI_TARGET[@]}" -q -d PIDS -lms "$INTERVAL_MS" \
           > "$fifo" 2>/dev/null &
  PROC_SRC_PID=$!

  LC_ALL=C awk -v out="$PROCS_OUT" -v busmap="$NVIDIA_BUSMAP" -v mode="$PROCS_MODE" \
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
  ' < "$fifo" &
  PROC_AWK_PID=$!
}

nvidia_list_procs() {
  nvidia-smi "${NVIDIA_SMI_TARGET[@]}" -q -d PIDS 2>/dev/null \
    | awk '/^ +Name +:/ { n = $0; sub(/^[^:]*:[ ]*/, "", n); split(n, w, " ")
                          sub(/.*\//, "", w[1]); print w[1] }'
}
