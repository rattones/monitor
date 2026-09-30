#!/usr/bin/env bash
#
# nouveau-sampler.sh - produtor do backend nouveau: o papel do "nvidia-smi -lms".
#
# O nouveau (driver livre da NVIDIA, usado pelo NVK) nao publica VRAM no sysfs,
# e com o firmware GSP (Turing em diante) nem o hwmon existe. O driver sabe a
# VRAM em uso (ioctl GETPARAM), mas shell nao faz ioctl - e quem faz, sem root,
# e o proprio Mesa: o NVK devolve esse numero no VK_EXT_memory_budget. Por isso
# a leitura passa pelo vulkaninfo, do pacote vulkan-tools.
#
# O que o vulkaninfo mostra, por heap DEVICE_LOCAL:
#   size   - VRAM da placa
#   budget - quanto este processo ainda pode alocar, que no NVK e 90% da VRAM
#            livre da placa inteira (medido: budget / (size - usada) = 0,900)
#   usage  - so a VRAM deste processo (zero no vulkaninfo), sem uso aqui
# Dai a estimativa: usada = size - budget / 0,9. E aproximada no nivel de alguns
# MiB e depende dessa regra do Mesa; quem precisar do valor exato do driver tem
# de ler o ioctl fora do shell.
#
# Cada leitura cria um dispositivo Vulkan (~0,2 s, ~0,08 s de CPU). Para nao
# disputar a GPU com o que esta sendo medido, a VRAM e lida no maximo a cada
# <minimo_ms>, mesmo que o intervalo pedido seja menor.
#
# Uso: nouveau-sampler.sh <intervalo_ms> <minimo_ms> <indice>...
# Saida, uma linha por placa por leitura:
#   timestamp,indice,vram_total_bytes,vram_usada_bytes
# Placa sem heap legivel sai com os dois campos vazios - nunca zero.
set -uo pipefail
export LC_ALL=C

(( $# >= 3 )) || { echo "uso: ${0##*/} <intervalo_ms> <minimo_ms> <indice>..." >&2; exit 2; }
iv_ms=$1; min_ms=$2; shift 2
(( iv_ms < min_ms )) && iv_ms=$min_ms
want=" $* "

# So o ICD do NVK: sem o llvmpipe e outras GPUs, a lista de placas do
# vulkaninfo e exatamente a das placas no nouveau, na ordem do barramento.
icd=""
for f in /usr/share/vulkan/icd.d/nouveau_icd*.json /etc/vulkan/icd.d/nouveau_icd*.json; do
  [[ -r "$f" ]] && { icd="$f"; break; }
done
[[ -n "$icd" ]] && export VK_DRIVER_FILES="$icd" VK_ICD_FILENAMES="$icd"

# Uma linha "indice size budget" por GPU: o primeiro heap DEVICE_LOCAL de cada
# bloco "GPU<n>:". O size e o budget aparecem antes das flags do heap, entao
# guarda os dois e decide quando a flag chega.
read_heaps() {
  vulkaninfo 2>/dev/null | awk '
    /^GPU[0-9]+:/            { gpu = substr($1, 4) + 0; inmem = 0; next }
    /^VkPhysicalDeviceMemoryProperties/ { inmem = !(gpu in done); next }
    !inmem                   { next }
    /memoryTypes:/           { inmem = 0; next }
    $1 == "size"             { size = $3; next }
    $1 == "budget"           { budget = $3; next }
    /MEMORY_HEAP_DEVICE_LOCAL_BIT/ {
      if (!(gpu in done)) { print gpu, size, budget; done[gpu] = 1 }
    }'
}

# Milissegundos no timestamp, como o nvidia-smi e os outros coletores. O
# EPOCHREALTIME (bash 5) evita um "date" por amostra.
stamp() {
  local now=$EPOCHREALTIME frac
  frac=${now#*[.,]}
  printf '%(%Y-%m-%dT%H:%M:%S)T.%s' "${now%[.,]*}" "${frac:0:3}"
}

usec() { local t=$EPOCHREALTIME; echo $(( ${t%[.,]*} * 1000000 + 10#${t#*[.,]} )); }

target=$(usec)
while :; do
  ts=$(stamp)
  declare -A seen=()
  while read -r idx size budget; do
    [[ "$want" == *" $idx "* ]] || continue
    seen[$idx]=1
    if [[ "$size" =~ ^[0-9]+$ && "$budget" =~ ^[0-9]+$ ]]; then
      used=$(( size - budget * 10 / 9 ))
      (( used < 0 )) && used=0
      printf '%s,%s,%s,%s\n' "$ts" "$idx" "$size" "$used"
    else
      printf '%s,%s,,\n' "$ts" "$idx"
    fi
  done < <(read_heaps)
  # Placa pedida que o vulkaninfo nao listou: linha com a medida ausente.
  for idx in $want; do
    [[ -n "${seen[$idx]:-}" ]] || printf '%s,%s,,\n' "$ts" "$idx"
  done
  unset seen

  target=$(( target + iv_ms * 1000 ))
  wait_us=$(( target - $(usec) ))
  if (( wait_us > 0 )); then
    sleep "$(printf '%d.%06d' $(( wait_us / 1000000 )) $(( wait_us % 1000000 )))"
  else
    target=$(usec)
  fi
done
