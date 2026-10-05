# Installing monitor

[English](INSTALL.md) · [Português](INSTALL.pt-BR.md)

## Quick start

```bash
git clone https://github.com/rattones/monitor.git
cd monitor
./install.sh
```

That installs into `~/.local` — no root needed. Then:

```bash
monitor --version
monitor -d 10
```

If the command is not found, `~/.local/bin` is not in your `PATH`. The
installer says so and prints the exact line to add to your `~/.bashrc` or
`~/.zshrc`.

## Without installing

The script runs straight from the clone. Nothing needs to be installed:

```bash
./monitor.sh -d 10
```

## Install modes

| Command | Where it goes | Root? |
|---|---|---|
| `./install.sh` | `~/.local` | no |
| `sudo ./install.sh --system` | `/usr/local` (all users) | yes |
| `./install.sh --prefix DIR` | `DIR` | depends on `DIR` |
| `./install.sh --link` | points at the clone (development) | no |

With no flag, the prefix follows who is running: root installs system-wide,
a regular user installs for themselves. That avoids both an unnecessary `sudo`
and a permission failure when root clearly meant system-wide.

**`--link` is for development.** The installed command points at your working
tree, so editing the code changes the command's behavior immediately. Every
other mode **copies**, so moving or deleting the clone later does not break
anything.

## What gets installed

```
<prefix>/bin/monitor          the command (a 3-line launcher)
<prefix>/bin/freeze-probe     the freeze probe (a 3-line launcher; run with sudo)
<prefix>/lib/monitor/         monitor.sh, lib/ and probe/
```

`freeze-probe` is installed with the monitor but grants nothing by being
installed: it runs only when you call it with `sudo`, when you decide you need
it. It needs `bpftrace` (`sudo apt install bpftrace`) and kernel BTF; the
monitor itself doesn't. sudo looks up commands in its `secure_path`, not your
`PATH`: with a `~/.local` install run `sudo ~/.local/bin/freeze-probe`; with
`--system`, `sudo freeze-probe` works as is. The installer prints the right
line. See [probe/README.md](probe/README.md).

The command in `bin/` is a launcher that points `MONITOR_LIB_DIR` at the
installed `lib/` and `exec`s the real script. The `exec` matters: without it an
extra shell would sit between your terminal and the collector, and Ctrl+C would
not reach whoever is collecting.

The installer checks the syntax of every file before copying, so a broken file
fails the install rather than leaving a broken command in your `PATH`.

## Requirements

| What | Why |
|---|---|
| **Linux** | reads `/proc/diskstats`, `/sys/block`, `/sys/class/drm` |
| **bash 4.0+** | `mapfile`, used in disk discovery |
| `awk` | mawk, gawk or busybox awk — no GNU extensions used |
| coreutils | `timeout`, `mktemp`, `mkfifo`, `readlink`, `date`, `sleep` |

For GPU metrics you also need, depending on the vendor:

| Vendor | Needs | Notes |
|---|---|---|
| NVIDIA | `nvidia-smi` (package `nvidia-utils-*`) | full support |
| AMD | nothing — reads sysfs | no per-process VRAM |
| Intel | nothing — reads sysfs | **untested on real hardware** |

The `disk` subcommand needs none of that and runs on a machine with no GPU at
all.

## Uninstalling

```bash
./install.sh --uninstall              # from ~/.local
sudo ./install.sh --uninstall --system # from /usr/local
```

Both commands, `monitor` and `freeze-probe`, are removed. A `freeze-probe`
that wasn't installed by this script is left alone.

**Your CSVs are kept.** They live in `~/.monitor/log`, outside anything the
installer touches. Delete them yourself if you want them gone.

## Where the data goes

CSVs go to `~/.monitor/log/` by default — in your home, not next to the script,
so the installed command never tries to write into a system directory and each
user keeps their own.

```bash
MONITOR_LOG_DIR=/data/metrics monitor -d 60   # somewhere else
monitor -o /tmp/run.csv -d 60                 # one specific file
```

## Environment variables

| Variable | What it does |
|---|---|
| `MONITOR_LOG_DIR` | where the CSVs go (default `$HOME/.monitor/log`) |
| `MONITOR_LANG` | forces the language (`en`, `pt`), ignoring the locale |
| `MONITOR_LIB_DIR` | where `lib/` is (set by the installed launcher) |
| `MONITOR_DRM_ROOT` | sysfs root for the AMD/Intel backends (used by the tests) |

## Troubleshooting

**`monitor: command not found` right after installing**
`~/.local/bin` is not in your `PATH`. Add the line the installer printed and
open a new shell.

**`no GPU recognized`**
No backend's probe accepted your hardware. Check with `lspci | grep -i vga`. If
you do have a supported GPU, force the backend: `monitor gpu -b amd`. On NVIDIA,
confirm the driver responds with `nvidia-smi -L`.

**`the AMD backend does not collect per-process VRAM`**
Expected: only NVIDIA reports per-process VRAM today. Use `monitor -p off` to
collect GPU and disk, or `monitor gpu` for the GPU alone. See
[CONTRIBUTING.md](CONTRIBUTING.md) if you want to help change that.

**`$CMD already exists and does not look like monitor's`**
Something else in that prefix is already named `monitor`. Pick another prefix
or pass `--force` if you are sure.

**A message appears as `<some_key>`**
A translation key without an entry. It is a bug — please
[open an issue](https://github.com/rattones/monitor/issues).
