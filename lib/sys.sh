# shellcheck shell=bash
#
# sys.sh - CPU, memoria e pressao do sistema, mais o estado das threads do alvo.
#
# Existe para responder a pergunta que as metricas da GPU sozinhas nao
# respondem: quando a GPU fica ociosa no meio de um jogo, quem parou de mandar
# trabalho para ela, e esperando o que? A GPU a 0% so diz que o gargalo esta
# antes dela; a CPU por nucleo, o PSI e o wchan das threads dizem onde.
#
# Como o disco, nao depende de GPU: le /proc direto, e o proprio awk cadencia o
# laco. Grava dois arquivos:
#
#   <saida>-sys.csv      uma linha por amostra: CPU total e do nucleo mais
#                        ocupado, memoria, PSI e o consumo agregado dos PIDs-alvo
#   <saida>-threads.csv  uma linha por thread ativa dos PIDs-alvo por amostra,
#                        com estado e wchan (em qual funcao do kernel ela dorme)
#
# O de threads so existe com -f pid:N: por nome o alvo pode casar com varios
# processos que nascem e morrem durante a coleta, e seguir as threads de um
# alvo movel geraria um arquivo sem uma pergunta clara por tras.
#
# Por que wchan e nao a pilha: /proc/<pid>/task/<tid>/stack e syscall exigem
# ptrace, que o Yama (ptrace_scope=1, padrao no Ubuntu) nega para processos que
# nao sao filhos do monitor. O wchan so exige leitura e ja separa os casos que
# importam: futex (lock/fila entre threads), poll/select (esperando socket -
# X11, audio, rede), funcoes do driver de video (esperando a GPU) e D-state
# (I/O ou o kernel).

SYS_PID=""
SYS_SKIP=1; THREADS_SKIP=1
SYS_PIDS=""           # "123;456" - PIDs de -f pid:N, sem os delimitadores do filtro

# Raiz do /proc. Existe para a suite de testes apontar o coletor para uma arvore
# falsa com threads, estados e contadores conhecidos. Em uso normal e o /proc.
PROC_ROOT="${MONITOR_PROC_ROOT:-/proc}"

# Uma thread entra no CSV quando gasta pelo menos THREADS_MIN_PCT de um nucleo
# no intervalo, e continua entrando por THREADS_HOLD_S segundos depois disso.
# A retencao e o ponto: numa parada, a thread de render deixa de consumir CPU
# justamente quando o wchan dela fica interessante - sem a retencao, ela sumiria
# do arquivo no instante em que passa a importar.
THREADS_MIN_PCT="${MONITOR_THREADS_MIN_PCT:-1}"
THREADS_HOLD_S="${MONITOR_THREADS_HOLD_S:-10}"

resolve_sys() {
  SYS_PIDS="${FILTER_PIDS#;}"; SYS_PIDS="${SYS_PIDS%;}"
  # Vem do ambiente: um valor torto viraria 0 dentro do awk sem aviso, e com
  # limiar 0 toda thread ociosa entraria no CSV.
  [[ "$THREADS_MIN_PCT" =~ ^[0-9]*\.?[0-9]+$ ]] || die "$(msg sys_bad_env MONITOR_THREADS_MIN_PCT "$THREADS_MIN_PCT")"
  [[ "$THREADS_HOLD_S"  =~ ^[0-9]*\.?[0-9]+$ ]] || die "$(msg sys_bad_env MONITOR_THREADS_HOLD_S "$THREADS_HOLD_S")"
  [[ -r "$PROC_ROOT/stat" ]] || die "$(msg sys_no_proc "$PROC_ROOT")"
}

