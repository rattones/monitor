# Contribuindo

[English](CONTRIBUTING.md) · [Português](CONTRIBUTING.pt-BR.md)

## O que mais precisamos: relatos de hardware AMD e Intel

Este projeto tem um problema específico e nada glamoroso: **o backend AMD foi
verificado contra exatamente uma GPU, e o backend Intel nunca rodou em hardware
real.**

Não há GPU Intel na máquina de desenvolvimento. O backend Intel foi escrito a
partir da documentação do kernel e validado contra um sysfs *simulado* — o que
prova que a leitura e a conversão de unidades funcionam, mas não prova nada
sobre se aqueles arquivos existem num i915 ou xe de verdade, nem se as unidades
batem.

Se você tem uma GPU AMD ou Intel, **rodar dois comandos e colar a saída numa
issue é a contribuição mais valiosa que pode fazer.** Leva cerca de um minuto e
não exige saber bash.

### Relato AMD

```bash
./monitor.sh gpu -b amd -d 3
```

Depois os valores crus que ele leu, para conferirmos as conversões:

```bash
for c in /sys/class/drm/card[0-9]*; do
  grep -q '^DRIVER=amdgpu$' "$c/device/uevent" 2>/dev/null || continue
  echo "== $c"
  for f in gpu_busy_percent mem_busy_percent mem_info_vram_total \
           mem_info_vram_used pp_dpm_mclk; do
    printf '%-24s %s\n' "$f" "$(cat "$c/device/$f" 2>/dev/null || echo ABSENT)"
  done
  for h in "$c"/device/hwmon/hwmon*; do
    for f in temp1_input power1_input power1_average freq1_input; do
      printf '%-24s %s\n' "$f" "$(cat "$h/$f" 2>/dev/null || echo ABSENT)"
    done
  done
done
lspci | grep -iE 'vga|3d|display'
```

### Relato Intel

```bash
./monitor.sh gpu -b intel -d 3
```

Ele vai avisar que o backend não foi testado — isso é esperado, e exatamente o
motivo de precisarmos do relato.

```bash
for c in /sys/class/drm/card[0-9]*; do
  grep -qE '^DRIVER=(i915|xe)$' "$c/device/uevent" 2>/dev/null || continue
  echo "== $c"
  for f in gt_cur_freq_mhz gt_act_freq_mhz lmem_total_bytes lmem_avail_bytes; do
    printf '%-24s %s\n' "$f" "$(cat "$c/$f" 2>/dev/null || echo ABSENT)"
  done
  for h in "$c"/device/hwmon/hwmon*; do
    for f in temp1_input power1_input power1_average; do
      printf '%-24s %s\n' "$f" "$(cat "$h/$f" 2>/dev/null || echo ABSENT)"
    done
  done
done
lspci | grep -iE 'vga|3d|display'
```

Também ajuda: `uname -r` (versão do kernel) e sua distribuição.

### O que fazemos com isso

Comparamos cada coluna do CSV com o valor cru do sysfs. Foi assim que o backend
AMD foi corrigido antes de sair — o hardware real expunha `power1_input` onde a
documentação dizia `power1_average`, e só rodando numa placa de verdade isso
apareceu. As linhas `ABSENT` são tão úteis quanto as preenchidas: dizem quais
métricas aquela geração não expõe, para a coluna sair corretamente **vazia** em
vez de zero.

### Por favor, NÃO envie o `-procs.csv`

O CSV de processos lista **os nomes dos programas que você rodou** —
navegadores, jogos, scripts, ferramentas de trabalho. Ele não é necessário para
validar hardware, e uma issue é pública.

Os comandos acima produzem apenas o CSV da GPU. Se você coletou com `all`, envie
só o `monitor-<data>.csv` e deixe o `monitor-<data>-procs.csv` de fora.

O CSV da GPU contém apenas o modelo da placa, métricas e timestamps — nada que
identifique você.

