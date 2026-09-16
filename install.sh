#!/usr/bin/env bash
#
# install.sh - instala (ou remove) o monitor como comando do sistema.
#
# O executavel e as bibliotecas vao para lugares separados, como manda o FHS:
# o comando em <prefixo>/bin/monitor, o lib/ em <prefixo>/lib/monitor/. O
# comando instalado e um lancador de tres linhas que aponta MONITOR_LIB_DIR
# para o lib/ instalado e chama o monitor.sh de la.
#
# Copia, nao cria symlink para o diretorio de desenvolvimento: assim mover ou
# apagar a pasta do projeto nao quebra o comando instalado. Para trabalhar no
# codigo e ver o efeito na hora, use --link.
#
#   ./install.sh                # instala para o usuario (~/.local)
#   sudo ./install.sh --system  # instala para todos (/usr/local)
#   ./install.sh --link         # aponta para este diretorio (desenvolvimento)
#   ./install.sh --uninstall    # remove
#
# Os CSVs nao ficam aqui: vao para ~/.monitor/log de quem roda o comando.

set -uo pipefail

SRC_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
NAME="monitor"

PREFIX=""
MODE="copy"      # copy | link
ACTION="install" # install | uninstall
FORCE=0

die() { printf 'erro: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

usage() {
  cat <<EOF
install.sh - instala o $NAME como comando do sistema

Uso: ${0##*/} [opcoes]

  --system          Instala em /usr/local (todos os usuarios; precisa de root)
  --user            Instala em ~/.local (padrao; nao precisa de root)
  --prefix DIR      Instala num prefixo especifico
  --link            Aponta para este diretorio em vez de copiar (desenvolvimento)
  --uninstall       Remove a instalacao
  --force           Sobrescreve um destino existente sem perguntar
  -h, --help        Mostra esta ajuda

Onde cada coisa vai:
  <prefixo>/bin/$NAME          o comando
  <prefixo>/lib/$NAME/         o monitor.sh e o lib/

Os CSVs vao para \$HOME/.monitor/log de quem executa o comando, e nao sao
tocados pela instalacao nem pela remocao.
EOF
}

# --- argumentos ------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)    PREFIX="/usr/local"; shift ;;
    --user)      PREFIX="$HOME/.local"; shift ;;
    --prefix)    [[ $# -ge 2 ]] || die "a opcao $1 exige um valor"
                 PREFIX="$2"; shift 2 ;;
    --link)      MODE="link"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "opcao desconhecida: $1 (use --help)" ;;
  esac
done

# Sem --system/--user/--prefix, escolhe pelo que da para escrever: root instala
# para todos, usuario comum instala para si. Evita um sudo desnecessario e, do
# outro lado, evita falhar por permissao quando o root claramente quis o sistema.
if [[ -z "$PREFIX" ]]; then
  if (( EUID == 0 )); then PREFIX="/usr/local"; else PREFIX="$HOME/.local"; fi
fi

BIN_DIR="$PREFIX/bin"
LIB_DEST="$PREFIX/lib/$NAME"
CMD="$BIN_DIR/$NAME"

# --- remocao ---------------------------------------------------------------

if [[ "$ACTION" == uninstall ]]; then
  removed=0
  if [[ -e "$CMD" ]]; then
    rm -f "$CMD" || die "nao consegui remover $CMD"
    info "removido: $CMD"; removed=1
  fi
  if [[ -d "$LIB_DEST" ]]; then
    rm -rf "$LIB_DEST" || die "nao consegui remover $LIB_DEST"
    info "removido: $LIB_DEST"; removed=1
  fi
  (( removed )) || info "nada a remover em $PREFIX"
  info ""
  info "os CSVs em \$HOME/.monitor/log foram mantidos."
  exit 0
fi

# --- verificacoes ----------------------------------------------------------

[[ -r "$SRC_DIR/monitor.sh" ]] || die "nao achei o monitor.sh em $SRC_DIR"
[[ -d "$SRC_DIR/lib" ]] || die "nao achei o lib/ em $SRC_DIR"

# Um bash muito antigo nao tem mapfile, usado na descoberta de discos.
if (( BASH_VERSINFO[0] < 4 )); then
  die "o monitor precisa de bash 4.0+ (aqui e ${BASH_VERSION})"
fi

# Sintaxe conferida antes de instalar: melhor falhar agora do que deixar um
# comando quebrado no PATH.
for f in "$SRC_DIR/monitor.sh" "$SRC_DIR"/lib/*.sh "$SRC_DIR"/lib/backends/*.sh; do
  bash -n "$f" 2>/dev/null || die "erro de sintaxe em $f - instalacao abortada"
done

mkdir -p "$BIN_DIR" || die "nao consegui criar $BIN_DIR (falta sudo?)"
[[ -w "$BIN_DIR" ]] || die "sem permissao de escrita em $BIN_DIR (tente sudo ./install.sh --system)"

if [[ -e "$CMD" ]] && (( ! FORCE )); then
  # Reinstalar por cima da propria instalacao e o caso comum (atualizar), entao
  # so pergunta quando o destino e algo que este script nao reconhece.
  if ! grep -q "MONITOR_LIB_DIR" "$CMD" 2>/dev/null; then
    die "$CMD ja existe e nao parece ser do monitor - use --force para sobrescrever"
  fi
fi

# --- instalacao ------------------------------------------------------------

if [[ "$MODE" == link ]]; then
  # Modo desenvolvimento: o comando aponta para esta arvore, entao editar o
  # codigo aqui muda o comportamento do comando instalado na hora.
  TARGET_LIB="$SRC_DIR/lib"
  TARGET_MAIN="$SRC_DIR/monitor.sh"
  rm -rf "$LIB_DEST" 2>/dev/null
else
  mkdir -p "$LIB_DEST" || die "nao consegui criar $LIB_DEST (falta sudo?)"
  [[ -w "$LIB_DEST" ]] || die "sem permissao de escrita em $LIB_DEST"

  # rm antes de copiar: sem isso, um backend removido de uma versao para outra
  # ficaria para tras no destino e a autodeteccao continuaria enxergando ele.
  rm -rf "${LIB_DEST:?}/lib" "${LIB_DEST:?}/monitor.sh"
  cp -R "$SRC_DIR/lib" "$LIB_DEST/lib" || die "nao consegui copiar o lib/"
  cp "$SRC_DIR/monitor.sh" "$LIB_DEST/monitor.sh" || die "nao consegui copiar o monitor.sh"
  chmod 0755 "$LIB_DEST/monitor.sh"

  TARGET_LIB="$LIB_DEST/lib"
  TARGET_MAIN="$LIB_DEST/monitor.sh"
fi

# O lancador: fixa onde esta o lib/ e repassa os argumentos. "exec" para o
# monitor herdar o PID, e nao ficar um bash extra no meio - o que importa para
# o Ctrl+C chegar em quem esta coletando.
cat > "$CMD" <<LAUNCHER || die "nao consegui escrever $CMD"
#!/usr/bin/env bash
# gerado por install.sh - nao edite; reinstale para atualizar
export MONITOR_LIB_DIR="$TARGET_LIB"
exec "$TARGET_MAIN" "\$@"
LAUNCHER
chmod 0755 "$CMD" || die "nao consegui tornar $CMD executavel"

# --- resultado -------------------------------------------------------------

info "instalado: $CMD"
if [[ "$MODE" == link ]]; then
  info "           (modo --link: usa $SRC_DIR diretamente)"
else
  info "           bibliotecas em $LIB_DEST"
fi
info ""

# Um comando fora do PATH e instalado mas inutil: avisa com a linha exata para
# corrigir, em vez de deixar a pessoa descobrir sozinha.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    info "atencao: $BIN_DIR nao esta no seu PATH."
    info "  adicione ao ~/.bashrc (ou ~/.zshrc):"
    info "    export PATH=\"$BIN_DIR:\$PATH\""
    info ""
    ;;
esac

info "logs em: \$HOME/.monitor/log  (sobrepoe com MONITOR_LOG_DIR)"
info ""
info "teste com:  $NAME --version"
