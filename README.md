# monitor

[English](README.md) · [Português](README.pt-BR.md)

Samples GPU usage — including VRAM — and writes it to CSV, twice a second by
default. It also writes a CSV charging VRAM to each process, to tie memory churn
to whoever caused it, and a CSV with disk read/write and temperature.

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

Three collectors on one timeline: GPU, per-process VRAM and disk, sampled on the
same clock so the CSVs join on the timestamp. No daemon, no dependencies beyond
bash and awk, and the files are flushed every sample so you can plot them while
collection is still running.

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

The three collectors are independent and can run alone. With no subcommand the
default is `all`.

| Subcommand | Collects | File |
|---|---|---|
| `all` (default) | GPU, processes and disk | all three |
| `gpu` | GPU metrics only | `<output>.csv` |
| `disk` | disk I/O and temperature | `<output>-disk.csv` |
| `proc` | per-process VRAM only | `<output>-procs.csv` |

```bash
monitor disk -D nvme0n1 -d 60   # disk only
monitor proc -f chrome          # processes only, filtered
monitor gpu -i 250              # GPU only, 4 samples/s
```

The subcommand comes **before** the options. `disk` needs no GPU at all: it
reads only `/proc` and `/sys`, so it runs on a machine without `nvidia-smi`.

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
| `-t, --top N` | How many processes in the final summary (default `5`; `0` off) |
| `-q, --quiet` | Only write the CSVs, print nothing |
| `-h, --help` | Help |
| `-V, --version` | Version |

Ctrl+C stops cleanly: the last sample is written, the summary is printed, and no
process is left orphaned.

## GPU support

| Backend | GPU metrics | Per-process VRAM |
|---|---|---|
| `nvidia` | yes | yes |
| `amd` | yes | no |
| `intel` | yes\* | no |

The backend is autodetected, or forced with `-b/--backend`.

**AMD** reads the `amdgpu` driver's sysfs — no root, no external tool. Verified
against a Radeon Vega (Cezanne). On that APU `mem_util_pct` comes out empty
because the card does not expose `mem_busy_percent`; dedicated cards usually do.

**\* Intel** was written from kernel documentation and has **never run on real
hardware** — there is no Intel GPU on the development machine. Its parsing and
unit conversion are exercised against a simulated sysfs tree, but the paths
themselves are unverified. It warns about this when it starts.
[Help us fix that →](CONTRIBUTING.md)

Neither AMD nor Intel has an equivalent to `nvidia-smi -q -d PIDS`, so `proc` is
refused on them with an explanation rather than producing an empty CSV. To
collect GPU and disk on AMD:

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

### A metric that is not reported is empty, never zero

Zero is a measured value; empty is the absence of a measurement. Every backend
writes the same columns in the same order — that is what lets you put
collections from different machines on the same chart — and leaves a cell empty
when that hardware does not expose the metric.

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
install.sh              installs/removes the system command
lib/
├── core.sh             die, run_source, FIFOs, traps, waiting
├── backend.sh          GPU backend contract + autodetection
├── csv.sh              headers and file setup
├── args.sh             subcommand, options, validation
├── filter.sh           --filter targets
├── disk.sh             disk collector (needs no GPU)
├── report.sh           banner, summaries, footer
├── i18n.sh             language detection and catalog
├── i18n/               messages and help per language
└── backends/
    ├── nvidia.sh       via nvidia-smi — implemented
    ├── amd.sh          via amdgpu sysfs — implemented (no per-process VRAM)
    └── intel.sh        via i915/xe sysfs — untested on hardware
tests/                  test suite and mocks
```

Everything vendor-specific lives in `lib/backends/<name>.sh`, behind the
contract described in `lib/backend.sh`. A backend implements seven functions;
the loader checks they all exist and refuses an incomplete file listing what is
missing, rather than failing halfway through a collection.

## Tests

```bash
./tests/run-tests.sh          # 106 tests, about a minute
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
```

## Why not `--query-compute-apps`

`nvidia-smi --query-compute-apps=pid,used_memory` is the canonical route, but it
only sees **CUDA** contexts. On a desktop, VRAM in use is usually all from
**graphics** processes (Xorg, browser, game, compositor), and the query comes
back empty — attributing nothing. This uses `nvidia-smi -q -d PIDS`, which
reports both families with an explicit type; `--procs compute` keeps whatever
has a compute context (`C`, and also `C+G` — a game using CUDA and video at
once) and reproduces the `--query-compute-apps` slice.

## License

MIT — see [LICENSE](LICENSE).