[**Abrir um relato de hardware →**](https://github.com/rattones/monitor/issues/new)

---

## Outras formas de ajudar

### VRAM por processo em AMD e Intel

A maior funcionalidade faltante. A NVIDIA reporta isso via
`nvidia-smi -q -d PIDS`; nem AMD nem Intel têm equivalente, então o
`monitor proc` se recusa a rodar nelas em vez de produzir um CSV vazio.

O caminho viável é o `fdinfo` dos descritores de `/dev/dri/*` — as linhas
`drm-memory-*`, que é como o `nvtop` faz, sem root. Implica varrer
`/proc/*/fdinfo/*` a cada amostra.

Os pontos de partida estão marcados como `TODO` em
[`lib/backends/amd.sh`](lib/backends/amd.sh) e
[`lib/backends/intel.sh`](lib/backends/intel.sh). Quando funcionar,
`<fabricante>_supports_procs` passa a retornar 0 e o subcomando se destrava
sozinho.

### Um backend novo

Um backend é um arquivo em `lib/backends/<nome>.sh` que implementa sete funções.
O contrato está documentado por inteiro no topo de
[`lib/backend.sh`](lib/backend.sh).

O carregador confere o contrato e recusa um arquivo incompleto **listando
exatamente o que falta** — então você descobre na hora de carregar, e não no
meio de uma coleta.

### Um idioma novo

Copie `lib/i18n/en.sh` para `lib/i18n/<código>.sh` e traduza os valores. O
inglês é sempre carregado como camada de base, então dá para traduzir parte e o
resto cai para inglês em vez de deixar buracos.

Uma regra: **sem caracteres acentuados nos catálogos.** Sob `LC_ALL=C` o awk
faz o padding de `%-Ns` por bytes, não por caracteres, então um acento
desalinharia a coluna. O catálogo português segue isso.

O texto de ajuda fica em `lib/i18n/usage-<código>.sh` — prosa, não entradas de
array.

---

## Trabalhando no código

### Testes

```bash
./tests/run-tests.sh          # 106 testes, cerca de um minuto
./tests/run-tests.sh -v amd   # filtra e mostra a saída das falhas
```

A suíte roda o script de verdade contra mocks — um `nvidia-smi` falso e árvores
de sysfs simuladas —, então **dá o mesmo resultado numa máquina sem GPU
nenhuma.** Você não precisa do hardware para rodar os testes.

Cada fabricante é exercitado em duas gerações, moderna e antiga. A antiga é a
que mais importa: é onde faltam métricas, e onde o contrato *"métrica que o
hardware não reporta vira célula vazia, nunca zero"* ou funciona ou quebra.

Detalhes em [tests/README.md](tests/README.md).

### Conferindo que um teste realmente detecta algo

Uma suíte que só passa não prova nada. Quando adicionar um teste, quebre o
código de propósito e confirme que ele falha. Três bugs foram injetados assim
para validar a suíte existente — uma métrica vazia virando `0`, o clock do Intel
sendo dividido quando já vem em MHz, e a remoção do guard do `shift 2` — e cada
um foi pego pelo teste correspondente.

### Coisas que parecem erradas mas não são

Algumas partes deste código são deliberadas e custaram tempo de depuração. Antes
de "consertar" uma, leia o comentário acima dela:

- **`LC_ALL=C` antes de cada `awk`.** Sem ele, um locale pt_BR faz o `%.1f`
  emitir vírgula decimal e parte uma coluna do CSV em duas. É load-bearing.
- **`exec` dentro do `run_source`.** Sem ele, uma função lançada com `&` deixa
  `$!` apontando para o subshell em vez do produtor real; o Ctrl+C mataria a
  casca e deixaria o `nvidia-smi` órfão segurando o FIFO aberto.
- **`make_fifo` devolvendo por variável, não por stdout.** Chamá-la via `$(...)`
  a poria num subshell, e o registro para limpeza morreria junto, deixando FIFOs
  para trás em `/tmp`.
- **`stop()` caindo para `*_AWK_PID`.** Um backend que lê sysfs não tem produtor
  externo — o awk *é* a fonte, e nada o encerraria.
- **`msg_raw` ao lado do `msg`.** Um `%d` destinado ao awk precisa chegar lá sem
  ser expandido; o `msg` comum o consumiria e imprimiria zero.

### Estilo

- **Comentários em português**, o resto do código em inglês. Comentário explica
  o *porquê*, não o *quê* — se uma decisão exigiu depuração para ser encontrada,
  registre isso.
- Toda mensagem de `die()` passa pelo catálogo, para acompanhar o idioma de quem
  usa.
- Nenhuma dependência nova em tempo de execução. Rodar em qualquer lugar com
  bash e awk é o ponto do projeto.

### Pull requests

Rode `./tests/run-tests.sh` antes de abrir um. Se mudou comportamento, adicione
um teste que falhe sem a sua mudança.

Pequeno e focado vence grande e abrangente — um PR que faz uma coisa é revisado;
um que faz cinco espera.

## Licença

MIT — veja [LICENSE](LICENSE). Ao contribuir, você concorda que sua contribuição
é licenciada nos mesmos termos.
