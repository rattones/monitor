# freeze-probe: main-thread freeze probe

*[Português](README.pt-BR.md)*

A monitor subproject that answers **what holds a freeze and what releases it**,
which the monitor's CSVs (500 ms samples, unprivileged) can't reach. It uses
eBPF (bpftrace), so it needs root. **The monitor itself is unchanged**: it keeps
running as your user from the GameMode hook. The probe runs separately under
`sudo`, and both write to the same `~/.monitor/log` on the same local clock, so
timestamps line up.

## Usage

```bash
sudo freeze-probe --check    # once: validates the program on your kernel
sudo freeze-probe -n dota2   # waits for the process to start (any program)
sudo freeze-probe -f Game.exe   # or by a piece of its command line
sudo freeze-probe -p 12345   # or a process that is already running
freeze-probe -V              # version (the monitor's; no root needed)
```

`freeze-probe` is installed by the monitor's `install.sh`, next to `monitor`.
With the default `~/.local` install, sudo doesn't search your `PATH`: use
`sudo ~/.local/bin/freeze-probe -n NAME` (the installer prints the exact line), or
install with `sudo ./install.sh --system`. Straight from a clone:
`sudo ./probe/freeze-probe.sh`.

Then use the program. The probe attaches when it starts and exits when it
closes. Output: `~/.monitor/log/<name>-YYYYMMDD-HHMMSS-probe.txt` (the
process name), owned by you.

| Option | Effect |
|---|---|
| `-n NAME` | process name, exact (as in `ps -o comm`). The kernel keeps only 15 characters, so a longer name is matched by its first 15 |
| `-f PATTERN` | a piece of the command line: for programs started through wrappers (Proton/Wine, scripts) or with a generic name. Picks the oldest match and ignores the probe itself |
| `-p PID` | attach to a process that is already running |
| `-t MS` | freeze threshold in ms (default 500, minimum 50) |
| `-o DIR` | output directory (default: `~/.monitor/log` of the sudo caller) |
| `--check` | only compile and attach the probes (`bpftrace --dry-run`), then exit |
| `-V` | version (the monitor's), no root needed |

Exactly one of `-n`, `-f` and `-p` is required (except with `--check` and `-V`).

Requires `bpftrace` (tested with 0.25) and a kernel with BTF
(`/sys/kernel/btf/vmlinux`).

## What counts as a freeze

The main thread (tid = pid) stopped for longer than the threshold:

| Variant | How the main thread is stopped |
|---|---|
| **A** | asleep in a `futex` (`FUTEX_WAIT` / `FUTEX_WAIT_BITSET`) |
| **B** | asleep in `epoll_wait` / `epoll_pwait` / `epoll_pwait2` |
| **C** | making no system calls at all: it is spinning itself |

## What each block records

The output is in Portuguese. Each freeze block contains:

- **`timeout_pedido_ms` / `ret`**: the timeout the main thread asked the kernel
  for (`-1` = none; `-2` = absolute `CLOCK_REALTIME` deadline) and the return
  value (`-110` = `ETIMEDOUT` for futex; `0` = timed out for epoll). This tells
  whether the ~3.2 s cap belongs to the main thread or to what it waits for.
- **`WAKE_MESMO_ENDERECO`**: another thread of the process issued `FUTEX_WAKE` on the exact
  address the main thread sleeps on, which proves the direct dependency.
- **`acordada por`**: who woke the main thread (`sched_waking`). The kernel
  stack shows the mechanism: `futex_wake` (another thread released it),
  `ep_poll_callback` from `eventfd_write`/socket/pipe (an epoll event), or
  `hrtimer_wakeup` (the timeout expired).
- **`primeiro_evento ... data=`** (variant B): the cookie of the event that woke
  epoll. The launcher reads the epoll `fdinfo` live and writes a
  `# epfd=N ...` table mapping each cookie to its fd and target
  (`anon_inode:[eventfd]`, `socket:[...]`, ...).
- **Threads of the process running during the freeze**: 99 Hz samples with user stack,
  thread and CPU. The spinning thread shows up here.
- **System calls by the other threads**: syscall numbers (`ausyscall NR`
  translates them). A pure spin makes none.

## Cost and limits

- Outside freezes, only the **main thread's** futex/epoll calls and syscall
  entries and exits are traced, plus cheap filters on `sched_waking` and the
  profile samples. Everything else records only while a freeze is in progress.
- Programs often ship without debug symbols (Dota 2's libraries do): stacks show library, offset
  and the few exported functions (such as `ThreadSpin`). Stacks may be short
  where the code omits frame pointers.
- `profile:hz:99` sampling misses freezes shorter than ~10 ms. That doesn't
  matter for thresholds in the hundreds of ms.
- **Known gap:** on kernel 7.0 the `sched_waking` capture ("who woke it") worked
  for futex waits but came back empty for every epoll wait. The reason is not
  known yet. For epoll, the `primeiro_evento` line and the fd table still tell
  which eventfd fired.

## Files

| File | Role |
|---|---|
| `freeze-probe.sh` | launcher (bash, root): waits for the process, writes the header, runs bpftrace, maps epoll cookies, exits with the program |
| `freeze.bt` | the bpftrace program |
| `<output>.maps` | written during the session: the process's executable mappings (every 30 s and on each freeze). At the end the launcher uses it to rewrite `0x... ([unknown])` frames as `library.so+0xoffset` |

Tests: `tests/run-tests.sh probe` (fake bpftrace in `tests/mocks/bin/` and a
fake `/proc`; no root needed).
