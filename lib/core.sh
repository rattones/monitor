# shellcheck shell=bash
#
# core.sh - utilidades comuns a todos os modulos: erro, ciclo de vida dos
# processos filhos e espera por sinal.

# O prefixo vem do catalogo, entao "erro:"/"error:" acompanha o idioma. A
# mensagem vai como argumento do proprio msg(), e nao por um printf externo:
# expandir duas vezes consumiria o %s do prefixo na primeira passada e a
# mensagem sumiria.
die() { msg core_error_prefix "$1" >&2; exit 1; }

# Roda um comando pelo tempo de --duration, ou sem limite quando ela e 0.
#
# O "exec" e essencial: sem ele, chamar esta funcao com "&" deixa o subshell
# bash no lugar, e $! passa a apontar para o subshell em vez do produtor real.
# O stop() mataria a casca, o produtor ficaria orfao segurando o FIFO aberto,
# o awk nunca veria EOF e o script travaria em vez de encerrar no Ctrl+C.
run_source() {
  if LC_ALL=C awk -v d="$DURATION" 'BEGIN { exit !(d > 0) }'; then
    exec timeout "$DURATION" "$@"
  else
    exec "$@"
  fi
}

# Ctrl+C/TERM encerram apenas as fontes de dados: os FIFOs chegam a EOF, os awks
# drenam o que ja foi lido, imprimem o resumo e saem por conta propria. Matar os
# awks aqui truncaria a ultima amostra e perderia a contagem final.
stop() {
  # Um backend com produtor externo (nvidia-smi) fecha pela fonte: o FIFO chega
  # a EOF e o awk sai sozinho depois de drenar. Um backend que le sysfs direto
  # nao tem produtor - o proprio awk e a fonte, e fica sem ninguem para
  # encerra-lo se so olharmos o *_SRC_PID. Nesse caso mata-se o awk, como ja e
  # feito com o disco: cada linha ja foi gravada com flush, nada fica pela metade.
  if [[ -n "$GPU_SRC_PID" ]]; then
    kill "$GPU_SRC_PID" 2>/dev/null
  else
    [[ -n "$GPU_AWK_PID" ]] && kill "$GPU_AWK_PID" 2>/dev/null
  fi

  if [[ -n "$PROC_SRC_PID" ]]; then
    kill "$PROC_SRC_PID" 2>/dev/null
  else
    [[ -n "$PROC_AWK_PID" ]] && kill "$PROC_AWK_PID" 2>/dev/null
  fi

  [[ -n "$DISK_PID" ]] && kill "$DISK_PID" 2>/dev/null
  [[ -n "$SYS_PID" ]]  && kill "$SYS_PID" 2>/dev/null
  return 0
}

cleanup() {
  local p
  for p in "$GPU_SRC_PID" "$PROC_SRC_PID" "$GPU_AWK_PID" "$PROC_AWK_PID" "$DISK_PID" "$SYS_PID"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  local f
  for f in "${FIFOS[@]}"; do
    [[ -n "$f" ]] && rm -f "$f"
  done
  return 0
}

# FIFOs criados pelos backends, removidos no cleanup.
FIFOS=()

# Cria um FIFO e o registra para limpeza, devolvendo o caminho em FIFO_PATH.
#
# Devolve por variavel, e nao por stdout, de proposito: chamar via $(...) poria
# a funcao num subshell, e o FIFOS+=() morreria junto com ele - o cleanup nao
# teria o que remover e cada execucao deixaria FIFOs para tras em /tmp.
FIFO_PATH=""
make_fifo() {
  local prefix="${1:-gpumon}"
  FIFO_PATH=$(mktemp -u -t "$prefix.XXXXXXXX") || die "$(msg core_fifo_name)"
  mkfifo "$FIFO_PATH" || die "$(msg core_fifo_create "$FIFO_PATH")"
  FIFOS+=("$FIFO_PATH")
}

# O wait e interrompido pelo sinal, entao reespera ate o filho realmente sair.
wait_for() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  while kill -0 "$pid" 2>/dev/null; do
    wait "$pid" 2>/dev/null
  done
}