start_sys() {
  local tck
  tck=$(getconf CLK_TCK 2>/dev/null) || tck=100
  [[ "$tck" =~ ^[0-9]+$ ]] || tck=100

  LC_ALL=C awk -v out="$SYS_OUT" -v tout="$THREADS_OUT" -v proc="$PROC_ROOT" \
               -v pids="$SYS_PIDS" -v tck="$tck" -v iv="$INTERVAL_S" \
               -v dur="$DURATION" -v tmin="$THREADS_MIN_PCT" -v hold="$THREADS_HOLD_S" '
  function uptime(   l, a) {
    getline l < (proc "/uptime"); close(proc "/uptime")
    split(l, a, " ")
    return a[1] + 0
  }

  # Milissegundos, como o CSV da GPU: uma parada de 3 s ocupa seis amostras, e
  # com resolucao de 1 s nao daria para alinhar uma com a outra.
  #
  # A hora sai de uma base lida uma vez somada ao /proc/uptime, e nao de um
  # "date" por amostra. Com a CPU carregada - justo o caso que se investiga - o
  # date chegou a sair meio segundo atrasado e ate fora de ordem, o que
  # embaralharia o alinhamento com a GPU. O uptime tem resolucao de 10 ms.
  function now(u,   e) {
    e = epoch0 + (u - up0)
    return strftime("%Y-%m-%dT%H:%M:%S", int(e)) sprintf(".%03d", int((e - int(e)) * 1000))
  }

  # /proc/stat: "cpu" e cada "cpuN" viram "ocupado total iowait" em ticks.
  # Ocioso = idle + iowait; o iowait sai a parte porque um nucleo "parado
  # esperando disco" e exatamente o tipo de coisa que se procura aqui.
  function snap_cpu(arr,   line, f, n, i, tot, busy) {
    delete arr
    while ((getline line < (proc "/stat")) > 0) {
      if (line !~ /^cpu/) continue
      n = split(line, f)
      tot = 0
      for (i = 2; i <= n && i <= 9; i++) tot += f[i]
      busy = tot - f[5] - f[6]
      arr[f[1]] = busy " " tot " " f[6]
    }
    close(proc "/stat")
  }

  function meminfo(   line, f) {
    delete mi
    while ((getline line < (proc "/meminfo")) > 0) {
      split(line, f, /[: ]+/)
      mi[f[1]] = f[2]
    }
    close(proc "/meminfo")
  }

  # PSI: o "total=" da linha "some" e cumulativo em microssegundos. Sem PSI no
  # kernel (CONFIG_PSI desligado) o arquivo nao existe e a coluna fica vazia.
  function psi(res,   path, line, v) {
    path = proc "/pressure/" res
    v = ""
    while ((getline line < path) > 0) {
      if (line ~ /^some/ && match(line, /total=[0-9]+/))
        v = substr(line, RSTART + 6, RLENGTH - 6)
    }
    close(path)
    return v
  }

  # Campos de /proc/<pid>/stat depois do comm. O comm vai entre parenteses e
  # pode conter espacos e ")", entao corta-se no ULTIMO ")": dividir a linha
  # inteira por espaco deslocaria todos os campos de uma thread chamada
  # "CNet Encrypt:0". Depois do corte, r[1] e o estado, r[10] o majflt,
  # r[12]/r[13] o utime/stime, r[37] o ultimo nucleo em que a thread rodou.
  function readstat(path, r,   line, p, q, n, i, f2) {
    delete r
    if ((getline line < path) <= 0) { close(path); return 0 }
    close(path)
    p = index(line, "(")
    q = length(line)
    while (q > 0 && substr(line, q, 1) != ")") q--
    if (p == 0 || q == 0) return 0
    r["comm"] = substr(line, p + 1, q - p - 1)
    n = split(substr(line, q + 2), f2, " ")
    for (i = 1; i <= n; i++) r[i] = f2[i]
    return 1
  }

  function readline1(path,   v) {
    v = ""
    if ((getline v < path) <= 0) v = ""
    close(path)
    return v
  }

  # Nucleos em que a thread PODE rodar ("0-15", "0,2,4"). A virgula vira espaco
  # para caber numa celula; vazio se o status nao for legivel.
  function affinity(path,   line, v) {
    v = ""
    while ((getline line < path) > 0)
      if (line ~ /^Cpus_allowed_list:/) { v = line; sub(/^Cpus_allowed_list:[ \t]*/, "", v) }
    close(path)
    gsub(/,/, " ", v)
    return v
  }

  # Texto livre (nome de thread) vira celula segura para CSV.
  function clean(s) { gsub(/[,"\r\n]/, "_", s); return s }

  function pct(num, den) { return den > 0 ? sprintf("%.1f", num * 100 / den) : "" }

  BEGIN {
    np = split(pids, pid, ";")
    cmd = "date +%s.%N"; cmd | getline epoch0; close(cmd)
    epoch0 += 0; up0 = uptime()
    snap_cpu(cprev)
    split("cpu memory io", res, " ")
    for (k = 1; k <= 3; k++) pprev[res[k]] = psi(res[k])

    t_prev = uptime(); t0 = t_prev; target = t0
    first = 1

    while (1) {
      # Mesma cadencia do disco: dorme ate o proximo instante-alvo, e nao um
      # intervalo cheio, para as linhas continuarem batendo com as da GPU.
      target += iv
      slp = target - uptime()
      if (slp > 0) system("sleep " slp)

      t = uptime(); dt = t - t_prev
      ts = now(t)

      # --- CPU ---
      snap_cpu(ccur)
      cpu = ""; iow = ""; maxc = ""; maxn = ""
      if ("cpu" in ccur && "cpu" in cprev) {
        split(cprev["cpu"], a); split(ccur["cpu"], b)
        cpu = pct(b[1] - a[1], b[2] - a[2])
        iow = pct(b[3] - a[3], b[2] - a[2])
      }
      best = -1
      for (c in ccur) {
        if (c == "cpu" || !(c in cprev)) continue
        split(cprev[c], a); split(ccur[c], b)
        if (b[2] - a[2] <= 0) continue
        u = (b[1] - a[1]) * 100 / (b[2] - a[2])
        if (u > best) { best = u; maxn = substr(c, 4) }
      }
      if (best >= 0) maxc = sprintf("%.1f", best)

      # --- memoria ---
      meminfo()
      mused = ""; mavail = ""; swap = ""
      if ("MemTotal" in mi && "MemAvailable" in mi) {
        mused  = int((mi["MemTotal"] - mi["MemAvailable"]) / 1024)
        mavail = int(mi["MemAvailable"] / 1024)
      }
      if ("SwapTotal" in mi && "SwapFree" in mi)
        swap = int((mi["SwapTotal"] - mi["SwapFree"]) / 1024)

      # --- PSI: % do intervalo em que alguma tarefa esperou pelo recurso ---
      for (k = 1; k <= 3; k++) {
        r0 = res[k]; v = psi(r0)
        pp[r0] = (v != "" && pprev[r0] != "" && dt > 0) ? \
                 sprintf("%.1f", (v - pprev[r0]) / (dt * 10000)) : ""
        pprev[r0] = v
      }

      # --- PIDs-alvo e suas threads ---
      pcpu = ""; pthr = ""; prun = ""; pdst = ""; pmaj = ""
      if (np > 0) {
        tot_ticks = 0; tot_maj = 0; nthr = 0; nrun = 0; nd = 0; alive = 0
        delete seen
        for (j = 1; j <= np; j++) {
          if (!readstat(proc "/" pid[j] "/stat", ps)) continue
          alive = 1
          tot_ticks += ps[12] + ps[13]
          tot_maj   += ps[10]

          cmd = "ls " proc "/" pid[j] "/task 2>/dev/null"
          while ((cmd | getline tid) > 0) {
            tp = proc "/" pid[j] "/task/" tid
            if (!readstat(tp "/stat", ts_)) continue
            key = pid[j] "/" tid
            seen[key] = 1
            nthr++
            st = ts_[1]
            if (st == "R") nrun++
            if (st == "D") nd++

            # O total decide se a thread entra; a divisao usuario/kernel diz,
            # numa thread girando a 100%, se o giro e no codigo do programa
            # (espera ativa, laco) ou dentro de uma chamada ao kernel.
            ticks = ts_[12] + ts_[13]
            have = (key in tprev && dt > 0)
            tpct = have ? (ticks - tprev[key]) * 100 / tck / dt : 0
            upct = have ? (ts_[12] - uprev[key]) * 100 / tck / dt : 0
            if (tpct < 0) tpct = 0
            if (upct < 0) upct = 0
            if (upct > tpct) upct = tpct
            tprev[key] = ticks; uprev[key] = ts_[12]
            if (tpct >= tmin) last_active[key] = t

            if (!first && ((key in last_active && t - last_active[key] <= hold) || st == "D")) {
              printf("%s,%s,%s,%s,%s,%.1f,%s,%.1f,%.1f,%s,%s\n", ts, pid[j], tid,
                     clean(ts_["comm"]), st, tpct, clean(readline1(tp "/wchan")),
                     upct, tpct - upct, ts_[37], affinity(tp "/status")) >> tout
            }
          }
          close(cmd)
        }
        # Thread que morreu nao volta: sem limpar, os mapas cresceriam a cada
        # thread efemera criada pelo jogo.
        for (key in tprev) if (!(key in seen)) { delete tprev[key]; delete uprev[key]; delete last_active[key] }

        if (alive) {
          pcpu = (have_prev && dt > 0) ? sprintf("%.1f", (tot_ticks - pticks) * 100 / tck / dt) : ""
          pmaj = (have_prev && dt > 0) ? sprintf("%.1f", (tot_maj - pmajp) / dt) : ""
          pthr = nthr; prun = nrun; pdst = nd
          pticks = tot_ticks; pmajp = tot_maj; have_prev = 1
        } else {
          have_prev = 0
        }
        fflush(tout)
      }

      if (!first && dt > 0) {
        printf("%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", ts,
               cpu, iow, maxc, maxn, mused, mavail, swap,
               pp["cpu"], pp["memory"], pp["io"],
               pcpu, pthr, prun, pdst, pmaj) >> out
        fflush(out)
      }

      for (c in ccur) cprev[c] = ccur[c]
      t_prev = t
      first = 0
      if (dur > 0 && t - t0 >= dur - 0.05) break
    }
  }
  ' &
  SYS_PID=$!
}
