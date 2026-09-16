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
#
# As mensagens deste arquivo ficam em ingles literal, sem passar pelo catalogo
# de lib/i18n/: o instalador roda ANTES de existir instalacao, e faze-lo
# carregar o catalogo significaria dar bootstrap num lib/ que ainda pode nem
# estar no lugar. Para ~30 mensagens, nao se paga. O monitor em si e traduzido.

set -uo pipefail

SRC_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
NAME="monitor"

PREFIX=""
MODE="copy"      # copy | link
ACTION="install" # install | uninstall
FORCE=0

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

usage() {
  cat <<EOF
install.sh - install $NAME as a system command

Usage: ${0##*/} [options]

  --system          Install into /usr/local (all users; needs root)
  --user            Install into ~/.local (default; no root needed)
  --prefix DIR      Install into a specific prefix
  --link            Point at this directory instead of copying (development)
  --uninstall       Remove the installation
  --force           Overwrite an existing target without asking
  -h, --help        Show this help

Where things go:
  <prefix>/bin/$NAME          the command
  <prefix>/lib/$NAME/         monitor.sh and lib/

The CSVs go to \$HOME/.monitor/log of whoever runs the command, and are
untouched by installing or removing.
EOF
}

# --- argumentos ------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)    PREFIX="/usr/local"; shift ;;
    --user)      PREFIX="$HOME/.local"; shift ;;
    --prefix)    [[ $# -ge 2 ]] || die "option $1 requires a value"
                 PREFIX="$2"; shift 2 ;;
    --link)      MODE="link"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown option: $1 (use --help)" ;;
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
    rm -f "$CMD" || die "could not remove $CMD"
    info "removed: $CMD"; removed=1
  fi
  if [[ -d "$LIB_DEST" ]]; then
    rm -rf "$LIB_DEST" || die "could not remove $LIB_DEST"
    info "removed: $LIB_DEST"; removed=1
  fi
  (( removed )) || info "nothing to remove in $PREFIX"
  info ""
  info "the CSVs in \$HOME/.monitor/log were kept."
  exit 0
fi

# --- verificacoes ----------------------------------------------------------

[[ -r "$SRC_DIR/monitor.sh" ]] || die "could not find monitor.sh in $SRC_DIR"
[[ -d "$SRC_DIR/lib" ]] || die "could not find lib/ in $SRC_DIR"

# Um bash muito antigo nao tem mapfile, usado na descoberta de discos.
if (( BASH_VERSINFO[0] < 4 )); then
  die "monitor needs bash 4.0+ (this is ${BASH_VERSION})"
fi

# Sintaxe conferida antes de instalar: melhor falhar agora do que deixar um
# comando quebrado no PATH.
for f in "$SRC_DIR/monitor.sh" "$SRC_DIR"/lib/*.sh "$SRC_DIR"/lib/backends/*.sh \
         "$SRC_DIR"/lib/i18n/*.sh; do
  bash -n "$f" 2>/dev/null || die "syntax error in $f - install aborted"
done

mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR (need sudo?)"
[[ -w "$BIN_DIR" ]] || die "no write permission in $BIN_DIR (try sudo ./install.sh --system)"

if [[ -e "$CMD" ]] && (( ! FORCE )); then
  # Reinstalar por cima da propria instalacao e o caso comum (atualizar), entao
  # so pergunta quando o destino e algo que este script nao reconhece.
  if ! grep -q "MONITOR_LIB_DIR" "$CMD" 2>/dev/null; then
    die "$CMD already exists and does not look like monitor's - use --force to overwrite"
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
  mkdir -p "$LIB_DEST" || die "could not create $LIB_DEST (need sudo?)"
  [[ -w "$LIB_DEST" ]] || die "no write permission in $LIB_DEST"

  # rm antes de copiar: sem isso, um backend removido de uma versao para outra
  # ficaria para tras no destino e a autodeteccao continuaria enxergando ele.
  rm -rf "${LIB_DEST:?}/lib" "${LIB_DEST:?}/monitor.sh"
  cp -R "$SRC_DIR/lib" "$LIB_DEST/lib" || die "could not copy lib/"
  cp "$SRC_DIR/monitor.sh" "$LIB_DEST/monitor.sh" || die "could not copy monitor.sh"
  chmod 0755 "$LIB_DEST/monitor.sh"

  TARGET_LIB="$LIB_DEST/lib"
  TARGET_MAIN="$LIB_DEST/monitor.sh"
fi

# O lancador: fixa onde esta o lib/ e repassa os argumentos. "exec" para o
# monitor herdar o PID, e nao ficar um bash extra no meio - o que importa para
# o Ctrl+C chegar em quem esta coletando.
cat > "$CMD" <<LAUNCHER || die "could not write $CMD"
#!/usr/bin/env bash
# gerado por install.sh - nao edite; reinstale para atualizar
export MONITOR_LIB_DIR="$TARGET_LIB"
exec "$TARGET_MAIN" "\$@"
LAUNCHER
chmod 0755 "$CMD" || die "could not make $CMD executable"

# --- resultado -------------------------------------------------------------

info "installed: $CMD"
if [[ "$MODE" == link ]]; then
  info "           (--link mode: uses $SRC_DIR directly)"
else
  info "           libraries in $LIB_DEST"
fi
info ""

# Um comando fora do PATH e instalado mas inutil: avisa com a linha exata para
# corrigir, em vez de deixar a pessoa descobrir sozinha.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    info "warning: $BIN_DIR is not in your PATH."
    info "  add to ~/.bashrc (or ~/.zshrc):"
    info "    export PATH=\"$BIN_DIR:\$PATH\""
    info ""
    ;;
esac

info "logs in: \$HOME/.monitor/log  (override with MONITOR_LOG_DIR)"
info ""
info "test with:  $NAME --version"
