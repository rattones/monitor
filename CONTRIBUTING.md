# Contributing

[English](CONTRIBUTING.md) · [Português](CONTRIBUTING.pt-BR.md)

## The one thing we need most: AMD and Intel hardware reports

This project has a specific, unglamorous problem: **the AMD backend was
verified against exactly one GPU, and the Intel backend has never run on real
hardware at all.**

There is no Intel GPU on the development machine. The Intel backend was written
from kernel documentation and validated against a *simulated* sysfs tree — which
proves the parsing and unit conversion work, but proves nothing about whether
those files exist on a real i915 or xe device, or whether the units match.

If you have an AMD or Intel GPU, **running two commands and pasting the output
into an issue is the single most valuable contribution you can make.** It takes
about a minute and does not require knowing any bash.

### AMD report

```bash
./monitor.sh gpu -b amd -d 3
```

Then the raw values it read, so we can check the conversions:

```bash
for c in /sys/class/drm/card[0-9]*; do
  grep -q '^DRIVER=amdgpu$' "$c/device/uevent" 2>/dev/null || continue
  echo "== $c"
  for f in gpu_busy_percent mem_busy_percent mem_info_vram_total \
           mem_info_vram_used pp_dpm_mclk; do
    printf '%-24s %s\n' "$f" "$(cat "$c/device/$f" 2>/dev/null || echo ABSENT)"
  done
  for h in "$c"/device/hwmon/hwmon*; do
    for f in temp1_input power1_input power1_average freq1_input; do
      printf '%-24s %s\n' "$f" "$(cat "$h/$f" 2>/dev/null || echo ABSENT)"
    done
  done
done
lspci | grep -iE 'vga|3d|display'
```

### Intel report

```bash
./monitor.sh gpu -b intel -d 3
```

It will warn that the backend is untested — that is expected, and exactly why
we need the report.

```bash
for c in /sys/class/drm/card[0-9]*; do
  grep -qE '^DRIVER=(i915|xe)$' "$c/device/uevent" 2>/dev/null || continue
  echo "== $c"
  for f in gt_cur_freq_mhz gt_act_freq_mhz lmem_total_bytes lmem_avail_bytes; do
    printf '%-24s %s\n' "$f" "$(cat "$c/$f" 2>/dev/null || echo ABSENT)"
  done
  for h in "$c"/device/hwmon/hwmon*; do
    for f in temp1_input power1_input power1_average; do
      printf '%-24s %s\n' "$f" "$(cat "$h/$f" 2>/dev/null || echo ABSENT)"
    done
  done
done
lspci | grep -iE 'vga|3d|display'
```

Also useful: `uname -r` (kernel version) and your distribution.

### What we do with it

We compare each CSV column against the raw sysfs value. That is how the AMD
backend got fixed before release — the real hardware exposed `power1_input`
where the documentation had said `power1_average`, and only running it on a real
card revealed that. `ABSENT` lines are just as useful as present ones: they tell
us which metrics that generation does not expose, so the column correctly comes
out **empty** instead of zero.

### Please do NOT send `-procs.csv`

The per-process CSV lists **the names of programs you ran** — browsers, games,
scripts, work tools. It is not needed for hardware validation, and an issue is
public.

The commands above only produce the GPU CSV. If you collected with `all`, send
only `monitor-<date>.csv` and leave `monitor-<date>-procs.csv` out.

The GPU CSV contains only the card model, metrics and timestamps — nothing that
identifies you.

[**Open a hardware report →**](https://github.com/rattones/monitor/issues/new)

---

## Other ways to help

### Per-process VRAM on AMD and Intel

The biggest missing feature. NVIDIA reports it through `nvidia-smi -q -d PIDS`;
neither AMD nor Intel has an equivalent, so `monitor proc` refuses to run on
them rather than producing an empty CSV.

The viable route is the `fdinfo` of `/dev/dri/*` file descriptors — the
`drm-memory-*` lines, which is how `nvtop` does it, without root. It means
scanning `/proc/*/fdinfo/*` each sample.

Starting points are marked `TODO` in
[`lib/backends/amd.sh`](lib/backends/amd.sh) and
[`lib/backends/intel.sh`](lib/backends/intel.sh). When it works,
`<vendor>_supports_procs` returns 0 and the subcommand unlocks itself.

### A new vendor backend

A backend is one file in `lib/backends/<name>.sh` implementing seven functions.
The contract is documented in full at the top of
[`lib/backend.sh`](lib/backend.sh).

The loader checks the contract and refuses an incomplete file **listing exactly
what is missing** — so you find out at load time, not halfway through a
collection.

### A new language

Copy `lib/i18n/en.sh` to `lib/i18n/<code>.sh` and translate the values. English
is always loaded as the base layer, so you can translate part of it and the rest
falls back to English rather than leaving holes.

One rule: **no accented characters in the catalogs.** Under `LC_ALL=C` awk pads
`%-Ns` by bytes, not characters, so an accent would misalign a column. The
Portuguese catalog follows this.

Help text lives in `lib/i18n/usage-<code>.sh` — plain prose, not array entries.

---

## Working on the code

### Tests

```bash
./tests/run-tests.sh          # 126 tests, about a minute
./tests/run-tests.sh -v amd   # filter, and show output of failures
```

The suite runs the real script against mocks — a fake `nvidia-smi` and
simulated sysfs trees — so **it gives the same result on a machine with no GPU
at all.** You do not need the hardware to run the tests.

Each vendor is exercised at two levels, modern and old. The old one matters
most: it is where metrics are missing, and where the contract *"a metric the
hardware does not report becomes an empty cell, never zero"* either holds or
breaks.

Details in [tests/README.md](tests/README.md).

### Checking that a test actually detects something

A suite that only passes proves nothing. When you add a test, break the code on
purpose and confirm it fails. Three bugs were injected this way to validate the
existing suite — an empty metric turning into `0`, the Intel clock being divided
when it is already in MHz, and the removal of the `shift 2` guard — and each was
caught by its corresponding test.

### Things that look wrong but are not

A few pieces of this codebase are deliberate and were paid for in debugging
time. Before "fixing" one, read the comment above it:

- **`LC_ALL=C` before every `awk`.** Without it, a pt_BR locale makes `%.1f`
  emit a decimal comma and splits a CSV column in two. It is load-bearing.
- **`exec` inside `run_source`.** Without it, a function launched with `&`
  leaves `$!` pointing at the subshell instead of the real producer; Ctrl+C
  would kill the shell and orphan `nvidia-smi` holding the FIFO open.
- **`make_fifo` returning via a variable, not stdout.** Calling it via `$(...)`
  would put it in a subshell, and the cleanup registry would die with it,
  leaving FIFOs behind in `/tmp`.
- **`stop()` falling back to `*_AWK_PID`.** A backend that reads sysfs has no
  external producer — the awk *is* the source, and nothing would close it.
- **`msg_raw` next to `msg`.** A `%d` meant for awk must reach it unexpanded;
  the regular `msg` would consume it and print zero.

### Style

- **Comments are in Portuguese**, the rest of the code in English. Comments
  explain *why*, not *what* — if a decision took debugging to reach, say so.
- Every `die()` message goes through the catalog, so it follows the user's
  language.
- No new runtime dependencies. Running anywhere with bash and awk is the point.

### Pull requests

Run `./tests/run-tests.sh` before opening one. If you changed behavior, add a
test that fails without your change.

Small and focused beats large and comprehensive — a PR that does one thing gets
reviewed; one that does five waits.

## License

MIT — see [LICENSE](LICENSE). By contributing you agree your contribution is
licensed under the same terms.
