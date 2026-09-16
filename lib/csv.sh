# shellcheck shell=bash
#
# csv.sh - nomes dos arquivos, cabecalhos e abertura dos CSVs.
#
# Os cabecalhos ficam aqui, num lugar so, porque sao o contrato entre os
# backends e quem le os dados depois: qualquer fabricante escreve estas mesmas
# colunas, na mesma ordem. Metrica que o hardware nao reporta vira celula
# vazia - zero e um valor medido, vazio e a ausencia de medida.

GPU_CSV_HEADER="timestamp,gpu_index,gpu_name,gpu_util_pct,mem_util_pct,vram_total_mib,vram_used_mib,vram_free_mib,vram_used_pct,temp_c,power_w,sm_clock_mhz,mem_clock_mhz"
PROCS_CSV_HEADER="timestamp,gpu_index,pid,type,process_name,used_vram_mib"
DISK_CSV_HEADER="timestamp,device,read_mb_s,write_mb_s,read_iops,write_iops,util_pct,temp_c"

# So escreve cabecalho em arquivo novo/vazio, para permitir append entre sessoes.
init_csv() {
  local file="$1" header="$2"
  [[ -s "$file" ]] || printf '%s\n' "$header" > "$file" || die "nao consegui escrever em $file"
}

# Resolve os tres nomes de arquivo a partir de --output e abre so os que os
# coletores ativos vao usar. PROCS_SKIP/DISK_SKIP marcam onde esta sessao
# comeca, para o resumo final nao somar linhas de coletas anteriores.
setup_outputs() {
  if [[ -z "$OUTPUT" ]]; then
    mkdir -p "$SCRIPT_DIR/logs" || die "nao consegui criar $SCRIPT_DIR/logs"
    OUTPUT="$SCRIPT_DIR/logs/monitor-$(date +%Y%m%d-%H%M%S).csv"
  fi
  mkdir -p "$(dirname -- "$OUTPUT")" || die "nao consegui criar $(dirname -- "$OUTPUT")"

  PROCS_OUT="${OUTPUT%.csv}-procs.csv"
  DISK_OUT="${OUTPUT%.csv}-disk.csv"

  (( WANT_GPU )) && init_csv "$OUTPUT" "$GPU_CSV_HEADER"
  if (( WANT_PROC )); then
    init_csv "$PROCS_OUT" "$PROCS_CSV_HEADER"
    PROCS_SKIP=$(wc -l < "$PROCS_OUT")
  fi
  if (( WANT_DISK )); then
    init_csv "$DISK_OUT" "$DISK_CSV_HEADER"
    DISK_SKIP=$(wc -l < "$DISK_OUT")
  fi
  return 0
}
