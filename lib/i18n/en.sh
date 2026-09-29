# shellcheck shell=bash
#
# en.sh - English catalog. This is the SOURCE language: every key must exist
# here, because i18n_init loads it as the base layer under every other
# language. A key missing from a translation falls back to the English text.
#
# Conventions:
#   - Keys are <module>_<what>, so grepping "args_" finds every argument error.
#   - Placeholders are printf-style and positional. A language needing a
#     different word order can reorder them with %1$s, %2$s.
#   - Never put a translated string in a fixed-width slot ("%-10s"): under
#     LC_ALL=C the padding counts BYTES, so accented text misaligns the column.

# --- core ------------------------------------------------------------------
MSG[core_error_prefix]='error: %s\n'
MSG[core_load_module]='error: could not load lib/%s.sh\n'
MSG[core_fifo_name]='could not generate the FIFO name'
MSG[core_fifo_create]='could not create the FIFO %s'

# --- args ------------------------------------------------------------------
MSG[args_need_value]='option %s requires a value'
MSG[args_subcmd_order]='the subcommand must come before the options: %s %s ...'
MSG[args_unknown_opt]='unknown option: %s (use --help)'
MSG[args_nothing_to_collect]='nothing to collect: subcommand "%s" was turned off by --procs/--disk/--sys off'
MSG[args_interval_ms]='--interval is in whole milliseconds: use -i %s instead of -i %s'
MSG[args_interval_invalid]='invalid interval: %s (whole milliseconds)'
MSG[args_interval_min]='minimum interval is 100ms (you asked for %sms)'
MSG[args_duration_invalid]='invalid duration: %s'
MSG[args_gpu_idx_invalid]='invalid GPU index: %s'
MSG[args_top_invalid]='invalid value for --top: %s'
MSG[args_procs_mode]='invalid mode for --procs: %s (use all, compute or off)'
MSG[args_sys_mode]='invalid mode for --sys: %s (use all or off)'
MSG[args_filter_needs_procs]='--filter only makes sense with process or system collection enabled'

# --- filter ----------------------------------------------------------------
MSG[filter_needs_target]='--filter requires at least one PID or name'
MSG[filter_empty_target]='empty target in --filter'
MSG[filter_bad_pid]='invalid PID in --filter: %s'
MSG[filter_no_match]='\nwarning: no process matched the filter "%s".\n'
MSG[filter_on_gpu_now]='processes on the GPU right now: %s\n'

# --- csv -------------------------------------------------------------------
MSG[csv_write_failed]='could not write to %s'
MSG[csv_mkdir_failed]='could not create %s'

# --- disk ------------------------------------------------------------------
MSG[disk_none_found]='no physical disk found (use --disk off)'
MSG[disk_unknown]='unknown disk: %s (see lsblk -d)'
MSG[disk_none_selected]='no disk selected in --disk'

# --- sys -------------------------------------------------------------------
MSG[sys_bad_env]='invalid value in %s: %s (expected a number)'
MSG[sys_no_proc]='cannot read %s/stat - is /proc mounted? (use --sys off)'

# --- perf ------------------------------------------------------------------
MSG[perf_needs_pid]='--perf needs a target PID: use -f pid:N'
MSG[perf_not_found]='perf not found (on Ubuntu: sudo apt install linux-tools-common linux-tools-$(uname -r))'
MSG[perf_paranoid]='perf is blocked for regular users (perf_event_paranoid=%s); run: sudo sysctl kernel.perf_event_paranoid=1'

# --- backend ---------------------------------------------------------------
MSG[backend_unknown]='unknown backend: %s (looked in %s)'
MSG[backend_load_failed]='could not load the %s backend'
MSG[backend_incomplete]='the %s backend does not implement: %s'
MSG[backend_none_detected]='no GPU recognized (backends: %s) - use --backend to force one'
MSG[backend_no_procs]='the %s backend does not collect per-process VRAM (use --procs off or the gpu subcommand)'

# --- NVIDIA ----------------------------------------------------------------
MSG[nvidia_not_found]='nvidia-smi not found - is the NVIDIA driver installed?'
MSG[nvidia_no_driver]='nvidia-smi could not talk to the driver'
MSG[nvidia_list_failed]='nvidia-smi could not list the GPU%s: %s'
MSG[nvidia_no_gpu]='no GPU found%s'
MSG[nvidia_at_index]=' at index %s'
MSG[nvidia_of_index]=' of index %s'

# --- AMD / Intel -----------------------------------------------------------
MSG[amd_no_gpu]='no AMD GPU found%s'
MSG[intel_no_gpu]='no Intel GPU found%s'
MSG[intel_untested_1]='warning: the Intel backend has never been tested on real hardware.\n'
MSG[intel_untested_2]='         check the values against sysfs and report what diverges.\n'
MSG[intel_untested_3]='         gpu_util_pct comes out empty: occupancy needs i915_pmu (intel_gpu_top).\n'
MSG[intel_dbg_cards]='cards found: %s\n'
MSG[intel_dbg_gpu]='\nGPU %s: %s\n'
MSG[intel_dbg_no_pmu]='<no source: needs i915_pmu>'
MSG[intel_dbg_no_source]='<no source>'
MSG[intel_dbg_integrated]='<no source: integrated?>'
MSG[intel_dbg_no_mclk]='<no equivalent in i915/xe>'

# --- banner / footer -------------------------------------------------------
MSG[report_gpu]='GPU: %s (%s)\n'
MSG[report_one_card]='1 card'
MSG[report_n_cards]='%s cards'
MSG[report_writing_to]='writing to: %s\n'
MSG[report_procs_to]='processes in: %s (%s%s)\n'
MSG[report_filter_suffix]=', filter: %s'
MSG[report_disk_to]='disk in: %s (%s)\n'
MSG[report_sys_to]='system in: %s\n'
MSG[report_threads_to]='threads in: %s (PID %s)\n'
MSG[report_perf_to]='perf in: %s (%s Hz)\n'
MSG[report_interval]='interval: %sms | duration: %s | Ctrl+C to stop\n\n'
MSG[report_unlimited]='unlimited'
MSG[report_csv]='CSV: %s\n'
MSG[report_csv_procs]='CSV processes: %s\n'
MSG[report_csv_disk]='CSV disk: %s\n'
MSG[report_csv_sys]='system CSV: %s\n'
MSG[report_csv_threads]='threads CSV: %s\n'
MSG[report_csv_perf]='perf: %s\n'
MSG[report_samples]='\n%d samples written.\n'

# --- strings passed into awk (see the -v flags in report.sh / nvidia.sh) ----
MSG[awk_top_procs]='top %d processes by VRAM (avg / peak)'
MSG[awk_disk_header]='disk - read / write (avg / peak)'
MSG[awk_no_sensor]='no sensor'
MSG[awk_samples]='%d samples written.'
MSG[awk_sys_header]='system - average / peak'
MSG[awk_sys_core]='busiest core peak'
MSG[awk_sys_psi]='peak stall:'
MSG[awk_sys_proc]='target  '
MSG[awk_top_threads]='top %d threads by CPU (average / peak, %% of one core)'
