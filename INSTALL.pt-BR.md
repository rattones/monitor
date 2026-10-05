# Instalando o monitor

[English](INSTALL.md) · [Português](INSTALL.pt-BR.md)

## Começando

```bash
git clone https://github.com/rattones/monitor.git
cd monitor
./install.sh
```

Isso instala em `~/.local` — sem root. Depois:

```bash
monitor --version
monitor -d 10
```

Se o comando não for encontrado, `~/.local/bin` não está no seu `PATH`. O
instalador avisa e imprime a linha exata para adicionar ao seu `~/.bashrc` ou
`~/.zshrc`.

## Sem instalar

O script roda direto do clone. Nada precisa ser instalado:

```bash
./monitor.sh -d 10
```

## Modos de instalação

| Comando | Onde vai | Root? |
|---|---|---|
| `./install.sh` | `~/.local` | não |
| `sudo ./install.sh --system` | `/usr/local` (todos os usuários) | sim |
| `./install.sh --prefix DIR` | `DIR` | depende de `DIR` |
| `./install.sh --link` | aponta para o clone (desenvolvimento) | não |

Sem nenhuma opção, o prefixo segue quem está executando: root instala para
todos, usuário comum instala para si. Isso evita tanto um `sudo` desnecessário
quanto uma falha de permissão quando o root claramente quis o sistema todo.

**`--link` é para desenvolvimento.** O comando instalado aponta para a sua árvore
de trabalho, então editar o código muda o comportamento do comando na hora.
Todos os outros modos **copiam**, então mover ou apagar o clone depois não
quebra nada.

## O que é instalado

```
<prefixo>/bin/monitor          o comando (um lançador de 3 linhas)
<prefixo>/bin/freeze-probe     a sonda de travadas (lançador de 3 linhas; roda com sudo)
<prefixo>/lib/monitor/         o monitor.sh, o lib/ e o probe/
```

O `freeze-probe` é instalado junto com o monitor, mas estar instalado não dá
privilégio nenhum: ele só roda quando você o chama com `sudo`, quando achar
necessário. Serve para qualquer programa: escolha o alvo com `-n NOME`,
`-f PADRÃO` (um trecho da linha de comando) ou `-p PID`. Precisa do `bpftrace`
(`sudo apt install bpftrace`) e de kernel com BTF; o monitor não precisa. O
sudo procura comandos no `secure_path` dele, não no seu `PATH`: instalado em
`~/.local`, rode `sudo ~/.local/bin/freeze-probe -n NOME`; com `--system`,
`sudo freeze-probe -n NOME` funciona direto. O instalador mostra a linha certa.
Ver [probe/README.pt-BR.md](probe/README.pt-BR.md).

O comando em `bin/` é um lançador que aponta `MONITOR_LIB_DIR` para o `lib/`
instalado e faz `exec` no script real. O `exec` importa: sem ele sobraria um
shell extra entre o seu terminal e o coletor, e o Ctrl+C não chegaria em quem
está coletando.

O instalador confere a sintaxe de todos os arquivos antes de copiar, então um
arquivo quebrado faz a instalação falhar em vez de deixar um comando quebrado no
seu `PATH`.

## Requisitos

| O quê | Por quê |
|---|---|
| **Linux** | lê `/proc/diskstats`, `/sys/block`, `/sys/class/drm` |
| **bash 4.0+** | `mapfile`, usado na descoberta de discos |
| `awk` | mawk, gawk ou busybox awk — nenhuma extensão GNU é usada |
| coreutils | `timeout`, `mktemp`, `mkfifo`, `readlink`, `date`, `sleep` |

Para as métricas de GPU você também precisa, conforme o fabricante:

| Fabricante | Precisa de | Observações |
|---|---|---|
| NVIDIA | `nvidia-smi` (pacote `nvidia-utils-*`) | suporte completo |
| AMD | nada — lê sysfs | sem VRAM por processo |
| Intel | nada — lê sysfs | **não testado em hardware real** |

O subcomando `disk` não precisa de nada disso e roda numa máquina sem GPU
nenhuma.

## Desinstalando

```bash
./install.sh --uninstall               # de ~/.local
sudo ./install.sh --uninstall --system # de /usr/local
```

Os dois comandos, `monitor` e `freeze-probe`, são removidos. Um `freeze-probe`
que não foi instalado por este script fica onde está.

**Seus CSVs são mantidos.** Eles ficam em `~/.monitor/log`, fora de qualquer
coisa que o instalador toque. Apague você mesmo, se quiser.

## Onde os dados ficam

Os CSVs vão para `~/.monitor/log/` por padrão — na sua home, e não ao lado do
script, para o comando instalado nunca tentar escrever num diretório do sistema
e para cada usuário ter os próprios.

```bash
MONITOR_LOG_DIR=/dados/metricas monitor -d 60   # outro lugar
monitor -o /tmp/run.csv -d 60                   # um arquivo específico
```

## Variáveis de ambiente

| Variável | O que faz |
|---|---|
| `MONITOR_LOG_DIR` | onde os CSVs vão (padrão `$HOME/.monitor/log`) |
| `MONITOR_LANG` | força o idioma (`en`, `pt`), ignorando o locale |
| `MONITOR_LIB_DIR` | onde está o `lib/` (definida pelo lançador instalado) |
| `MONITOR_DRM_ROOT` | raiz do sysfs para os backends AMD/Intel (usada pelos testes) |

## Solução de problemas

**`monitor: comando não encontrado` logo após instalar**
`~/.local/bin` não está no seu `PATH`. Adicione a linha que o instalador
imprimiu e abra um shell novo.

**`no GPU recognized` / `nenhuma GPU reconhecida`**
Nenhum backend reconheceu seu hardware. Confira com `lspci | grep -i vga`. Se
você tem uma GPU suportada, force o backend: `monitor gpu -b amd`. Em NVIDIA,
confirme que o driver responde com `nvidia-smi -L`.

**`o backend AMD nao coleta VRAM por processo`**
Esperado: só a NVIDIA reporta VRAM por processo hoje. Use `monitor -p off` para
coletar GPU e disco, ou `monitor gpu` só para a GPU. Veja
[CONTRIBUTING.pt-BR.md](CONTRIBUTING.pt-BR.md) se quiser ajudar a mudar isso.

**`$CMD already exists and does not look like monitor's`**
Já existe outra coisa chamada `monitor` naquele prefixo. Escolha outro prefixo
ou passe `--force` se tiver certeza.

**Uma mensagem aparece como `<alguma_chave>`**
Uma chave de tradução sem entrada. É um bug — por favor
[abra uma issue](https://github.com/rattones/monitor/issues).
