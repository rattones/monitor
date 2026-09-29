# Mocks

[English](README.md) · [Português](README.pt-BR.md)

Fake hardware for the test suite. This is what lets the tests run **on a machine
with no GPU at all** — and it is the only way the Intel backend is exercised,
since there is no Intel GPU on the development machine.

| File | Role |
|---|---|
| `gpu-profiles.sh` | the hardware data each profile reproduces |
| `bin/nvidia-smi` | fakes `-L`, `--query-gpu` and `-q -d PIDS` |
| `bin/lspci` | the PCI class line used to name the card |
| `bin/perf` | fakes `perf record` (for `-P`) and `perf script` (for `tools/perf-window.sh`) |
| `make-sysfs.sh` | builds a fake `/sys/class/drm` tree for a profile |

## The point: which files exist, not just which values

A mock that only changes numbers tests nothing interesting. What matters here is
reproducing **which files a given generation exposes** — because that is what
exercises the contract *"a metric the hardware does not report becomes an empty
cell, never zero"*.

So `amd_antiga` does not create `mem_busy_percent` at all, and `intel_antiga`
does not create `lmem_*`. The absence is the test.

## Profiles

Two per vendor. The old one is the one that matters.

| Profile | Hardware | What it exercises |
|---|---|---|
| `nvidia_moderna` | RTX 4070, 12 GiB | everything reported |
| `nvidia_antiga` | **GTX 1050**, 2 GiB | `power.draw` = `[N/A]` → empty cell |
| `amd_moderna` | RX 7800 XT, 16 GiB | `mem_busy_percent` and `power1_input` present |
| `amd_antiga` | RX 560 (Polaris), 4 GiB | no `mem_busy_percent`; uses `power1_average` |
| `intel_moderna` | Arc A770, 16 GiB | dedicated: has `lmem_*` |
| `intel_antiga` | HD 630 (integrated) | no `lmem_*` → `vram_*` empty |

What each generation fails to report is not invented — it is what that hardware
actually does not expose. The `power1_average` vs `power1_input` split is real:
the development machine's Vega exposes `power1_input` where the documentation
said `power1_average`, which is why the backend looks for both.

Values are in sysfs units — VRAM in bytes, temperature in thousandths of a
degree, power in microwatts, clocks in Hz. Converting them is the backend's job,
and checking that conversion is the test's job.

## Variables

| Variable | Effect |
|---|---|
| `MOCK_DIR` | where the mocks live (the suite exports it) |
| `MOCK_PROFILE` | which hardware profile to use |
| `MOCK_SAMPLES` | how many samples the stream emits (`0` = until killed) |
| `MOCK_FAIL` | `driver` (mute driver, exit 9) or `nodevice` |
| `MONITOR_DRM_ROOT` | sysfs root the AMD/Intel backends read |
| `MONITOR_PROC_ROOT` | `/proc` root the `sys` collector and `-P` read |
| `MOCK_PERF_SCRIPT` | file `perf script` prints (a captured real output) |
| `MOCK_PERF_LOG` | where `perf script` writes its arguments, to check `--time` |

`MONITOR_DRM_ROOT` is the injection point that makes the sysfs backends
testable. It is defined in `lib/backend.sh` and defaults to `/sys/class/drm`.

## Running a mock by hand

Useful when a test fails and you want to see what the backend actually received:

```bash
export MOCK_DIR=tests/mocks

# What nvidia-smi returns for an old card
MOCK_PROFILE=nvidia_antiga tests/mocks/bin/nvidia-smi \
  --query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.total,\
memory.used,memory.free,temperature.gpu,power.draw,clocks.sm,clocks.mem \
  --format=csv,noheader,nounits

# Build a fake sysfs tree and point the backend at it
tests/mocks/make-sysfs.sh /tmp/fakesys amd_antiga
MONITOR_DRM_ROOT=/tmp/fakesys/class/drm ./monitor.sh gpu -b amd -d 2

# The same for Intel, which has no real hardware here
tests/mocks/make-sysfs.sh /tmp/fakeintel intel_moderna
MONITOR_DRM_ROOT=/tmp/fakeintel/class/drm ./monitor.sh gpu -b intel -d 2
```

## Adding a profile

1. Add a `profile_<name>()` function to `gpu-profiles.sh`, exporting the same
   variables as its siblings.
2. If it is AMD or Intel, make sure `make-sysfs.sh` only creates the files that
   generation really has — omitting a file is how you test the empty cell.
3. Add the assertions to `run-tests.sh`, including what should come out
   **empty**.

Then break the backend on purpose and confirm your new test fails. A test that
passes with both correct and broken code is measuring nothing.

## Fidelity

The `nvidia-smi` mock reproduces the real binary's output format, captured from
an RTX 3050 — including the indented `-q -d PIDS` block and the `[N/A]` that
cards without a power sensor return. If the real tool's format ever changes,
this mock has to change with it, or the tests will pass against a format that no
longer exists.

The `lspci` mock returns a line with the `VGA compatible controller` class,
because the backends filter on that before trusting the name. That filter exists
for a reason: without it, a slot pointing at something else would give a GPU the
name of a network card, silently.

The `perf` mock's `record` writes its arguments into the `-o` file and stays
alive until a signal arrives, then appends which one (`stopped: INT`). The real
`perf` only closes `perf.data` cleanly on SIGINT, so the signal is what the tests
check. That part is in perl, not bash: the monitor starts `perf` with `&`, and a
non-interactive shell starts background children with SIGINT ignored — bash
cannot trap a signal that arrived ignored, while perl (and the real `perf`)
install their own handler over it. `perf script` output follows the real
format: sample header at column 0, frames indented by a tab, kernel frames
without symbols.
