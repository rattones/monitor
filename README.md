# monitor

[English](README.md) · [Português](README.pt-BR.md)

Samples GPU usage — including VRAM — and writes it to CSV, twice a second by
default. It also writes a CSV charging VRAM to each process, to tie memory churn
to whoever caused it, a CSV with disk read/write and temperature, and a CSV
with CPU, memory and pressure — plus, for a target PID, what each of its threads
was doing.

```bash
./monitor.sh -d 300
```

```
GPU: NVIDIA (1 card)
writing to: /home/you/.monitor/log/monitor-20260916-095821.csv
interval: 500ms | duration: 300s | Ctrl+C to stop

09:58:21  GPU0  util  30%   vram   794/4096 MiB (19.4%)   temp  52 C    24.00 W
09:58:22  GPU0  util  35%   vram   812/4096 MiB (19.8%)   temp  53 C    26.10 W
```

Four collectors on one timeline: GPU, per-process VRAM, disk and system, sampled on the
same clock so the CSVs join on the timestamp. No daemon, no dependencies beyond
bash and awk, and the files are flushed every sample so you can plot them while
collection is still running.

For a program (a game, say) that freezes while the GPU sits idle, the repository also has a
separate, root-only bpftrace probe of the main thread ([`probe/`](#freeze-probe-probe-root)).

## Install

```bash
git clone https://github.com/rattones/monitor.git
cd monitor
./install.sh          # into ~/.local, no root needed
```

Or run it straight from the clone with `./monitor.sh`. Full details, including
system-wide install and troubleshooting, in [INSTALL.md](INSTALL.md).

## Usage

```bash
monitor                      # 2 samples/s until Ctrl+C
monitor -d 300               # for 5 minutes
monitor -i 1000 -o run.csv   # 1 sample/s into run.csv
monitor -p compute           # CUDA contexts only
monitor -q -d 60 &           # in the background, no screen output
```

### Subcommands

The four collectors are independent and can run alone. With no subcommand the
default is `all`.

| Subcommand | Collects | File |
|---|---|---|
| `all` (default) | GPU, processes, disk and system | all of them |
| `gpu` | GPU metrics only | `<output>.csv` |
| `disk` | disk I/O and temperature | `<output>-disk.csv` |
| `proc` | per-process VRAM only | `<output>-procs.csv` |
| `sys` | CPU, memory, PSI and target threads | `<output>-sys.csv`, `<output>-threads.csv` |

```bash
monitor disk -D nvme0n1 -d 60   # disk only
monitor proc -f chrome          # processes only, filtered
monitor gpu -i 250              # GPU only, 4 samples/s
monitor sys -f pid:4242         # system, plus the threads of PID 4242
```

The subcommand comes **before** the options. `disk` and `sys` need no GPU at
all: they read only `/proc` and `/sys`, so they run on a machine without
`nvidia-smi`.

### Options

| Option | Description |
|---|---|
| `-i, --interval MS` | Interval between samples, in **milliseconds** (default `500`; whole number, minimum `100`) |
| `-d, --duration SEC` | Total duration (default `0` = until Ctrl+C) |
| `-o, --output FILE` | Output CSV (default `~/.monitor/log/monitor-YYYYMMDD-HHMMSS.csv`) |
| `-g, --gpu IDX` | Monitor only the GPU at index `IDX` (default: all) |
| `-b, --backend NAME` | Force a GPU backend (default: autodetection) |
| `-p, --procs MODE` | `all` (default) = compute and graphics; `compute` = CUDA only; `off` = skip |
| `-f, --filter TARGET` | Monitor only these processes — PID or name, comma-separated, repeatable |
| `-D, --disk MODE` | `all` (default) = every physical disk; `off` = skip; or a list (`nvme0n1`, `sda,sdb`) |
| `-S, --sys MODE` | `all` (default) = CPU, memory, PSI and target threads; `off` = skip |
| `-P, --perf` | Sample the stacks of the `-f pid:N` targets with `perf record` (see below) |
| `-t, --top N` | How many processes/threads in the final summary (default `5`; `0` off) |
| `-q, --quiet` | Only write the CSVs, print nothing |
| `-h, --help` | Help |
| `-V, --version` | Version |

Ctrl+C stops cleanly: the last sample is written, the summary is printed, and no
process is left orphaned.

## GPU support

| Backend | GPU metrics | Per-process VRAM |
|---|---|---|
| `nvidia` | yes | yes |
| `nouveau` | VRAM only | no |
| `amd` | yes | no |
| `intel` | yes\* | no |

The backend is autodetected, or forced with `-b/--backend`.

**AMD** reads the `amdgpu` driver's sysfs — no root, no external tool. Verified
against a Radeon Vega (Cezanne). On that APU `mem_util_pct` comes out empty
because the card does not expose `mem_busy_percent`; dedicated cards usually do.

**nouveau** is an NVIDIA card on the free stack — the `nouveau` kernel driver
and NVK (Mesa) for Vulkan — where `nvidia-smi` does not exist. With the GSP
firmware (Turing and newer) the driver exposes no hwmon, busy percentage,
clocks or fdinfo stats, so only VRAM is filled in; every other column stays
empty. VRAM is read through `vulkaninfo` (package `vulkan-tools`): NVK reports
the card's free VRAM in `VK_EXT_memory_budget`, and used = size − budget / 0.9
(Mesa gives 90% of the free VRAM as budget). It is an estimate within a few
MiB. Each read creates a Vulkan device (~0.2 s), so VRAM is read at most every
`MONITOR_NOUVEAU_MIN_MS` (default 2000) even with a smaller `-i`. Verified on an
RTX 3050 Laptop (GA107) with Linux 7.0 and Mesa 26.0.

**\* Intel** was written from kernel documentation and has **never run on real
hardware** — there is no Intel GPU on the development machine. Its parsing and
unit conversion are exercised against a simulated sysfs tree, but the paths
themselves are unverified. It warns about this when it starts.
[Help us fix that →](CONTRIBUTING.md)

Only `nvidia` has an equivalent to `nvidia-smi -q -d PIDS`, so `proc` is refused
on the others with an explanation rather than producing an empty CSV; under
`all` the process collector is just skipped, with a notice, and the rest runs.
To collect GPU and disk on AMD:

```bash
monitor -b amd -p off
```

## Choosing what to monitor

`-f/--filter` restricts the process CSV to specific targets. Each target is a
**PID** (digits only) or a **name** (anything else):

```bash
monitor -f chrome                # one name
monitor -f chrome,Xorg           # several names
monitor -f 1598                  # one PID
monitor -f dota,4892 -f cinnamon # names and PIDs mixed
```

- **Name** matches as a substring, case-insensitive: `-f steam` catches `steam`
  and `steamwebhelper`.
- The name is matched against the **executable**. When the target carries a path
  or arguments, it is matched against the **whole command line** too, so you can
  paste what you see in `ps` or `nvidia-smi -q`:

  ```bash
  monitor -f /opt/google/chrome/chrome
  monitor -f "python3 train.py"
  monitor -f "...rack-uuid=3190708988185955192"   # name truncated by nvidia-smi
  ```

  Wide matching applies only to those more specific targets. A short one like
  `-f gpu` looks at the executable only, or it would catch every process with
  `--type=gpu-process` in its arguments.
- **PID** matches exactly: `-f 159` does not catch PID `1598`.
- Matching **one** target is enough — targets are alternatives, not requirements.
- For a name that is all digits, disambiguate with `name:` or `pid:` —
  `-f name:1234` looks for the process *called* `1234`.
- If nothing matches, the script says so and lists what was on the GPU, so you
  can correct the target.

## Output

### `<output>.csv` — one line per GPU per sample

| Column | Meaning |
|---|---|
| `timestamp` | local ISO-8601 with milliseconds |
| `gpu_index` / `gpu_name` | index and model |
| `gpu_util_pct` | % of time with active kernels (core occupancy) |
| `mem_util_pct` | % of time with the memory bus in use |
| `vram_total_mib` / `vram_used_mib` / `vram_free_mib` | VRAM in MiB |
| `vram_used_pct` | VRAM in use, as % of total |
| `temp_c` | core temperature, °C |
| `power_w` | draw in W (empty if not reported) |
| `sm_clock_mhz` / `mem_clock_mhz` | SM and memory clocks |

`gpu_util_pct` and `mem_util_pct` are percentages of *time busy*, not of
capacity: a high `mem_util_pct` with a low `vram_used_pct` means heavy traffic
through little memory. For how much VRAM is being consumed, use `vram_used_mib`.

### `<output>-procs.csv` — one line per process per sample

| Column | Meaning |
|---|---|
| `timestamp` | local ISO-8601 (1s resolution) |
| `gpu_index` / `pid` | GPU index and process PID |
| `type` | `C` = compute (CUDA), `G` = graphics, `C+G` = both |
| `process_name` | executable name (the full command line is discarded) |
| `used_vram_mib` | VRAM charged to this process |

At the end, the biggest consumers of the session:

```
top 5 processes by VRAM (avg / peak):
  dota                     pid 60282   [C+G]    1404 MiB /   1404 MiB
  Xorg                     pid 1598    [G]      285 MiB /    285 MiB
```

### `<output>-disk.csv` — one line per disk per sample

| Column | Meaning |
|---|---|
| `timestamp` / `device` | timestamp and disk name |
| `read_mb_s` / `write_mb_s` | read and write rate over the interval, MB/s |
| `read_iops` / `write_iops` | operations per second |
| `util_pct` | % of time with at least one request in flight |
| `temp_c` | disk temperature (empty if there is no sensor) |

And in the final summary:

```
disk - read / write (avg / peak):
  nvme0n1      59.5 /  554.5 MB/s     60.2 /  513.0 MB/s   temp 42.8 / 42.9 C
```

Worth knowing:

- Rates are **deltas** between samples, so the first reading is the baseline and
  this CSV's first line appears one interval after the start.
- `util_pct` is time with I/O in flight, not throughput. An NVMe serves several
  queues in parallel, so it can saturate its bandwidth at 40% `util_pct`.
- Temperature comes from the device's own `hwmon`. NVMe exposes it directly;
  SATA disks need the `drivetemp` module (`sudo modprobe drivetemp`).
- Partitions are not accepted in `-D`: I/O is accounted to the whole disk.
  `dm-*`, `md*` and `loop*` are excluded from `all` because they would mirror
  real disks and count twice.
- No root and no `smartctl` needed.

### `<output>-sys.csv` — one line per sample

Answers the question GPU metrics alone cannot: when the GPU goes idle in the
middle of a game, who stopped feeding it?

| Column | Meaning |
|---|---|
| `timestamp` | with milliseconds, like the GPU CSV (10 ms resolution) |
| `cpu_util_pct` / `cpu_iowait_pct` | CPU busy and CPU idle-waiting-for-I/O, averaged over all cores |
| `cpu_max_core_pct` / `cpu_max_core` | the busiest core and which one — a game bound to one thread saturates a core while the average stays low |
| `mem_used_mib` / `mem_avail_mib` / `swap_used_mib` | memory in use, available, and swap in use |
| `psi_cpu_pct` / `psi_mem_pct` / `psi_io_pct` | % of the interval with some task stalled waiting for CPU, memory or I/O ([PSI](https://docs.kernel.org/accounting/psi.html)) |
| `proc_cpu_pct` | CPU of the `-f pid:N` targets, in % of one core (empty without a target) |
| `proc_threads` / `proc_running` / `proc_dstate` | target threads: total, running (R), and uninterruptible (D) |
| `proc_majflt_s` | target major page faults per second — pages that had to come from disk |

### `<output>-threads.csv` — one line per active target thread per sample

Only created with `-f pid:N`. By name, a target can match several processes
that come and go, and following the threads of a moving target would produce a
file with no clear question behind it.

| Column | Meaning |
|---|---|
| `timestamp` | the same as the matching `-sys.csv` line |
| `pid` / `tid` / `thread_name` | process, thread and thread name |
| `state` | `R` running, `S` sleeping, `D` uninterruptible… |
| `cpu_pct` | thread CPU over the interval, in % of one core |
| `wchan` | the kernel function the thread is sleeping in |
| `user_pct` / `sys_pct` | `cpu_pct` split between the program's own code and the kernel |
| `last_cpu` / `affinity` | the core it last ran on, and the cores it may run on (`0-15`; commas become spaces) |

A thread enters the file once it uses 1% of a core and **stays for 10 more
seconds after it goes idle**. That retention is the point: during a stall, the
render thread stops using CPU exactly when its `wchan` becomes interesting.
`D`-state threads always enter. Tune with `MONITOR_THREADS_MIN_PCT` and
`MONITOR_THREADS_HOLD_S`.

Reading `wchan`: `futex_*` is a lock or queue between threads; `poll_*`,
`do_select` and `ep_poll` are waits on a socket or pipe (X11, audio, network);
a video driver function means waiting on the GPU; `0` means running.

Why `wchan` and not the stack: `/proc/<pid>/task/<tid>/stack` and `syscall`
require ptrace, which Yama (`ptrace_scope=1`, the Ubuntu default) denies for
processes that are not children of the monitor. `wchan` only needs read access.

### `-P`: where a thread spins

The threads CSV says *which* thread spun and in what state; `perf` says *where*:
in which library and function. For a thread at 100% while the GPU sits idle,
that is what separates "the program stuck in a loop" from "the video driver
busy-waiting on something".

```bash
sudo sysctl kernel.perf_event_paranoid=1     # without root; lasts until reboot
monitor all -f pid:4242 -P -o run.csv
tools/perf-window.sh run 14:10:24 14:10:26 GlobPool
```

It writes `<output>-perf.data` (compressed samples, 49 Hz by default —
`MONITOR_PERF_FREQ`) and `<output>-perf.log`. It records on `CLOCK_MONOTONIC`,
which makes perf store its own wall-clock reference in the file (`perf script
-F tod`) — that is how `perf-window.sh` maps the CSVs' times onto perf's.
`tools/perf-window.sh` takes a time window as the CSVs show it and prints the
samples by thread, by the library they landed in, and by the first frame
outside the kernel — kernel frames show without symbols while `kptr_restrict`
is on, which is the default.

`-P` needs `perf` installed (`linux-tools-$(uname -r)` on Ubuntu) and a PID
target; a name target is not enough. `install.sh` does not install `tools/`:
run `perf-window.sh` from the repository.

### A metric that is not reported is empty, never zero

Zero is a measured value; empty is the absence of a measurement. Every backend
writes the same columns in the same order — that is what lets you put
collections from different machines on the same chart — and leaves a cell empty
when that hardware does not expose the metric.

## Freeze probe (`probe/`, root)

The CSVs say *that* the main thread stopped and which thread spun meanwhile.
`probe/freeze-probe.sh` says *what the main thread was waiting for* and *what
released it*. It is a bpftrace program, so it needs root, and it runs on its
own: the monitor keeps running unprivileged and unchanged, and both write to
`~/.monitor/log` on the same local clock.

```bash
sudo freeze-probe --check   # once: validate the program on this kernel
sudo freeze-probe -n dota2  # waits for the process, exits with it (any program: -n, -f, -p)
```

`install.sh` installs it next to `monitor` as the `freeze-probe` command.
Installing grants nothing: it only runs when you call it with `sudo`. sudo
looks up commands in its own `secure_path`, not your `PATH`, so with the default
`~/.local` install use the full path (`sudo ~/.local/bin/freeze-probe -n NAME`). The
installer prints the exact line, and `sudo ./install.sh --system` makes plain
`sudo freeze-probe` work. From a clone without installing:
`sudo ./probe/freeze-probe.sh`.

It works with any program. Pick the target with `-n NAME` (process name, as in
`ps -o comm`), `-f PATTERN` (a piece of the command line, for programs started
through wrappers such as Proton/Wine or scripts) or `-p PID`.

For every main-thread stop longer than the threshold (`-t`, 500 ms by default),
whether asleep in a `futex`, in `epoll_wait`, or making no system call at all,
it writes one block to `<name>-<date>-probe.txt` with:

- the timeout the thread asked the kernel for, and the return value;
- its user stack when it went to sleep;
- a `FUTEX_WAKE` on the same address from another thread of the process;
- the epoll event that fired, mapped to its file descriptor through `fdinfo`;
- 99 Hz stack samples of every thread of the process while the main thread is
  stopped, and the system calls they made.

It also keeps `<name>-<date>-probe.maps`, the process's executable mappings,
and at the end rewrites `0x... ([unknown])` stack frames as
`library.so+0xoffset`. Needs `bpftrace` (tested with 0.25) and kernel BTF.
Details and limits in [probe/README.md](probe/README.md).

## Language

Runtime text — help, errors, banner and summaries — follows the system locale.
English and Portuguese are translated; any other locale falls back to English.

```bash
LANG=en_US.UTF-8 monitor --help   # English
LANG=pt_BR.UTF-8 monitor --help   # Portuguese
MONITOR_LANG=en monitor --help    # force, ignoring the locale
```

Detection follows POSIX precedence (`LC_ALL` > `LC_MESSAGES` > `LANG`), with
`MONITOR_LANG` above all. Catalogs live in `lib/i18n/<lang>.sh`; adding a
language is adding a file.

**The CSV does not change with the language.** Headers and the decimal separator
are data format, not text — otherwise two collections from the same machine
would stop being comparable. A test covers exactly that.

Code comments are in Portuguese.

## Code layout

```
monitor.sh              entry point: loads lib/, assembles main()
install.sh              installs/removes the commands (monitor and freeze-probe)
lib/
├── core.sh             die, run_source, FIFOs, traps, waiting
├── backend.sh          GPU backend contract + autodetection
├── csv.sh              headers and file setup
├── args.sh             subcommand, options, validation
├── filter.sh           --filter targets
├── disk.sh             disk collector (needs no GPU)
├── sys.sh              CPU, memory, PSI and thread collector (needs no GPU)
├── perf.sh             -P: perf record on the target PIDs
├── report.sh           banner, summaries, footer
├── i18n.sh             language detection and catalog
├── i18n/               messages and help per language
├── helpers/
│   └── nouveau-sampler.sh  VRAM producer for the nouveau backend (vulkaninfo)
└── backends/
    ├── nvidia.sh       via nvidia-smi — implemented
    ├── nouveau.sh      NVIDIA on nouveau/NVK — VRAM only
    ├── amd.sh          via amdgpu sysfs — implemented (no per-process VRAM)
    └── intel.sh        via i915/xe sysfs — untested on hardware
tools/perf-window.sh    where the threads spent CPU in a time window
probe/                  freeze probe of the main thread (bpftrace, root)
├── freeze-probe.sh     launcher: waits for the process, runs the probe, exits with it
└── freeze.bt           the bpftrace program
tests/                  test suite and mocks
```

Everything vendor-specific lives in `lib/backends/<name>.sh`, behind the
contract described in `lib/backend.sh`. A backend implements seven functions;
the loader checks they all exist and refuses an incomplete file listing what is
missing, rather than failing halfway through a collection.

## Tests

```bash
./tests/run-tests.sh          # 247 tests, about two minutes
./tests/run-tests.sh -v amd   # filter, show output of failures
```

The suite runs the real script against mocks — a fake `nvidia-smi` and simulated
sysfs trees — so it gives the same result on a machine with no GPU at all. Each
vendor is tested at two generations, modern and old, because it is on the old
one, where metrics are missing, that the empty-cell contract is put to the test.

Details in [tests/README.md](tests/README.md).

## Contributing

**If you have an AMD or Intel GPU, the most useful thing you can do takes a
minute:** run two commands and paste the output into an issue. The Intel backend
has never touched real hardware, and the AMD one was verified against a single
card. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Analysis examples

```bash
# peak and average VRAM used
awk -F, 'NR>1 { s+=$7; if ($7>m) m=$7 } END { printf "avg %.0f MiB | peak %d MiB\n", s/(NR-1), m }' \
    ~/.monitor/log/monitor-*.csv

# samples where the GPU went over 80%
awk -F, 'NR>1 && $4>80' ~/.monitor/log/monitor-*.csv

# did the GPU wait on the disk? cross GPU util with disk util in the same second
awk -F, 'FNR==1 { next }
         FILENAME ~ /-disk/ { d[substr($1,1,19)] = $7; next }
         { g = substr($1,1,19); if (g in d) printf "%s  gpu %3s%%  disk %5.1f%%\n", g, $4, d[g] }' \
    ~/.monitor/log/monitor-*-disk.csv ~/.monitor/log/monitor-*[0-9].csv

# who grew during the collection: first vs last reading per PID
awk -F, 'NR>1 { if (!(($3) in first)) first[$3]=$6; last[$3]=$6; name[$3]=$5 }
         END { for (p in last) printf "%-24s pid %-7s %+6d MiB\n", name[p], p, last[p]-first[p] }' \
    ~/.monitor/log/monitor-*-procs.csv | sort -k4 -n

# the GPU went idle: what were the target threads doing? (run with -f pid:N)
awk -F, 'FNR==1 { next }
         FILENAME !~ /-threads/ { if ($4 == 0) idle[substr($1,1,19)] = 1; next }
         substr($1,1,19) in idle { printf "%s  %-20s %s %5.1f%%  %s\n", $1, $4, $5, $6, $7 }' \
    ~/.monitor/log/game-*[0-9].csv ~/.monitor/log/game-*-threads.csv
```

## Why not `--query-compute-apps`

`nvidia-smi --query-compute-apps=pid,used_memory` is the canonical route, but it
only sees **CUDA** contexts. On a desktop, VRAM in use is usually all from
**graphics** processes (Xorg, browser, game, compositor), and the query comes
back empty — attributing nothing. This uses `nvidia-smi -q -d PIDS`, which
reports both families with an explicit type; `--procs compute` keeps whatever
has a compute context (`C`, and also `C+G` — a game using CUDA and video at
once) and reproduces the `--query-compute-apps` slice.

## In practice

The threads CSV, `-P`, the nouveau backend and the probe were written while
chasing ~3 s freezes in Dota 2 on a Ryzen laptop. The cause turned out to be
the firmware leaving CPU 0's TSC seconds behind the other cores, made frequent
by the kernel's amd-pstate preferred-core ranking. The whole investigation,
with the data from each tool, is in
[ValveSoftware/Dota-2#3558](https://github.com/ValveSoftware/Dota-2/issues/3558).

## Changelog

What changed in each version: [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
