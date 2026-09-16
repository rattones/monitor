# shellcheck shell=bash
#
# disk.sh - I/O e temperatura de disco.
#
# Nao depende de GPU nenhuma: le /proc/diskstats e /sys/class/hwmon, entao roda
# igual em qualquer maquina Linux, com ou sem placa de video dedicada.

DISK_DEVS=""; DISK_TEMPS=""
DISK_PID=""
DISK_SKIP=1

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

resolve_disks() {
  local _disks=() _d
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
}

# Aqui nao ha produtor externo: /proc e /sys sao arquivos, entao o proprio awk
# cadencia o loop. Os contadores do kernel sao cumulativos desde o boot, e o que
# interessa e a taxa - por isso a primeira leitura vira base e so a partir da
# segunda sai linha no CSV.
start_disk() {
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
}
