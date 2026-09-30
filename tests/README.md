# Tests

[English](README.md) · [Português](README.pt-BR.md)

```bash
./tests/run-tests.sh              # 204 tests, about a minute
./tests/run-tests.sh -v           # show the output of each failure
./tests/run-tests.sh amd          # only tests whose name contains "amd"
```

The suite runs the real `monitor.sh` against fake data: a mocked `nvidia-smi` on
the `PATH` and simulated `/sys/class/drm` trees for AMD and Intel. Nothing
touches the machine's hardware, so **the result is the same on a machine with no
GPU at all** — which is exactly how the Intel backend is tested, since there is
no Intel GPU here.

## Two levels per vendor

Each backend is exercised with two generations. The old level is the one that
matters: it is where metrics are missing, and where the contract *"a missing
metric becomes an empty cell, never zero"* either holds or breaks.

| Vendor | Modern | Old | What the old one exercises |
|---|---|---|---|
| NVIDIA | RTX 4070 | **GTX 1050** | `power.draw` = `[N/A]` → empty column |
| AMD | RX 7800 XT | RX 560 (Polaris) | no `mem_busy_percent`; uses `power1_average` |
| Intel | Arc A770 | HD 630 (integrated) | no `lmem_*` → `vram_*` columns empty |

What each generation fails to report is not invented: it is what that hardware
actually does not expose. The values live in
[`mocks/gpu-profiles.sh`](mocks/gpu-profiles.sh).

## What is covered

- **Columns and units** — each backend, at both levels: bytes→MiB,
  thousandths→°C, microwatts→W, Hz→MHz. Intel checks the opposite case:
  `gt_*_freq_mhz` already comes in MHz and must **not** be divided.
- **Empty cells** — `[N/A]`, a missing sysfs file, an integrated GPU with no VRAM.
- **Cross-backend contract** — same header, 13 columns, millisecond timestamps
  in all three; no `N/A` ever written to a CSV.
- **Processes** — `C`/`G`/`C+G` types, `--procs compute` keeping `C+G`, filters
  by name and by PID, the warning when nothing matches.
- **Arguments** — the 9 options with a required value (the `shift 2` hang),
  interval in ms, subcommands, error messages.
- **Signals** — `SIGTERM` finishing with data preserved, no orphaned FIFOs, and
  the case of a backend with no external producer (AMD), where the awk *is* the
  source.
- **Driver failures** — mute driver, nonexistent GPU index.
- **i18n** — language detection, POSIX precedence, fallback to English,
  `MONITOR_LANG` overriding the locale, and that the **CSV does not change with
  the language**.

## The mocks

| File | Role |
|---|---|
| `mocks/gpu-profiles.sh` | the data of each hardware profile |
| `mocks/bin/nvidia-smi` | reproduces `-L`, `--query-gpu` and `-q -d PIDS` in the real binary's exact format |
| `mocks/bin/lspci` | the PCI class line used for the card name |
| `mocks/make-sysfs.sh` | builds a profile's fake `/sys/class/drm` tree |

Details in [mocks/README.md](mocks/README.md). The variables that control them:

| Variable | Effect |
|---|---|
| `MOCK_PROFILE` | which hardware profile to use |
| `MOCK_SAMPLES` | how many samples the stream emits (`0` = until killed) |
| `MOCK_FAIL` | `driver` (mute driver) or `nodevice` |
| `MONITOR_DRM_ROOT` | sysfs root the AMD/Intel backends read |

`MONITOR_DRM_ROOT` is the injection point that makes the sysfs backends
testable. In normal use it is `/sys/class/drm`.

## Checking that the tests detect regressions

A suite that only passes proves nothing. These three bugs were injected on
purpose, and each one was caught:

| Injected bug | Test that caught it |
|---|---|
| a missing metric becoming `0` instead of empty | `amd antiga: mem_util VAZIO` |
| dividing the Intel clock, which is already in MHz | `intel moderna: clock ja em MHz` |
| removing the `shift 2` guard | `arg -i sem valor nao trava` |

Worth repeating that exercise whenever you add a test: if it passes with both
the correct and the broken code, it is measuring nothing.

## Limitations

- The `nvidia-smi` mock emits several samples within the same second, and the
  process CSV's timestamp has 1s resolution. Process tests count distinct PIDs,
  not lines per timestamp.
- The disk test reads the **real** `/proc/diskstats` (read-only, no side
  effects). On a machine without it, that group is skipped.
- The system test uses a fake `/proc` (`MONITOR_PROC_ROOT`) with frozen
  counters, so CPU and PSI rates come out as "not measured" and only the
  `D`-state thread enters the threads CSV. Rates and the 10 s retention were
  checked by hand against real processes. The fake `uptime` is a link to the
  real one, because the collector's loop is paced and ended by that clock.
- The Intel backend is validated against a simulated sysfs, which exercises the
  reading and conversion logic — **not** that those paths exist on a real i915.
  Only a test on hardware settles that.
