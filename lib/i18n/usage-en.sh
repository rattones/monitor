# shellcheck shell=bash
#
# usage-en.sh - English help text.
#
# Prose, not messages: it lives in a file per language instead of ~90 array
# entries, which keeps the interpolations ($VERSION, $LOG_DIR, backend_list)
# working and stays editable. Sourced by usage_text() in lib/i18n.sh.

cat <<EOF
monitor.sh v$VERSION - GPU/VRAM, process, disk and system monitor, CSV output

Usage: ${0##*/} [subcommand] [options]

Subcommands:
  all      Collect GPU, processes, disk and system (the default when none is given)
  gpu      GPU metrics only
  disk     Disk I/O and temperature only
  proc     Per-process VRAM only
  sys      CPU, memory, PSI and the threads of the -f PIDs only

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
                       nouveau = NVIDIA on the free driver (NVK): VRAM only,
                       read through vulkaninfo. Only nvidia collects
                       per-process VRAM.

Process options (subcommands all, proc; -f pid:N also applies to sys):
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

System options (subcommands all, sys):
  -S, --sys MODE       CPU, memory, PSI and target threads (default: all)
                         all     - collect
                         off     - do not collect
                       Threads are only followed for PIDs given as -f pid:N.
                       A thread enters the CSV once it uses 1% of a core and
                       stays for 10 s after it stops: that is when its wchan
                       shows what stalled it.
  -P, --perf           Sample the stacks of the -f pid:N PIDs with perf record,
                       to see which library and function a thread spins in.
                       Without root, needs kernel.perf_event_paranoid <= 1.

Outputs (only the files of the active collectors are created):
  <output>.csv         one line per GPU per sample (usage, VRAM, temperature...)
  <output>-procs.csv   one line per process per sample (VRAM charged to the PID)
  <output>-disk.csv    one line per disk per sample (read/write and temperature)
  <output>-sys.csv     one line per sample (CPU, memory, PSI and the target in aggregate)
  <output>-threads.csv one line per active target thread per sample (only with -f pid:N)
  <output>-perf.data   perf samples (only with -P), with their own wall-clock
                       reference - see tools/perf-window.sh

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

Columns of <output>-sys.csv:
  timestamp          local ISO-8601, with milliseconds (10 ms resolution)
  cpu_util_pct       % CPU busy, averaged over all cores
  cpu_iowait_pct     % of CPU time idle waiting for I/O
  cpu_max_core_pct   % of the busiest core - a game bound to one thread
                     saturates a core while the average stays low
  cpu_max_core       which core that was
  mem_used_mib       memory in use (total - available)
  mem_avail_mib      available memory
  swap_used_mib      swap in use
  psi_cpu_pct        % of the interval with some task waiting for CPU (PSI)
  psi_mem_pct        same, waiting for memory
  psi_io_pct         same, waiting for I/O
  proc_cpu_pct       CPU of the -f PIDs, in % of one core (empty without target)
  proc_threads       target threads
  proc_running       target threads running (state R)
  proc_dstate        target threads in D (I/O or kernel, uninterruptible)
  proc_majflt_s      major page faults per second (pages read from disk)

Columns of <output>-threads.csv:
  timestamp          the same as the matching <output>-sys.csv line
  pid, tid           process and thread
  thread_name        thread name (commas become _)
  state              R running, S sleeping, D uninterruptible...
  cpu_pct            thread CPU in the interval, in % of one core
  wchan              kernel function the thread sleeps in: futex_* (lock
                     between threads), poll/select (socket: X11, audio,
                     network), video driver functions (waiting for the GPU);
                     0 while running
  user_pct, sys_pct  cpu_pct split between the program's code and the kernel:
                     a thread at 100% user_pct spins in its own code
  last_cpu           the last core the thread ran on
  affinity           cores it is allowed to run on (e.g. 0-15; commas become
                     spaces)

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
  MONITOR_THREADS_MIN_PCT  Minimum CPU for a thread to enter the CSV (default: 1)
  MONITOR_THREADS_HOLD_S   Seconds it stays after going idle (default: 10)
  MONITOR_PERF_FREQ        Samples per second for -P (default: 49)
  MONITOR_NOUVEAU_MIN_MS   Minimum ms between VRAM reads on nouveau (default: 2000)
EOF
