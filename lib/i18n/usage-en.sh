# shellcheck shell=bash
#
# usage-en.sh - English help text.
#
# Prose, not messages: it lives in a file per language instead of ~90 array
# entries, which keeps the interpolations ($VERSION, $LOG_DIR, backend_list)
# working and stays editable. Sourced by usage_text() in lib/i18n.sh.

cat <<EOF
monitor.sh v$VERSION - GPU/VRAM, process and disk monitor, CSV output

Usage: ${0##*/} [subcommand] [options]

Subcommands:
  all      Collect GPU, processes and disk (the default when none is given)
  gpu      GPU metrics only
  disk     Disk I/O and temperature only
  proc     Per-process VRAM only

Common options:
  -i, --interval MS    Interval between samples, in milliseconds
                       (default: 500; whole number, minimum 100)
  -d, --duration SEC   Total duration in seconds (default: 0 = until Ctrl+C)
  -o, --output FILE    Output CSV file
                       (default: $LOG_DIR/monitor-YYYYMMDD-HHMMSS.csv)
  -q, --quiet          Print nothing on screen, only write the CSVs
  -h, --help           Show this help
  -V, --version        Show the version

GPU options (subcommands all, gpu, proc):
  -g, --gpu IDX        Monitor only the GPU at index IDX (default: all)
  -b, --backend NAME   Force a backend (default: autodetection)
                       Available: $(backend_list | paste -sd" ")
                       Only NVIDIA collects per-process VRAM today.

Process options (subcommands all, proc):
  -p, --procs MODE     Per-process VRAM attribution (default: all)
                         all     - compute (C) and graphics (G) processes
                         compute - CUDA/compute contexts only (C)
                         off     - do not collect processes
  -f, --filter TARGET  Monitor only these processes; TARGET is a PID or a name,
                       several separated by commas, and the option may repeat.
                       Digits only = PID; anything else = name, matched as a
                       substring, case-insensitive. The name is compared against
                       the executable and, when the target carries a path or
                       arguments, against the whole command line too.
                         -f chrome                        chrome only
                         -f chrome,Xorg                   both
                         -f 1598 -f python3               PID 1598 and python3
                         -f /opt/google/chrome/chrome     full path
                         -f "python3 train.py"            name + arguments
                         -f name:1234                     process named "1234"
                       The comma always separates targets: for a command with a
                       comma in its arguments, filter by a comma-free substring.
  -t, --top N          How many processes in the final summary (default: 5; 0 off)

Disk options (subcommands all, disk):
  -D, --disk MODE      Monitor disk I/O and temperature (default: all)
                         all     - every physical disk
                         off     - do not collect disk
                         LIST    - devices separated by commas
                                   (e.g. -D nvme0n1 or -D sda,sdb)

Outputs (only the files of the active collectors are created):
  <output>.csv         one line per GPU per sample (usage, VRAM, temperature...)
  <output>-procs.csv   one line per process per sample (VRAM charged to the PID)
  <output>-disk.csv    one line per disk per sample (read/write and temperature)

Columns of <output>.csv:
  timestamp          local ISO-8601, with milliseconds
  gpu_index          GPU index
  gpu_name           model name
  gpu_util_pct       % of time with active kernels (core occupancy)
  mem_util_pct       % of time with the memory bus in use
  vram_total_mib     total VRAM
  vram_used_mib      VRAM in use
  vram_free_mib      free VRAM
  vram_used_pct      VRAM in use, as % of total
  temp_c             core temperature in C
  power_w            draw in W (empty if the GPU does not report it)
  sm_clock_mhz       SM clock
  mem_clock_mhz      memory clock

Columns of <output>-procs.csv:
  timestamp          local ISO-8601 (1s resolution)
  gpu_index          GPU index
  pid                process PID
  type               C = compute (CUDA), G = graphics
  process_name       executable name
  used_vram_mib      VRAM charged to this process

Columns of <output>-disk.csv:
  timestamp          local ISO-8601 (1s resolution)
  device             disk name (nvme0n1, sda...)
  read_mb_s          reads over the interval, in MB/s
  write_mb_s         writes over the interval, in MB/s
  read_iops          read operations per second
  write_iops         writes per second
  util_pct           % of time with at least one request in flight
  temp_c             disk temperature (empty if there is no sensor)

A metric the hardware does not report becomes an empty cell, never zero: zero is
a measured value, empty is the absence of a measurement.

The files join on the second of the timestamp (and on gpu_index, between the
first two). The sum of used_vram_mib is smaller than vram_used_mib, because the
driver and the video context also reserve memory outside the processes. Disk
rates are deltas between samples, so the first reading serves as the baseline
and the first line of <output>-disk.csv appears one interval after the start.

The CSVs are flushed on every sample, so they can be read or plotted while
collection is still running.

Environment:
  MONITOR_LANG         Force the language (e.g. en, pt), ignoring the locale
  MONITOR_LOG_DIR      Where the CSVs go (default: \$HOME/.monitor/log)
EOF
