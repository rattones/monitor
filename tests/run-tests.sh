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
run_monitor() {
  PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" "$MONITOR" "$@" 2>&1
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
contains "filtro sem match: avisa" "$out" "nenhum processo casou"

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
  if [[ "$o1" == *"nao coleta VRAM por processo"* && "$o2" == *"nao coleta VRAM por processo"* ]]; then
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
  contains "contrato: backend incompleto e recusado" "$out" "nao implementa"
fi

# ===========================================================================
group "argumentos e validacao"
# ===========================================================================

export MOCK_PROFILE=nvidia_moderna

for opt in -i -d -o -g -p -D -f -t -b; do
  if runs "arg $opt sem valor nao trava"; then
    out=$(timeout 5 env PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
          "$MONITOR" "$opt" 2>&1); rc=$?
    if (( rc == 124 )); then
      no "arg $opt sem valor nao trava" "travou (timeout)"
    elif [[ "$out" == *"exige um valor"* ]]; then
      ok "arg $opt sem valor nao trava"
    else
      no "arg $opt sem valor nao trava" "mensagem inesperada" "$out"
    fi
  fi
done

out=$(run_monitor -i 0.5 2>&1)
contains "interval fracionario sugere ms" "$out" "use -i 500"

out=$(run_monitor -i 50 2>&1)
contains "interval abaixo do minimo" "$out" "minimo e 100ms"

out=$(run_monitor -i abc 2>&1)
contains "interval nao numerico" "$out" "intervalo invalido"

out=$(run_monitor -p xyz 2>&1)
contains "modo de procs invalido" "$out" "modo invalido para --procs"

out=$(run_monitor disk -D off 2>&1)
contains "subcomando sem coletor" "$out" "nada a coletar"

out=$(run_monitor -d 3 disk 2>&1)
contains "subcomando depois das opcoes" "$out" "deve vir antes"

out=$(run_monitor gpu -f chrome 2>&1)
contains "filtro sem coleta de procs" "$out" "--filter so faz sentido"

out=$(run_monitor gpu -b naoexiste 2>&1)
contains "backend inexistente" "$out" "backend desconhecido"

# ===========================================================================
group "falhas de driver"
# ===========================================================================

if runs "driver mudo: erro claro"; then
  out=$(MOCK_FAIL=driver run_monitor gpu -b nvidia -d 1 2>&1)
  contains "driver mudo: erro claro" "$out" "nao conseguiu falar com o driver"
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

if runs "SIGTERM: encerra e preserva dados"; then
  export MOCK_SAMPLES=0
  csv="$TMP/sig.csv"
  PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
    "$MONITOR" gpu -b nvidia -o "$csv" > "$TMP/sig.out" 2>&1 &
  p=$!
  sleep 2
  kill -TERM "$p" 2>/dev/null
  died=0
  for _ in $(seq 1 20); do
    kill -0 "$p" 2>/dev/null || { died=1; break; }
    sleep 0.25
  done
  if (( ! died )); then
    kill -9 "$p" 2>/dev/null
    no "SIGTERM: encerra e preserva dados" "nao encerrou em 5s"
  elif (( $(rows "$csv") < 1 )); then
    no "SIGTERM: encerra e preserva dados" "nenhuma linha gravada"
  else
    ok "SIGTERM: encerra e preserva dados"
  fi
fi

if runs "SIGTERM: sem FIFOs orfaos"; then
  n=$(find /tmp -maxdepth 1 -name 'gpumon*' -newer "$TMP" 2>/dev/null | wc -l)
  eq "SIGTERM: sem FIFOs orfaos" "$n" "0"
fi

# AMD nao tem produtor externo: o awk e a fonte, e o stop() precisa mata-lo.
if runs "SIGTERM: backend sem produtor encerra"; then
  export MOCK_PROFILE=amd_moderna
  export MONITOR_DRM_ROOT="$TMP/sys_amd_moderna/class/drm"
  csv="$TMP/sigamd.csv"
  PATH="$MOCK_DIR/bin:$PATH" MONITOR_LOG_DIR="$TMP/logs" \
    "$MONITOR" gpu -b amd -o "$csv" > "$TMP/sigamd.out" 2>&1 &
  p=$!
  sleep 2
  kill -TERM "$p" 2>/dev/null
  died=0
  for _ in $(seq 1 20); do
    kill -0 "$p" 2>/dev/null || { died=1; break; }
    sleep 0.25
  done
  if (( died )); then ok "SIGTERM: backend sem produtor encerra"
  else kill -9 "$p" 2>/dev/null; no "SIGTERM: backend sem produtor encerra" "travou"; fi
  unset MONITOR_DRM_ROOT
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
