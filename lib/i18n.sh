# shellcheck shell=bash
#
# i18n.sh - catalogo de mensagens e deteccao de idioma.
#
# As mensagens ficam em lib/i18n/<idioma>.sh, como entradas do array MSG. O
# ingles e o idioma de origem e o fallback: toda chave existe nele, entao um
# catalogo ausente ou incompleto cai para ingles em vez de deixar buracos.
#
# Sobre o LC_ALL=C: a formatacao numerica forcada antes de cada awk nao tem
# relacao com isto. O awk trata o texto das mensagens como bytes opacos, entao
# um catalogo em UTF-8 e um "%.1f" com ponto decimal convivem sem conflito -
# verificado. Nao "conserte" um com o outro.
#
# Uma regra ao escrever catalogos: nunca ponha texto traduzido num campo de
# largura fixa ("%-10s"). Sob LC_ALL=C o padding conta BYTES, nao caracteres,
# entao um acento desalinharia a coluna. Os dois campos assim que existem hoje
# (em report.sh) recebem dados - nome de processo e de disco -, nunca rotulos.

declare -A MSG=()

I18N_DIR="${MONITOR_I18N_DIR:-$LIB_DIR/i18n}"
LANG_CODE="en"

# O idioma vem da primeira variavel de locale definida, na precedencia POSIX:
# LC_ALL manda em tudo, LC_MESSAGES rege especificamente o texto, LANG e o
# padrao. MONITOR_LANG sobrepoe todas - e o que a suite de testes fixa, para as
# assercoes nao dependerem do locale de quem roda.
detect_lang() {
  local raw="${MONITOR_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"

  # "C" e "POSIX" significam "sem localizacao", o que aqui e o ingles - e nao
  # um catalogo faltando.
  case "$raw" in
    ""|C|POSIX|C.*) printf 'en'; return ;;
  esac

  # pt_BR.UTF-8 -> pt ; ca_ES@valencia -> ca
  raw="${raw%%.*}"; raw="${raw%%@*}"; raw="${raw%%_*}"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
}

# Carrega o ingles como base e sobrepoe o idioma detectado por cima, de modo que
# uma traducao parcial mostre o que tem e caia para ingles no resto. Tambem
# significa que uma chave nova adicionada ao en.sh nunca quebra outro idioma.
i18n_init() {
  local want
  want="$(detect_lang)"

  # shellcheck source=/dev/null
  . "$I18N_DIR/en.sh" || {
    printf 'error: cannot load message catalog %s\n' "$I18N_DIR/en.sh" >&2
    exit 1
  }

  if [[ "$want" != en && -r "$I18N_DIR/$want.sh" ]]; then
    # shellcheck source=/dev/null
    . "$I18N_DIR/$want.sh" && LANG_CODE="$want"
  fi
  return 0
}

# msg <chave> [args...] - devolve a mensagem com os %s posicionais expandidos.
#
# Uma chave sem entrada sai como "<chave>" em vez de string vazia: um erro de
# digitacao aparece na tela, feio mas diagnosticavel, em vez de sumir.
msg() {
  local key="$1"; shift
  local fmt="${MSG[$key]:-<$key>}"
  # O "--" e obrigatorio: varias mensagens comecam com "--interval", "--filter"
  # e afins, e sem ele o printf as trataria como opcao propria e falharia.
  # shellcheck disable=SC2059
  printf -- "$fmt" "$@"
}

# Texto da ajuda. E prosa longa com interpolacao ($VERSION, $LOG_DIR), entao
# mora num arquivo por idioma em vez de virar ~90 entradas de array.
usage_text() {
  local f="$I18N_DIR/usage-$LANG_CODE.sh"
  [[ -r "$f" ]] || f="$I18N_DIR/usage-en.sh"
  # shellcheck source=/dev/null
  . "$f"
}
