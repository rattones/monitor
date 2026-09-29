# shellcheck shell=bash
#
# csv.sh - nomes dos arquivos, cabecalhos e abertura dos CSVs.
#
# Os cabecalhos ficam aqui, num lugar so, porque sao o contrato entre os
# backends e quem le os dados depois: qualquer fabricante escreve estas mesmas
# colunas, na mesma ordem. Metrica que o hardware nao reporta vira celula
# vazia - zero e um valor medido, vazio e a ausencia de medida.

# Onde os CSVs vao quando --output nao e informado. Fica na home, e nao ao lado
# do script, para o comando instalado em /usr/local/bin nao tentar escrever num
# diretorio do sistema - e para cada usuario ter os proprios logs.
# MONITOR_LOG_DIR sobrepoe, para quem quiser outro lugar sem passar -o sempre.
LOG_DIR="${MONITOR_LOG_DIR:-$HOME/.monitor/log}"

GPU_CSV_HEADER="timestamp,gpu_index,gpu_name,gpu_util_pct,mem_util_pct,vram_total_mib,vram_used_mib,vram_free_mib,vram_used_pct,temp_c,power_w,sm_clock_mhz,mem_clock_mhz"
PROCS_CSV_HEADER="timestamp,gpu_index,pid,type,process_name,used_vram_mib"
DISK_CSV_HEADER="timestamp,device,read_mb_s,write_mb_s,read_iops,write_iops,util_pct,temp_c"
SYS_CSV_HEADER="timestamp,cpu_util_pct,cpu_iowait_pct,cpu_max_core_pct,cpu_max_core,mem_used_mib,mem_avail_mib,swap_used_mib,psi_cpu_pct,psi_mem_pct,psi_io_pct,proc_cpu_pct,proc_threads,proc_running,proc_dstate,proc_majflt_s"
THREADS_CSV_HEADER="timestamp,pid,tid,thread_name,state,cpu_pct,wchan,user_pct,sys_pct,last_cpu,affinity"

# So escreve cabecalho em arquivo novo/vazio, para permitir append entre sessoes.
init_csv() {
  local file="$1" header="$2"
  [[ -s "$file" ]] || printf '%s\n' "$header" > "$file" || die "$(msg csv_write_failed "$file")"
}

# Resolve os nomes de arquivo a partir de --output e abre so os que os
# coletores ativos vao usar. PROCS_SKIP/DISK_SKIP marcam onde esta sessao
# comeca, para o resumo final nao somar linhas de coletas anteriores.
setup_outputs() {
  if [[ -z "$OUTPUT" ]]; then
    mkdir -p "$LOG_DIR" || die "$(msg csv_mkdir_failed "$LOG_DIR")"
    OUTPUT="$LOG_DIR/monitor-$(date +%Y%m%d-%H%M%S).csv"
  fi
  mkdir -p "$(dirname -- "$OUTPUT")" || die "$(msg csv_mkdir_failed "$(dirname -- "$OUTPUT")")"

  PROCS_OUT="${OUTPUT%.csv}-procs.csv"
  DISK_OUT="${OUTPUT%.csv}-disk.csv"
  SYS_OUT="${OUTPUT%.csv}-sys.csv"
  THREADS_OUT="${OUTPUT%.csv}-threads.csv"
  PERF_OUT="${OUTPUT%.csv}-perf.data"
  PERF_CLOCK="${OUTPUT%.csv}-perf.clock"
  PERF_LOG="${OUTPUT%.csv}-perf.log"

  (( WANT_GPU )) && init_csv "$OUTPUT" "$GPU_CSV_HEADER"
  if (( WANT_PROC )); then
    init_csv "$PROCS_OUT" "$PROCS_CSV_HEADER"
    PROCS_SKIP=$(wc -l < "$PROCS_OUT")
  fi
  if (( WANT_DISK )); then
    init_csv "$DISK_OUT" "$DISK_CSV_HEADER"
    DISK_SKIP=$(wc -l < "$DISK_OUT")
  fi
  if (( WANT_SYS )); then
    init_csv "$SYS_OUT" "$SYS_CSV_HEADER"
    SYS_SKIP=$(wc -l < "$SYS_OUT")
    # Sem PID-alvo nao ha thread a seguir: nem cria o arquivo, para um CSV so
    # com cabecalho nao parecer coleta quebrada.
    if [[ -n "$SYS_PIDS" ]]; then
      init_csv "$THREADS_OUT" "$THREADS_CSV_HEADER"
      THREADS_SKIP=$(wc -l < "$THREADS_OUT")
    else
      THREADS_OUT=/dev/null
    fi
  fi
  return 0
}
