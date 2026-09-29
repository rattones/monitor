#!/usr/bin/env bash
#
# run-tests.sh - suite de testes do monitor.
#
# Roda o monitor de verdade contra mocks: um nvidia-smi falso no PATH e arvores
# /sys/class/drm falsas para AMD e Intel. Nada aqui toca o hardware da maquina,
# entao a suite da o mesmo resultado numa maquina sem GPU nenhuma - que e o
# ponto: e assim que se testa o backend Intel, para o qual nao ha hardware.
#
# Cada fabricante e exercitado em dois niveis, "moderna" e "antiga". O nivel
# antigo e o que importa: e onde faltam metricas, e onde o contrato "metrica
# ausente vira celula vazia, nunca zero" ou funciona ou quebra.
#
# Uso: ./tests/run-tests.sh [-v] [filtro]
#        -v       mostra o comando e a saida de cada teste que falhar
#        filtro   roda so os testes cujo nome contenha este trecho

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$TESTS_DIR")"
MONITOR="$ROOT/monitor.sh"
export MOCK_DIR="$TESTS_DIR/mocks"

VERBOSE=0
FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    *) FILTER="$1"; shift ;;
  esac
done

TMP=$(mktemp -d -t montest.XXXXXXXX) || { echo "nao consegui criar o diretorio temporario" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

# --- infraestrutura --------------------------------------------------------

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no()   {
  FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
  printf '  \033[31mFALHA\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2"
  if (( VERBOSE )) && [[ -n "${3:-}" ]]; then
    printf '         --- saida ---\n'
    printf '%s\n' "$3" | sed 's/^/         /'
  fi
}
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mskip\033[0m %s (%s)\n' "$1" "$2"; }

group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Um teste roda se nao ha filtro, ou se o nome casa com ele.
runs() { [[ -z "$FILTER" || "$1" == *"$FILTER"* ]]; }

# Compara e reporta.
eq() {
  local name="$1" got="$2" want="$3" out="${4:-}"
  runs "$name" || return 0
  if [[ "$got" == "$want" ]]; then ok "$name"
  else no "$name" "esperava [$want], veio [$got]" "$out"; fi
}

contains() {
  local name="$1" hay="$2" needle="$3"
  runs "$name" || return 0
  if [[ "$hay" == *"$needle"* ]]; then ok "$name"
  else no "$name" "esperava conter [$needle]" "$hay"; fi
}

# O campo N da primeira linha de dados do CSV (linha 2, depois do cabecalho).
field() { sed -n 2p "$1" 2>/dev/null | cut -d, -f"$2"; }

# Quantas linhas de dados o CSV tem.
rows() { local n; n=$(wc -l < "$1" 2>/dev/null || echo 1); echo $(( n - 1 )); }

# Roda o monitor com o PATH apontando para os mocks. O sysfs falso entra por
# MOCK_SYSFS, que os backends AMD/Intel leem via MONITOR_DRM_ROOT.
#
# MONITOR_LANG=en fixa o idioma: varias assercoes abaixo casam com o texto das
# mensagens, entao sem isto a suite passaria ou falharia conforme o $LANG de
# quem a roda.
run_monitor() {
  PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" MONITOR_LANG=en \
    "$MONITOR" "$@" 2>&1
}

# ===========================================================================
group "mocks"
# ===========================================================================

if runs "mock nvidia-smi enumera"; then
  out=$(MOCK_PROFILE=nvidia_moderna "$MOCK_DIR/bin/nvidia-smi" \
        --query-gpu=index,name,gpu_bus_id --format=csv,noheader)
  eq "mock nvidia-smi enumera" "$out" "0, NVIDIA GeForce RTX 4070, 00000000:01:00.0"
fi

if runs "mock nvidia-smi [N/A] na antiga"; then
  out=$(MOCK_PROFILE=nvidia_antiga "$MOCK_DIR/bin/nvidia-smi" \
        --query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.total,memory.used,memory.free,temperature.gpu,power.draw,clocks.sm,clocks.mem \
        --format=csv,noheader,nounits | cut -d, -f9 | tr -d ' ')
  eq "mock nvidia-smi [N/A] na antiga" "$out" "[N/A]"
fi

if runs "mock nvidia-smi driver morto"; then
  MOCK_FAIL=driver "$MOCK_DIR/bin/nvidia-smi" -L >/dev/null 2>&1
  eq "mock nvidia-smi driver morto" "$?" "9"
fi

for p in amd_moderna amd_antiga intel_moderna intel_antiga; do
  if runs "mock sysfs $p"; then
    if "$MOCK_DIR/make-sysfs.sh" "$TMP/sys_$p" "$p" >/dev/null 2>&1; then
      ok "mock sysfs $p"
    else
      no "mock sysfs $p" "make-sysfs.sh falhou"
    fi
  else
    "$MOCK_DIR/make-sysfs.sh" "$TMP/sys_$p" "$p" >/dev/null 2>&1
  fi
done

# ===========================================================================
group "NVIDIA - moderna (RTX 4070: reporta tudo)"
# ===========================================================================

export MOCK_PROFILE=nvidia_moderna MOCK_SAMPLES=4
csv="$TMP/nv_mod.csv"
out=$(run_monitor gpu -b nvidia -d 1 -q -o "$csv")

eq "nvidia moderna: 13 colunas"     "$(field "$csv" 13 >/dev/null; sed -n 2p "$csv" | awk -F, '{print NF}')" "13" "$out"
eq "nvidia moderna: nome"           "$(field "$csv" 3)"  "NVIDIA GeForce RTX 4070" "$out"
eq "nvidia moderna: util"           "$(field "$csv" 4)"  "78" "$out"
eq "nvidia moderna: vram total"     "$(field "$csv" 6)"  "12282" "$out"
eq "nvidia moderna: vram usada"     "$(field "$csv" 7)"  "3204" "$out"
eq "nvidia moderna: vram livre"     "$(field "$csv" 8)"  "9078" "$out"
eq "nvidia moderna: vram %"         "$(field "$csv" 9)"  "26.1" "$out"
eq "nvidia moderna: temp"           "$(field "$csv" 10)" "63" "$out"
eq "nvidia moderna: potencia"       "$(field "$csv" 11)" "182.45" "$out"
eq "nvidia moderna: clock sm"       "$(field "$csv" 12)" "2610" "$out"

# ===========================================================================
group "NVIDIA - antiga (GTX 1050: sem sensor de potencia)"
# ===========================================================================

export MOCK_PROFILE=nvidia_antiga
csv="$TMP/nv_old.csv"
out=$(run_monitor gpu -b nvidia -d 1 -q -o "$csv")

eq "nvidia antiga: 13 colunas"      "$(sed -n 2p "$csv" | awk -F, '{print NF}')" "13" "$out"
eq "nvidia antiga: nome"            "$(field "$csv" 3)"  "NVIDIA GeForce GTX 1050" "$out"
eq "nvidia antiga: vram total"      "$(field "$csv" 6)"  "2048" "$out"
# O ponto deste nivel: "[N/A]" tem de virar celula vazia, e nao "0" nem "[N/A]".
eq "nvidia antiga: potencia VAZIA"  "$(field "$csv" 11)" "" "$out"
eq "nvidia antiga: temp preenchida" "$(field "$csv" 10)" "58" "$out"

if runs "nvidia antiga: nao escreve N/A"; then
  if grep -q 'N/A' "$csv"; then
    no "nvidia antiga: nao escreve N/A" "o CSV contem N/A" "$(cat "$csv")"
  else ok "nvidia antiga: nao escreve N/A"; fi
fi

# ===========================================================================
group "NVIDIA - processos"
# ===========================================================================

export MOCK_PROFILE=nvidia_moderna
pcsv="$TMP/nv_proc-procs.csv"
out=$(run_monitor proc -b nvidia -d 1 -q -o "$TMP/nv_proc.csv")

# Conta PIDs distintos, e nao linhas por timestamp: o timestamp dos processos
# tem resolucao de 1s, entao varias amostras do mock caem no mesmo segundo e
# contar linhas mediria a cadencia, nao a quantidade de processos vistos.
if runs "procs: ve os 4 processos"; then
  n=$(awk -F, 'NR>1 {print $3}' "$pcsv" | sort -u | wc -l)
  eq "procs: ve os 4 processos" "$n" "4" "$out"
fi

if runs "procs: cada amostra traz os 4"; then
  # Todo bloco de 4 linhas consecutivas deve ter 4 PIDs distintos.
  n=$(awk -F, 'NR>1 {a[(NR-2)%4]=$3} (NR-1)%4==0 && NR>1 {
        if (a[0]==a[1] || a[1]==a[2] || a[2]==a[3]) bad=1
      } END {print bad ? "repetido" : "ok"}' "$pcsv")
  eq "procs: cada amostra traz os 4" "$n" "ok" "$out"
fi

eq "procs: tipo C+G preservado" \
   "$(awk -F, '$3==60282 {print $4; exit}' "$pcsv")" "C+G" "$out"
eq "procs: nome so o executavel" \
   "$(awk -F, '$3==4892 {print $5; exit}' "$pcsv")" "chrome" "$out"
eq "procs: vram do dota" \
   "$(awk -F, '$3==60282 {print $6; exit}' "$pcsv")" "1404" "$out"

# --procs compute: mantem C e C+G, descarta G puro.
pcsv2="$TMP/nv_comp-procs.csv"
out=$(run_monitor proc -b nvidia -p compute -d 1 -q -o "$TMP/nv_comp.csv")
if runs "procs compute: descarta G puro"; then
  has_g=$(awk -F, 'NR>1 && $4=="G" {print "sim"; exit}' "$pcsv2")
  eq "procs compute: descarta G puro" "${has_g:-nao}" "nao" "$out"
fi
if runs "procs compute: mantem C+G"; then
  has_cg=$(awk -F, 'NR>1 && $4=="C+G" {print "sim"; exit}' "$pcsv2")
  eq "procs compute: mantem C+G" "${has_cg:-nao}" "sim" "$out"
fi

# Filtros.
pcsv3="$TMP/nv_filt-procs.csv"
out=$(run_monitor proc -b nvidia -f chrome -d 1 -q -o "$TMP/nv_filt.csv")
if runs "filtro por nome: so o alvo"; then
  others=$(awk -F, 'NR>1 && $5!="chrome" {print "sim"; exit}' "$pcsv3")
  eq "filtro por nome: so o alvo" "${others:-nao}" "nao" "$out"
fi

pcsv4="$TMP/nv_fpid-procs.csv"
out=$(run_monitor proc -b nvidia -f 60282 -d 1 -q -o "$TMP/nv_fpid.csv")
eq "filtro por PID: so o alvo" \
   "$(awk -F, 'NR>1 {print $3}' "$pcsv4" | sort -u | paste -sd,)" "60282" "$out"

out=$(run_monitor proc -b nvidia -f naoexiste -d 1 -o "$TMP/nv_fnone.csv")
contains "filtro sem match: avisa" "$out" "no process matched"

# ===========================================================================
group "AMD - moderna (RX 7800 XT: reporta tudo)"
# ===========================================================================

export MOCK_PROFILE=amd_moderna
export MONITOR_DRM_ROOT="$TMP/sys_amd_moderna/class/drm"
csv="$TMP/amd_mod.csv"
out=$(run_monitor gpu -b amd -d 1 -q -o "$csv")

eq "amd moderna: 13 colunas"     "$(sed -n 2p "$csv" | awk -F, '{print NF}')" "13" "$out"
eq "amd moderna: util"           "$(field "$csv" 4)"  "82" "$out"
eq "amd moderna: mem_util"       "$(field "$csv" 5)"  "57" "$out"
eq "amd moderna: vram total MiB" "$(field "$csv" 6)"  "16384" "$out"
eq "amd moderna: vram usada MiB" "$(field "$csv" 7)"  "5120" "$out"
eq "amd moderna: temp C"         "$(field "$csv" 10)" "68" "$out"
eq "amd moderna: potencia W"     "$(field "$csv" 11)" "241.00" "$out"
eq "amd moderna: clock sm MHz"   "$(field "$csv" 12)" "2430" "$out"
eq "amd moderna: clock mem MHz"  "$(field "$csv" 13)" "2425" "$out"

# ===========================================================================
group "AMD - antiga (RX 560: sem mem_busy, power1_average)"
# ===========================================================================

export MOCK_PROFILE=amd_antiga
export MONITOR_DRM_ROOT="$TMP/sys_amd_antiga/class/drm"
csv="$TMP/amd_old.csv"
out=$(run_monitor gpu -b amd -d 1 -q -o "$csv")

eq "amd antiga: 13 colunas"       "$(sed -n 2p "$csv" | awk -F, '{print NF}')" "13" "$out"
eq "amd antiga: util"             "$(field "$csv" 4)"  "51" "$out"
# O ponto deste nivel: sem o arquivo, a coluna sai vazia - nao zero.
eq "amd antiga: mem_util VAZIO"   "$(field "$csv" 5)"  "" "$out"
eq "amd antiga: vram total MiB"   "$(field "$csv" 6)"  "4096" "$out"
eq "amd antiga: vram usada MiB"   "$(field "$csv" 7)"  "1024" "$out"
# power1_average em vez de power1_input: o backend tem de achar os dois.
eq "amd antiga: acha power1_average" "$(field "$csv" 11)" "78.00" "$out"
eq "amd antiga: clock sm MHz"     "$(field "$csv" 12)" "1275" "$out"

# ===========================================================================
group "Intel - moderna (Arc A770: dedicada, com VRAM)"
# ===========================================================================

export MOCK_PROFILE=intel_moderna
export MONITOR_DRM_ROOT="$TMP/sys_intel_moderna/class/drm"
csv="$TMP/intel_mod.csv"
out=$(run_monitor gpu -b intel -d 1 -q -o "$csv")

eq "intel moderna: 13 colunas"     "$(sed -n 2p "$csv" | awk -F, '{print NF}')" "13" "$out"
# Sem i915_pmu, a ocupacao nao tem fonte: vazia de proposito.
eq "intel moderna: util VAZIO"     "$(field "$csv" 4)"  "" "$out"
eq "intel moderna: vram total MiB" "$(field "$csv" 6)"  "16384" "$out"
eq "intel moderna: vram usada MiB" "$(field "$csv" 7)"  "4096" "$out"
eq "intel moderna: temp C"         "$(field "$csv" 10)" "61" "$out"
eq "intel moderna: potencia W"     "$(field "$csv" 11)" "190.00" "$out"
# gt_*_freq_mhz ja vem em MHz: nao pode ser dividido como o Hz do amdgpu.
eq "intel moderna: clock ja em MHz" "$(field "$csv" 12)" "2100" "$out"

# ===========================================================================
group "Intel - antiga (HD 630: integrada, sem VRAM)"
# ===========================================================================

export MOCK_PROFILE=intel_antiga
export MONITOR_DRM_ROOT="$TMP/sys_intel_antiga/class/drm"
csv="$TMP/intel_old.csv"
out=$(run_monitor gpu -b intel -d 1 -q -o "$csv")

eq "intel antiga: 13 colunas"      "$(sed -n 2p "$csv" | awk -F, '{print NF}')" "13" "$out"
# Numa integrada a memoria e a RAM do sistema: as colunas vram_* ficam vazias,
# e nao zeradas nem preenchidas com o total da RAM.
eq "intel antiga: vram total VAZIO" "$(field "$csv" 6)" "" "$out"
eq "intel antiga: vram usada VAZIO" "$(field "$csv" 7)" "" "$out"
eq "intel antiga: vram pct VAZIO"   "$(field "$csv" 9)" "" "$out"
eq "intel antiga: temp preenchida"  "$(field "$csv" 10)" "54" "$out"
eq "intel antiga: potencia VAZIA"   "$(field "$csv" 11)" "" "$out"
eq "intel antiga: clock preenchido" "$(field "$csv" 12)" "1150" "$out"

unset MONITOR_DRM_ROOT

# ===========================================================================
group "contrato entre backends"
# ===========================================================================

if runs "contrato: mesmo cabecalho nos 3"; then
  h1=$(head -1 "$TMP/nv_mod.csv"); h2=$(head -1 "$TMP/amd_mod.csv"); h3=$(head -1 "$TMP/intel_mod.csv")
  if [[ "$h1" == "$h2" && "$h2" == "$h3" ]]; then ok "contrato: mesmo cabecalho nos 3"
  else no "contrato: mesmo cabecalho nos 3" "cabecalhos divergem"; fi
fi

if runs "contrato: timestamp com ms"; then
  bad=""
  for f in "$TMP/nv_mod.csv" "$TMP/amd_mod.csv" "$TMP/intel_mod.csv"; do
    ts=$(field "$f" 1)
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}$ ]] || bad="$bad $(basename "$f"):$ts"
  done
  eq "contrato: timestamp com ms" "${bad:-ok}" "ok"
