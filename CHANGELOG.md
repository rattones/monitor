# Changelog

[English](CHANGELOG.md) · [Português](CHANGELOG.pt-BR.md)

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version is the
one printed by `monitor --version`.

## [3.4] — 2026-09-29

### Added

- **`-P, --perf`** (`lib/perf.sh`): runs `perf record` on the `-f pid:N`
  targets alongside the collectors, to show *where* a spinning thread spends
  its CPU — which library and function — not just *which* thread it is.
  - `<output>-perf.data`: compressed call-graph samples, 49 Hz by default
    (`MONITOR_PERF_FREQ`), on `CLOCK_MONOTONIC`.
  - `<output>-perf.clock`: a wall-clock/monotonic pair read at start, to map
    perf time onto the CSVs' timestamps; `<output>-perf.log`: perf's output.
  - Refused up front, with the fix, when there is no PID target, `perf` is
    missing, or `perf_event_paranoid` blocks regular users.
- `tools/perf-window.sh`: takes a time window as the CSVs show it and prints
  the samples by thread, by library, and by the first frame outside the kernel.
- `<output>-threads.csv` gains four columns: `user_pct` and `sys_pct`
  (`cpu_pct` split between the program's code and the kernel), `last_cpu` and
  `affinity`.
- 58 new tests (184 in total): `-P` against a fake `perf`, `perf-window.sh`,
  the user/kernel CPU split against a thread that really burns CPU on the
  collector's clock, and argument, filter and disk errors that had no test.

### Changed

- **Breaking for CSV readers:** `<output>-threads.csv` now has 11 columns
  instead of 7; the new ones are appended at the end.
- `-f/--filter` is also accepted when only `-P` would use it.
- `-P` reads `perf_event_paranoid` under `MONITOR_PROC_ROOT`, like the `sys`
  collector, so the tests do not depend on the machine's sysctl.

### Fixed

- The "no orphan FIFOs" test counted every `gpumon*` in `/tmp`, so it failed
  whenever a real `monitor` was running on the same machine; it now uses a
  `TMPDIR` of its own.
- `tools/perf-window.sh` went on with an empty window after an invalid time,
  instead of stopping.

## [3.3] — 2026-09-29

### Added

- **`sys` collector** (`lib/sys.sh`): CPU, memory and pressure on the same
  timeline as the GPU, to answer what GPU metrics alone cannot — when the GPU
  goes idle mid-game, who stopped feeding it. Needs no GPU; reads only `/proc`.
  - `<output>-sys.csv`: overall CPU and iowait, the busiest core and which one,
    memory, available memory and swap in use, PSI stall percentages for CPU,
    memory and I/O, and — with `-f pid:N` — the target's CPU, thread counts
    (total, running, `D`-state) and major page faults per second.
  - `<output>-threads.csv` (only with `-f pid:N`): one line per active target
    thread per sample, with state, CPU and `wchan`. A thread stays in the file
    for 10 s after going idle, so a stalled render thread does not vanish the
    moment it becomes interesting. `D`-state threads always enter.
- `sys` subcommand and `-S, --sys MODE` option (`all` | `off`); `all` now runs
  four collectors.
- `MONITOR_THREADS_MIN_PCT` and `MONITOR_THREADS_HOLD_S` to tune the thread
  threshold and retention; `MONITOR_PROC_ROOT` points the collector at another
  `/proc` (used by the tests).
- End-of-run summary for the system (average/peak CPU, busiest core, PSI peaks,
  target CPU) and the top threads by CPU, bounded by `-t`.
- 20 new tests (126 in total), against a fake `/proc`.

### Changed

- `-f/--filter` is also accepted by the `sys` collector, not only by `proc`.
- `-t/--top` now also bounds the thread summary.

## [3.2] — 2026-09-16

### Added

- `install.sh`: installs `monitor` as a system command (`/usr/local` as root,
  `~/.local` otherwise); copies by default, `--link` for development.
- **AMD backend** via `amdgpu` sysfs, no root and no external tool. Verified on
  one real GPU.
- **Intel backend** via `i915`/`xe` sysfs, written from documentation and not
  yet run on real hardware; it warns about that on start.
- Test suite (`tests/run-tests.sh`) with hardware mocks: fake `nvidia-smi` and
  simulated `/sys/class/drm` trees for two generations of each vendor.
- i18n: help, errors, banner and summaries in English and Portuguese, picked
  from the locale (`LC_ALL` > `LC_MESSAGES` > `LANG`) or `MONITOR_LANG`.
  CSVs are identical in every language.
- Bilingual README, INSTALL and CONTRIBUTING; MIT license.

### Changed

- CSVs now go to `~/.monitor/log` (override with `MONITOR_LOG_DIR`) instead of
  `./logs` next to the script.
- AMD and Intel backends check the PCI class before naming a GPU, so a slot
  pointing to another device no longer names the GPU after, say, a network card.

## [3.1] — 2026-09-16

### Changed

- Renamed `gpu-monitor.sh` to `monitor.sh`; default CSVs are now
  `monitor-<date>.csv`.
- **Breaking:** `-i/--interval` takes integer milliseconds, default `500`
  (was 1 s). `-i 0.5` is rejected with a hint to use `-i 500`.

## [3.0] — 2026-09-16

### Changed

- Code split into modules under `lib/`, with vendor-specific code behind a
  seven-function backend contract in `lib/backend.sh`. A backend is picked by
  autodetection or `-b/--backend`, and an incomplete one is refused up front.

## [2.0] — 2026-09-16

### Added

- Subcommands `gpu`, `disk` and `proc`; with none, the default `all` runs all
  three. `disk` runs on a machine without `nvidia-smi`.

### Fixed

- An option with no value at the end of the line looped forever.
- Ctrl+C hung the script: the producer was left orphaned holding the FIFO.

## [1.1] — 2026-09-16

- State before the subcommand refactor: NVIDIA only, GPU, per-process VRAM and
  disk CSVs.