fi

if runs "contrato: sem N/A em nenhum CSV"; then
  found=$(grep -l 'N/A' "$TMP"/*.csv 2>/dev/null | head -1)
  eq "contrato: sem N/A em nenhum CSV" "${found:-nenhum}" "nenhum"
fi

if runs "contrato: backends sem proc recusam"; then
  # Cada um com o seu sysfs falso: sem ele o init falharia por "nenhuma GPU
  # encontrada" antes de chegar na checagem de supports_procs, e o teste
  # passaria a medir outra coisa.
  o1=$(MONITOR_DRM_ROOT="$TMP/sys_amd_moderna/class/drm" run_monitor proc -b amd -d 1 2>&1)
  o2=$(MONITOR_DRM_ROOT="$TMP/sys_intel_moderna/class/drm" run_monitor proc -b intel -d 1 2>&1)
  if [[ "$o1" == *"does not collect per-process VRAM"* && "$o2" == *"does not collect per-process VRAM"* ]]; then
    ok "contrato: backends sem proc recusam"
  else
    no "contrato: backends sem proc recusam" "mensagem inesperada" "amd: $o1
intel: $o2"
  fi
fi

if runs "contrato: backend incompleto e recusado"; then
  cat > "$ROOT/lib/backends/ztest.sh" <<'BE'
ztest_name() { printf 'ZTest'; }
ztest_probe() { return 1; }
BE
  out=$(run_monitor gpu -b ztest -d 1 2>&1)
  rm -f "$ROOT/lib/backends/ztest.sh"
  contains "contrato: backend incompleto e recusado" "$out" "does not implement"
fi

# ===========================================================================
group "argumentos e validacao"
# ===========================================================================

export MOCK_PROFILE=nvidia_moderna

for opt in -i -d -o -g -p -D -S -f -t -b; do
  if runs "arg $opt sem valor nao trava"; then
    out=$(timeout 5 env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
          MONITOR_LANG=en "$MONITOR" "$opt" 2>&1); rc=$?
    if (( rc == 124 )); then
      no "arg $opt sem valor nao trava" "travou (timeout)"
    elif [[ "$out" == *"requires a value"* ]]; then
      ok "arg $opt sem valor nao trava"
    else
      no "arg $opt sem valor nao trava" "mensagem inesperada" "$out"
    fi
  fi
done

out=$(run_monitor -i 0.5 2>&1)
contains "interval fracionario sugere ms" "$out" "use -i 500"

out=$(run_monitor -i 50 2>&1)
contains "interval abaixo do minimo" "$out" "minimum interval is 100ms"

out=$(run_monitor -i abc 2>&1)
contains "interval nao numerico" "$out" "invalid interval"

out=$(run_monitor -p xyz 2>&1)
contains "modo de procs invalido" "$out" "invalid mode for --procs"

out=$(run_monitor disk -D off 2>&1)
contains "subcomando sem coletor" "$out" "nothing to collect"

out=$(run_monitor -d 3 disk 2>&1)
contains "subcomando depois das opcoes" "$out" "must come before"

out=$(run_monitor gpu -f chrome 2>&1)
contains "filtro sem coleta de procs" "$out" "--filter only makes sense"

out=$(run_monitor gpu -b naoexiste 2>&1)
contains "backend inexistente" "$out" "unknown backend"

out=$(run_monitor -d abc 2>&1)
contains "duracao invalida" "$out" "invalid duration: abc"

out=$(run_monitor -g x 2>&1)
contains "indice de GPU nao numerico" "$out" "invalid GPU index: x"

out=$(run_monitor -t -1 2>&1)
contains "top invalido" "$out" "invalid value for --top"

out=$(run_monitor --naoexiste 2>&1)
contains "opcao desconhecida" "$out" "unknown option: --naoexiste"

if runs "--version imprime a versao"; then
  out=$(run_monitor --version 2>&1)
  want="monitor $(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$MONITOR")"
  eq "--version imprime a versao" "$out" "$want"
fi

# O prefixo pid: exige digitos; sem ele, um numero ja e PID e o resto e nome.
out=$(run_monitor proc -f pid:abc 2>&1)
contains "filtro: pid: nao numerico" "$out" "invalid PID in --filter: abc"

out=$(run_monitor proc -f pid: 2>&1)
contains "filtro: pid: vazio" "$out" "empty target in --filter"

out=$(run_monitor proc -f '' 2>&1)
contains "filtro: alvo vazio" "$out" "requires at least one PID or name"

# name: forca nome mesmo para digitos, e "..." (colado da tabela do nvidia-smi)
# casa pelo trecho que sobrou.
if runs "filtro: name: com digitos e nome"; then
  out=$(run_monitor proc -b nvidia -f name:60282 -d 1 -o "$TMP/nv_fname.csv" 2>&1)
  contains "filtro: name: com digitos e nome" "$out" "no process matched"
fi

if runs "filtro: reticencias casam pelo trecho"; then
  run_monitor proc -b nvidia -f '...hrome' -d 1 -q -o "$TMP/nv_fdots.csv" >/dev/null 2>&1
  eq "filtro: reticencias casam pelo trecho" \
     "$(awk -F, 'NR>1 {print $5}' "$TMP/nv_fdots-procs.csv" | sort -u | paste -sd,)" "chrome"
fi

out=$(run_monitor disk -D naoexiste 2>&1)
contains "disco inexistente" "$out" "unknown disk: naoexiste"

out=$(run_monitor disk -D ' , ' 2>&1)
contains "disco: lista so com virgulas" "$out" "no disk selected"

# ===========================================================================
group "falhas de driver"
# ===========================================================================

if runs "driver mudo: erro claro"; then
  out=$(MOCK_FAIL=driver run_monitor gpu -b nvidia -d 1 2>&1)
  contains "driver mudo: erro claro" "$out" "could not talk to the driver"
fi

if runs "indice de GPU invalido"; then
  out=$(run_monitor gpu -b nvidia -g 7 -d 1 2>&1)
  contains "indice de GPU invalido" "$out" "No devices were found"
fi

# ===========================================================================
group "disco"
# ===========================================================================

if [[ -r /proc/diskstats ]]; then
  dcsv="$TMP/dsk-disk.csv"
  out=$(run_monitor disk -d 2 -q -o "$TMP/dsk.csv")
  if runs "disco: gera linhas"; then
    n=$(rows "$dcsv")
    if (( n >= 1 )); then ok "disco: gera linhas"
    else no "disco: gera linhas" "nenhuma linha" "$out"; fi
  fi
  eq "disco: 8 colunas" "$(sed -n 2p "$dcsv" | awk -F, '{print NF}')" "8" "$out"
  if runs "disco: taxas nao negativas"; then
    bad=$(awk -F, 'NR>1 && ($3<0 || $4<0) {print "sim"; exit}' "$dcsv")
    eq "disco: taxas nao negativas" "${bad:-nao}" "nao" "$out"
  fi
else
  skip "disco" "/proc/diskstats indisponivel"
fi

# ===========================================================================
group "cadencia e sinais"
# ===========================================================================

if runs "cadencia: -i 250 em 1s"; then
  export MOCK_SAMPLES=0   # o mock emite ate ser morto
  csv="$TMP/cad.csv"
  run_monitor gpu -b nvidia -i 250 -d 1 -q -o "$csv" >/dev/null 2>&1
  n=$(rows "$csv")
  # ~4 amostras em 1s; a margem absorve o custo de processo em maquina ocupada.
  if (( n >= 3 && n <= 6 )); then ok "cadencia: -i 250 em 1s"
  else no "cadencia: -i 250 em 1s" "esperava 3-6 amostras, veio $n"; fi
fi

# Manda TERM ao monitor em background e espera ele sair. Devolve 0 se saiu em
# 5 s; senao mata com -9 e devolve 1. O $! do chamador vai em $1.
term_and_wait() {
  local p="$1" _
  sleep 2
  kill -TERM "$p" 2>/dev/null
  for _ in $(seq 1 20); do
    kill -0 "$p" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -9 "$p" 2>/dev/null
  return 1
}

# Os FIFOs vao para um TMPDIR so desta execucao: procurar em /tmp contaria os de
# um monitor de verdade rodando na mesma maquina, e o teste falharia sem bug.
if runs "SIGTERM: encerra e preserva dados" || runs "SIGTERM: sem FIFOs orfaos"; then
  export MOCK_SAMPLES=0
  csv="$TMP/sig.csv"; fifodir="$TMP/fifos"
  mkdir -p "$fifodir"
  TMPDIR="$fifodir" PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" MONITOR_LANG=en \
    "$MONITOR" gpu -b nvidia -o "$csv" > "$TMP/sig.out" 2>&1 &
  if ! term_and_wait $!; then r="nao encerrou em 5s"
  elif (( $(rows "$csv") < 1 )); then r="nenhuma linha gravada"
  else r="ok"; fi
  eq "SIGTERM: encerra e preserva dados" "$r" "ok" "$(cat "$TMP/sig.out")"
  eq "SIGTERM: sem FIFOs orfaos" "$(find "$fifodir" -name 'gpumon*' | wc -l)" "0"
fi

# AMD nao tem produtor externo: o awk e a fonte, e o stop() precisa mata-lo.
if runs "SIGTERM: backend sem produtor encerra"; then
  export MOCK_PROFILE=amd_moderna
  export MONITOR_DRM_ROOT="$TMP/sys_amd_moderna/class/drm"
  csv="$TMP/sigamd.csv"
  PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" MONITOR_LANG=en \
    "$MONITOR" gpu -b amd -o "$csv" > "$TMP/sigamd.out" 2>&1 &
  if term_and_wait $!; then ok "SIGTERM: backend sem produtor encerra"
  else no "SIGTERM: backend sem produtor encerra" "travou"; fi
  unset MONITOR_DRM_ROOT
fi

# ===========================================================================
group "i18n"
# ===========================================================================

export MOCK_PROFILE=nvidia_moderna MOCK_SAMPLES=3

if runs "i18n: LANG=en da mensagem em ingles"; then
  out=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
        LC_ALL= LC_MESSAGES= LANG=en_US.UTF-8 "$MONITOR" -i 2>&1)
  contains "i18n: LANG=en da mensagem em ingles" "$out" "requires a value"
fi

if runs "i18n: LANG=pt da mensagem em portugues"; then
  out=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
        LC_ALL= LC_MESSAGES= LANG=pt_BR.UTF-8 "$MONITOR" -i 2>&1)
  contains "i18n: LANG=pt da mensagem em portugues" "$out" "exige um valor"
fi

# pt_PT tambem e portugues: o codigo do pais nao entra na escolha do catalogo.
if runs "i18n: pt_PT usa o catalogo pt"; then
  out=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
        LC_ALL= LC_MESSAGES= LANG=pt_PT "$MONITOR" -i 2>&1)
  contains "i18n: pt_PT usa o catalogo pt" "$out" "exige um valor"
fi

# Idioma sem catalogo cai para ingles, e nao para o portugues de origem.
if runs "i18n: locale sem catalogo cai para ingles"; then
  out=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
        LC_ALL= LC_MESSAGES= LANG=fr_FR.UTF-8 "$MONITOR" -i 2>&1)
  contains "i18n: locale sem catalogo cai para ingles" "$out" "requires a value"
fi

# "C" significa "sem localizacao", o que aqui e ingles.
if runs "i18n: LANG=C da ingles"; then
  out=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
        LC_ALL= LC_MESSAGES= LANG=C "$MONITOR" -i 2>&1)
  contains "i18n: LANG=C da ingles" "$out" "requires a value"
fi

# Precedencia POSIX: LC_ALL manda em LANG.
if runs "i18n: LC_ALL vence LANG"; then
  out=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
        LC_MESSAGES= LC_ALL=pt_BR.UTF-8 LANG=en_US.UTF-8 "$MONITOR" -i 2>&1)
  contains "i18n: LC_ALL vence LANG" "$out" "exige um valor"
fi

# MONITOR_LANG vence tudo - e o que a propria suite usa.
if runs "i18n: MONITOR_LANG vence o locale"; then
  out=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
        MONITOR_LANG=pt LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$MONITOR" -i 2>&1)
  contains "i18n: MONITOR_LANG vence o locale" "$out" "exige um valor"
fi

if runs "i18n: ajuda acompanha o idioma"; then
  o_en=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
         MONITOR_LANG=en "$MONITOR" --help 2>&1 | head -1)
  o_pt=$(env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
         MONITOR_LANG=pt "$MONITOR" --help 2>&1 | head -1)
  if [[ "$o_en" == *"disk and system monitor"* && "$o_pt" == *"disco e sistema"* ]]; then
    ok "i18n: ajuda acompanha o idioma"
  else
    no "i18n: ajuda acompanha o idioma" "cabecalho nao mudou" "en: $o_en
pt: $o_pt"
  fi
fi

# O mais importante do grupo: o CSV e formato de dados, nao texto. Nem o
# cabecalho nem o separador decimal podem mudar com o idioma - senao duas
# coletas da mesma maquina deixariam de ser comparaveis.
if runs "i18n: CSV nao muda com o idioma"; then
  env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" MONITOR_LANG=en \
      "$MONITOR" gpu -b nvidia -d 1 -q -o "$TMP/l_en.csv" >/dev/null 2>&1
  env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" MONITOR_LANG=pt \
      "$MONITOR" gpu -b nvidia -d 1 -q -o "$TMP/l_pt.csv" >/dev/null 2>&1
  h_en=$(head -1 "$TMP/l_en.csv"); h_pt=$(head -1 "$TMP/l_pt.csv")
  v_en=$(field "$TMP/l_en.csv" 9); v_pt=$(field "$TMP/l_pt.csv" 9)
  if [[ "$h_en" == "$h_pt" && "$v_en" == "26.1" && "$v_pt" == "26.1" ]]; then
    ok "i18n: CSV nao muda com o idioma"
  else
    no "i18n: CSV nao muda com o idioma" \
       "cabecalho ou separador decimal divergiu" "en: $v_en / pt: $v_pt"
  fi
fi

# Uma chave inexistente tem de aparecer, nao sumir.
if runs "i18n: chave desconhecida fica visivel"; then
  out=$(cd "$ROOT" && bash -c '
    LIB_DIR=lib; . lib/i18n.sh; i18n_init; msg chave_que_nao_existe')
  eq "i18n: chave desconhecida fica visivel" "$out" "<chave_que_nao_existe>"
fi

# ===========================================================================
group "CSV: append e cabecalho"
# ===========================================================================

export MOCK_PROFILE=nvidia_moderna MOCK_SAMPLES=3

if runs "append: nao repete cabecalho"; then
  csv="$TMP/app.csv"
  run_monitor gpu -b nvidia -d 1 -q -o "$csv" >/dev/null 2>&1
  run_monitor gpu -b nvidia -d 1 -q -o "$csv" >/dev/null 2>&1
  eq "append: nao repete cabecalho" "$(grep -c '^timestamp' "$csv")" "1"
fi

if runs "output sem .csv: sufixos corretos"; then
  run_monitor -b nvidia -p off -d 1 -q -o "$TMP/noext" >/dev/null 2>&1
  if [[ -f "$TMP/noext" && -f "$TMP/noext-disk.csv" ]]; then
    ok "output sem .csv: sufixos corretos"
  else
    no "output sem .csv: sufixos corretos" "arquivos esperados nao existem"
  fi
fi

# ===========================================================================
group "sistema e threads"
# ===========================================================================

# Um /proc falso com contadores fixos. O uptime e um link para o real: o laco
# do coletor cadencia e encerra pelo relogio, e com um uptime parado ele nunca
# terminaria a duracao. Com os contadores parados, so a
# thread em D-state entra no CSV de threads - que e o que se quer conferir.
# Sem nenhum tick decorrido, o uso de CPU nao foi medido: celula vazia.
fakeproc="$TMP/proc"
mkdir -p "$fakeproc/pressure" "$fakeproc/4242/task/4242" "$fakeproc/4242/task/4243" \
         "$fakeproc/4242/task/4244"
ln -s /proc/uptime "$fakeproc/uptime"
printf 'cpu  100 0 50 800 10 0 0 0 0 0\ncpu0 50 0 25 400 5 0 0 0 0 0\ncpu1 50 0 25 400 5 0 0 0 0 0\n' \
  > "$fakeproc/stat"
printf 'MemTotal:       16384000 kB\nMemFree:         1000000 kB\nMemAvailable:    8192000 kB\nSwapTotal:       2048000 kB\nSwapFree:        1024000 kB\n' \
  > "$fakeproc/meminfo"
for r in cpu memory io; do
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' \
    > "$fakeproc/pressure/$r"
done
# O stat de processo: comm entre parenteses, depois estado e o resto. O comm
# com espaco e ")" e o caso que um split ingenuo por espaco quebraria.
# Os campos vao ate o 39 (processor, o ultimo nucleo), que e 3 no mock.
pstat() {
  printf '%s (%s) %s 1 1 1 0 -1 0 0 0 %s 0 %s %s 0 0 20 0 3 0 %s 3 0\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
}
pstat 4242 dota S 7 500 100 > "$fakeproc/4242/stat"
pstat 4242 dota S 0 300 50  > "$fakeproc/4242/task/4242/stat"
pstat 4243 'Render (main) 1' D 0 200 50 > "$fakeproc/4242/task/4243/stat"
pstat 4244 idle S 0 0 0 > "$fakeproc/4242/task/4244/stat"
echo poll_schedule_timeout > "$fakeproc/4242/task/4242/wchan"
echo nv_wait_for_gpu > "$fakeproc/4242/task/4243/wchan"
echo futex_do_wait > "$fakeproc/4242/task/4244/wchan"
printf 'Name:\tRender\nCpus_allowed_list:\t0,2-3\n' > "$fakeproc/4242/task/4243/status"

run_sys() { MONITOR_PROC_ROOT="$fakeproc" run_monitor sys "$@"; }

scsv="$TMP/sy-sys.csv"; tcsv="$TMP/sy-threads.csv"
out=$(run_sys -f pid:4242 -d 1.2 -q -o "$TMP/sy.csv")
eq "sys: 16 colunas"           "$(sed -n 2p "$scsv" | awk -F, '{print NF}')" "16" "$out"
eq "sys: timestamp com ms"     "$(field "$scsv" 1 | grep -cE 'T[0-9:]{8}\.[0-9]{3}$')" "1" "$out"
eq "sys: cpu sem ticks = vazio" "$(field "$scsv" 2)" "" "$out"
eq "sys: memoria usada"        "$(field "$scsv" 6)" "8000" "$out"
eq "sys: memoria disponivel"   "$(field "$scsv" 7)" "8000" "$out"
eq "sys: swap usada"           "$(field "$scsv" 8)" "1000" "$out"
eq "sys: psi parado = 0"       "$(field "$scsv" 9)" "0.0" "$out"
eq "sys: threads do alvo"      "$(field "$scsv" 13)" "3" "$out"
eq "sys: threads em D"         "$(field "$scsv" 15)" "1" "$out"
eq "threads: 11 colunas"       "$(sed -n 2p "$tcsv" | awk -F, '{print NF}')" "11" "$out"
eq "threads: comm com parenteses" "$(field "$tcsv" 4)" "Render (main) 1" "$out"
eq "threads: estado apos o comm"  "$(field "$tcsv" 5)" "D" "$out"
eq "threads: wchan"            "$(field "$tcsv" 7)" "nv_wait_for_gpu" "$out"
eq "threads: ociosa fica fora" "$(grep -c ',idle,' "$tcsv")" "0" "$out"
eq "threads: ultimo nucleo"    "$(field "$tcsv" 10)" "3" "$out"
eq "threads: afinidade sem virgula" "$(field "$tcsv" 11)" "0 2-3" "$out"
# Sem tick nenhum, a divisao usuario/kernel e 0/0 - e nao vazia: a thread em D
# entrou, entao o cpu_pct dela foi medido (0), e as partes dele tambem.
eq "threads: user_pct parado = 0" "$(field "$tcsv" 8)" "0.0" "$out"
eq "threads: sys_pct parado = 0"  "$(field "$tcsv" 9)" "0.0" "$out"

# Uma thread que gasta CPU de verdade no relogio do coletor: o stat dela e
# reescrito a partir do /proc/uptime real, 60% de um nucleo no codigo do
# programa e 20% no kernel. O mv deixa a troca atomica - o coletor nunca le um
# stat pela metade.
mkdir -p "$fakeproc/5151/task/5151"
pstat 5151 Worker R 0 0 0 > "$fakeproc/5151/stat"
cp "$fakeproc/5151/stat" "$fakeproc/5151/task/5151/stat"
busy_writer() {
  local tck up0 up u s
  tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
  up0=$(cut -d' ' -f1 /proc/uptime)
  while :; do
    up=$(cut -d' ' -f1 /proc/uptime)
    read -r u s < <(LC_ALL=C awk -v a="$up0" -v b="$up" -v t="$tck" \
                    'BEGIN { d = (b - a) * t; printf "%d %d\n", d * 0.6, d * 0.2 }')
    pstat 5151 Worker R 0 "$u" "$s" > "$fakeproc/5151/stat.new"
    cp "$fakeproc/5151/stat.new" "$fakeproc/5151/task/5151/stat.new"
    mv "$fakeproc/5151/stat.new" "$fakeproc/5151/stat"
    mv "$fakeproc/5151/task/5151/stat.new" "$fakeproc/5151/task/5151/stat"
    sleep 0.05
  done
}

if runs "threads: user + sys = cpu" || runs "threads: user acima de sys" \
   || runs "threads: cpu da thread medida" || runs "threads: sem status = afinidade vazia"; then
  busy_writer & bw=$!
  out=$(run_sys -f pid:5151 -d 2.2 -q -o "$TMP/su.csv" 2>&1)
  kill "$bw" 2>/dev/null; wait "$bw" 2>/dev/null
  ucsv="$TMP/su-threads.csv"
  # Arredondamento: user e cpu saem com uma casa cada, e sys e a diferenca.
  # LC_ALL=C: num locale pt_BR o mawk leria "58.8" como 58.
  eq "threads: user + sys = cpu" \
     "$(LC_ALL=C awk -F, 'NR>1 { d = $8 + $9 - $6; if (d > 0.15 || d < -0.15) bad = 1 }
                 END { print (NR > 1 && !bad) ? "ok" : "divergiu" }' "$ucsv")" "ok" "$out"
  eq "threads: user acima de sys" \
     "$(LC_ALL=C awk -F, 'NR>1 { u += $8; s += $9 } END { print (u > s * 1.5) ? "ok" : u "/" s }' "$ucsv")" "ok" "$out"
  # 80% de um nucleo, com folga para o jitter do escritor e da maquina.
  eq "threads: cpu da thread medida" \
     "$(LC_ALL=C awk -F, 'NR>1 { c += $6; n++ } END { m = n ? c / n : 0; print (m >= 50 && m <= 110) ? "ok" : m }' "$ucsv")" \
     "ok" "$out"
  # A Worker nao tem status no /proc falso: celula vazia, e nao a linha crua.
  eq "threads: sem status = afinidade vazia" \
     "$(awk -F, 'NR==2 {print "[" $11 "]"}' "$ucsv")" "[]" "$out"
fi

out=$(MONITOR_THREADS_MIN_PCT=abc run_sys -d 1 2>&1)
contains "sys: MIN_PCT invalido" "$out" "invalid value in MONITOR_THREADS_MIN_PCT: abc"

out=$(MONITOR_THREADS_HOLD_S=-1 run_sys -d 1 2>&1)
contains "sys: HOLD_S invalido" "$out" "invalid value in MONITOR_THREADS_HOLD_S: -1"

out=$(MONITOR_PROC_ROOT="$TMP/naoexiste" run_monitor sys -d 1 2>&1)
contains "sys: /proc ilegivel" "$out" "cannot read $TMP/naoexiste/stat"

if runs "sys: sem pid nao cria threads"; then
  run_sys -d 1 -q -o "$TMP/sn.csv" >/dev/null 2>&1
  if [[ -s "$TMP/sn-sys.csv" && ! -e "$TMP/sn-threads.csv" ]]; then ok "sys: sem pid nao cria threads"
  else no "sys: sem pid nao cria threads" "esperava sn-sys.csv e nenhum sn-threads.csv"; fi
fi

if runs "sys: PID que sumiu deixa celula vazia"; then
  run_sys -f pid:999999 -d 1 -q -o "$TMP/sg.csv" >/dev/null 2>&1
  eq "sys: PID que sumiu deixa celula vazia" "$(field "$TMP/sg-sys.csv" 13)" ""
fi

out=$(run_monitor -S xyz 2>&1)
contains "sys: modo invalido" "$out" "invalid mode for --sys"

out=$(run_monitor sys -S off 2>&1)
contains "sys: subcomando desligado" "$out" "nothing to collect"

if runs "sys: filtro aceito sem procs"; then
  out=$(run_sys -f pid:4242 -d 1 -q -o "$TMP/sf.csv" 2>&1)
  if [[ "$out" != *"only makes sense"* && -s "$TMP/sf-threads.csv" ]]; then ok "sys: filtro aceito sem procs"
  else no "sys: filtro aceito sem procs" "o filtro foi recusado ou nao gerou threads" "$out"; fi
fi

if runs "sys: resumo mostra a thread"; then
  out=$(run_sys -f pid:4242 -d 1.2 -o "$TMP/sr.csv" 2>&1)
  contains "sys: resumo mostra a thread" "$out" "Render (main) 1"
fi

# ===========================================================================
group "perf (-P)"
# ===========================================================================

# O perf dos mocks: grava os argumentos no -o e o sinal que o encerrou. O
# paranoid vem do /proc falso, para o resultado nao depender do sysctl da
# maquina de quem roda a suite.
mkdir -p "$fakeproc/sys/kernel"
echo 1 > "$fakeproc/sys/kernel/perf_event_paranoid"

out=$(run_sys -P -d 1 2>&1)
contains "perf: exige PID" "$out" "--perf needs a target PID"

# Por nome o alvo pode ser varios processos, que nascem e morrem na coleta.
out=$(run_sys -f dota -P -d 1 2>&1)
contains "perf: alvo por nome nao basta" "$out" "--perf needs a target PID"

out=$(MONITOR_PERF_FREQ=abc run_sys -f pid:4242 -P -d 1 2>&1)
contains "perf: frequencia invalida" "$out" "invalid value in MONITOR_PERF_FREQ: abc"

out=$(MONITOR_PERF_FREQ=0 run_sys -f pid:4242 -P -d 1 2>&1)
contains "perf: frequencia zero" "$out" "invalid value in MONITOR_PERF_FREQ: 0"

if runs "perf: paranoid alto recusa"; then
  if (( EUID == 0 )); then
    skip "perf: paranoid alto recusa" "root ignora o paranoid"
  else
    echo 4 > "$fakeproc/sys/kernel/perf_event_paranoid"
    out=$(run_sys -f pid:4242 -P -d 1 2>&1)
    echo 1 > "$fakeproc/sys/kernel/perf_event_paranoid"
    contains "perf: paranoid alto recusa" "$out" "perf_event_paranoid=4"
  fi
fi

# Um PATH com tudo do sistema menos o perf: e o que a maquina sem
# linux-tools ve.
if runs "perf: sem perf instalado"; then
  mkdir -p "$TMP/noperf"
  for d in /usr/local/bin /usr/bin /bin; do
    [[ -d "$d" ]] && ln -s "$d"/* "$TMP/noperf/" 2>/dev/null
  done
  rm -f "$TMP/noperf"/perf "$TMP/noperf"/perf_*
  out=$(PATH="$TMP/noperf" MONITOR_PROC_ROOT="$fakeproc" MONITOR_LOG_DIR="$TMP/logs" \
        MONITOR_LANG=en "$MONITOR" sys -f pid:4242 -P -d 1 2>&1)
  contains "perf: sem perf instalado" "$out" "perf not found"
fi

pbase="$TMP/pf"
out=$(run_sys -f pid:4242,5151 -P -d 1.2 -o "$pbase.csv" 2>&1)
pdata=$(cat "$pbase-perf.data" 2>/dev/null)
contains "perf: record em todos os PIDs" "$pdata" "-p 4242,5151"
contains "perf: frequencia padrao 49"    "$pdata" "-F 49"
contains "perf: relogio monotonico"      "$pdata" "-k CLOCK_MONOTONIC"
contains "perf: grava no -o derivado"    "$pdata" "-o $pbase-perf.data"
# O perf real so fecha o perf.data direito com SIGINT; o timeout do -d manda
# esse sinal, e nao o TERM padrao.
contains "perf: -d encerra com INT"      "$pdata" "stopped: INT"
eq "perf: .clock com o par de relogios" \
   "$(grep -cE '^(realtime|monotonic)=[0-9]+\.[0-9]+$' "$pbase-perf.clock" 2>/dev/null)" "2" "$out"
eq "perf: .clock diz a fonte" \
   "$(grep -cE '^source=(python3|uptime)$' "$pbase-perf.clock" 2>/dev/null)" "1" "$out"
contains "perf: banner mostra o arquivo" "$out" "perf in: $pbase-perf.data (49 Hz)"
contains "perf: rodape mostra o arquivo" "$out" "perf: $pbase-perf.data"

if runs "perf: MONITOR_PERF_FREQ chega ao record"; then
  MONITOR_PERF_FREQ=99 run_sys -f pid:4242 -P -d 1 -q -o "$TMP/pq.csv" >/dev/null 2>&1
  contains "perf: MONITOR_PERF_FREQ chega ao record" "$(cat "$TMP/pq-perf.data" 2>/dev/null)" "-F 99"
fi

# O filtro so com -P: nem proc nem sys ligados, e mesmo assim ele tem uso.
if runs "perf: filtro aceito so com -P"; then
  out=$(MONITOR_PROC_ROOT="$fakeproc" run_monitor gpu -b nvidia -f pid:4242 -P -d 1 -q \
        -o "$TMP/pg.csv" 2>&1)
  if [[ "$out" != *"only makes sense"* && -s "$TMP/pg-perf.data" ]]; then ok "perf: filtro aceito so com -P"
  else no "perf: filtro aceito so com -P" "o filtro foi recusado ou o perf nao rodou" "$out"; fi
fi

# Sem -d, quem encerra o perf e o stop() do monitor - com INT tambem.
if runs "perf: SIGTERM encerra o perf com INT"; then
  MONITOR_PROC_ROOT="$fakeproc" PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
    MONITOR_LANG=en "$MONITOR" sys -f pid:4242 -P -o "$TMP/pt.csv" > "$TMP/pt.out" 2>&1 &
  if ! term_and_wait $!; then r="o monitor nao encerrou em 5s"
  elif pgrep -f "$TMP/pt-perf.data" >/dev/null; then r="o perf ficou vivo"
  else r=$(tail -1 "$TMP/pt-perf.data" 2>/dev/null); fi
  pkill -f "$TMP/pt-perf.data" 2>/dev/null
  eq "perf: SIGTERM encerra o perf com INT" "$r" "stopped: INT" "$(cat "$TMP/pt.out")"
fi

# ===========================================================================
group "tools/perf-window.sh"
# ===========================================================================

# Um .clock com a coleta comecando as 14:10:00 locais e o monotonico em 1000:
# a janela 14:10:24-14:10:26 tem de virar 1024-1026 no relogio do perf.
PW="$ROOT/tools/perf-window.sh"
wbase="$TMP/pw"
: > "$wbase-perf.data"
printf 'realtime=%s.000000\nmonotonic=1000.000000\nsource=python3\n' \
  "$(date -d '2026-09-29 14:10:00' +%s)" > "$wbase-perf.clock"

# Saida no formato do "perf script -F comm,tid,time,ip,sym,dso" com -g: o
# cabecalho da amostra na coluna 0, os quadros indentados por tab, do mais
# interno para o mais externo; quadros do kernel sem simbolo (kptr_restrict).
{
  printf 'GlobPool  4250 1024.100000: \n'
  printf '\t    7f00aa001234 spin_wait+0x12 (/opt/game/libengine.so)\n'
  printf '\t    7f00aa005678 job_run+0x40 (/opt/game/libengine.so)\n\n'
  printf 'GlobPool  4250 1024.200000: \n'
  printf '\tffffffffa8ef695c [unknown] ([unknown])\n'
  printf '\t    7f1b7e2f7f0b __sched_yield+0xb (/usr/lib/x86_64-linux-gnu/libc.so.6)\n'
  printf '\t    7f00aa001234 spin_wait+0x12 (/opt/game/libengine.so)\n\n'
  printf 'GlobPool  4251 1024.300000: \n'
  printf '\t    7f00aa001234 spin_wait+0x12 (/opt/game/libengine.so)\n\n'
  printf 'Render Thread  4260 1024.400000: \n'
  printf '\t    7f00bb000100 si_flush+0x20 (/usr/lib/x86_64-linux-gnu/dri/radeonsi_dri.so)\n\n'
  printf 'Render Thread  4260 1024.500000: \n'
  printf '\tffffffffa8ef695c [unknown] ([unknown])\n'
  printf '\tffffffffa9162344 [unknown] ([unknown])\n\n'
} > "$TMP/perf-script.txt"

run_pw() {
  PATH="$MOCK_DIR/bin:$PATH" MOCK_PERF_SCRIPT="$TMP/perf-script.txt" \
    MOCK_PERF_LOG="$TMP/perf-script.args" "$PW" "$@" 2>&1
}

out=$(run_pw "$wbase" 14:10:24 14:10:26 GlobPool)
contains "perf-window: janela no relogio do perf" "$(cat "$TMP/perf-script.args" 2>/dev/null)" \
         "--time 1024.000000,1026.000000"
contains "perf-window: filtra pela thread"      "$out" "3 amostras"
contains "perf-window: biblioteca da amostra"   "$out" "66.7%       2  libengine.so"
contains "perf-window: kernel vira biblioteca"  "$out" "33.3%       1  kernel"
contains "perf-window: primeiro quadro fora do kernel" "$out" "libc.so.6: __sched_yield"

out=$(run_pw "$wbase" 14:10:24 14:10:26)
contains "perf-window: sem filtro conta tudo"   "$out" "5 amostras"
contains "perf-window: comm com espaco"         "$out" "40.0%       2  Render Thread"
contains "perf-window: amostra so no kernel"    "$out" "(so kernel)"

out=$(run_pw "$wbase.csv" 14:10:24 14:10:26 GlobPool)
contains "perf-window: aceita o caminho com .csv" "$out" "3 amostras"

out=$(run_pw "$wbase-perf.data" 14:10:24 14:10:26 GlobPool)
contains "perf-window: aceita o proprio perf.data" "$out" "3 amostras"

# Data explicita, para uma coleta que vira a meia-noite.
if runs "perf-window: aceita data e hora"; then
  run_pw "$wbase" '2026-09-29 14:10:24' '2026-09-29 14:10:26' >/dev/null
  contains "perf-window: aceita data e hora" "$(cat "$TMP/perf-script.args" 2>/dev/null)" \
           "--time 1024.000000,1026.000000"
fi

if runs "perf-window: thread sem amostras"; then
  out=$(run_pw "$wbase" 14:10:24 14:10:26 naoexiste); rc=$?
  eq "perf-window: thread sem amostras" "$rc:${out%%$'\n'*}" \
     '1:nenhuma amostra nessa janela para "naoexiste"'
fi

if runs "perf-window: horario invalido para"; then
  : > "$TMP/perf-script.args"
  out=$(run_pw "$wbase" 25:99 14:10:26); rc=$?
  # Tem de parar antes de chamar o perf, e nao seguir com uma janela vazia.
  eq "perf-window: horario invalido para" \
     "$rc:$(grep -c 'horario invalido' <<< "$out"):$(wc -c < "$TMP/perf-script.args")" "1:1:0"
fi

out=$(run_pw "$TMP/naoexiste" 14:10:24 14:10:26)
contains "perf-window: sem perf.data" "$out" "nao achei $TMP/naoexiste-perf.data"

if runs "perf-window: sem .clock"; then
  : > "$TMP/pw2-perf.data"
  out=$(run_pw "$TMP/pw2" 14:10:24 14:10:26)
  contains "perf-window: sem .clock" "$out" "nao achei $TMP/pw2-perf.clock"
fi

out=$(run_pw "$wbase" 14:10:24)
contains "perf-window: poucos argumentos" "$out" "uso: perf-window.sh"

# ===========================================================================
# resultado
# ===========================================================================

printf '\n'
printf '\033[1m%d ok, %d falha(s), %d pulado(s)\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL )); then
  printf '\nfalharam:\n'
  printf '  %s\n' "${FAILED_NAMES[@]}"
  (( VERBOSE )) || printf '\nrode com -v para ver a saida de cada falha.\n'
  exit 1
fi
exit 0
