# monitor

[English](README.md) · [Português](README.pt-BR.md)

Amostra o uso da GPU — incluindo VRAM — e grava em CSV, por padrão duas amostras
por segundo. Grava também um CSV atribuindo a VRAM a cada processo, para ligar o
churn de memória a quem o causa, e um CSV com leitura/escrita e temperatura dos
discos.

```bash
./monitor.sh -d 300
```

```
GPU: NVIDIA (1 placa)
gravando em: /home/voce/.monitor/log/monitor-20260916-095821.csv
intervalo: 500ms | duracao: 300s | Ctrl+C para parar

09:58:21  GPU0  util  30%   vram   794/4096 MiB (19.4%)   temp  52 C    24.00 W
09:58:22  GPU0  util  35%   vram   812/4096 MiB (19.8%)   temp  53 C    26.10 W
```

Três coletores na mesma linha do tempo: GPU, VRAM por processo e disco,
amostrados no mesmo relógio, então os CSVs se juntam pelo timestamp. Sem daemon,
sem dependência além de bash e awk, e com flush a cada amostra — dá para plotar
enquanto a coleta ainda roda.

## Instalação

```bash
git clone https://github.com/rattones/monitor.git
cd monitor
./install.sh          # em ~/.local, sem root
```

Ou rode direto do clone com `./monitor.sh`. Detalhes completos, incluindo
instalação para todos os usuários e solução de problemas, em
[INSTALL.pt-BR.md](INSTALL.pt-BR.md).

## Uso

```bash
monitor                      # 2 amostras/s até Ctrl+C
monitor -d 300               # por 5 minutos
monitor -i 1000 -o run.csv   # 1 amostra/s em run.csv
monitor -p compute           # só contextos CUDA
monitor -q -d 60 &           # em segundo plano, sem saída na tela
```

### Subcomandos

Os três coletores são independentes e podem rodar isolados. Sem subcomando, o
padrão é `all`.

| Subcomando | O que coleta | Arquivo |
|---|---|---|
| `all` (padrão) | GPU, processos e disco | os três |
| `gpu` | só as métricas da GPU | `<saída>.csv` |
| `disk` | só I/O e temperatura dos discos | `<saída>-disk.csv` |
| `proc` | só a VRAM por processo | `<saída>-procs.csv` |

```bash
monitor disk -D nvme0n1 -d 60   # só o disco
monitor proc -f chrome          # só os processos, filtrando
monitor gpu -i 250              # só a GPU, 4 amostras/s
```

O subcomando vem **antes** das opções. `disk` não precisa de GPU nenhuma: lê
apenas `/proc` e `/sys`, então roda numa máquina sem `nvidia-smi`.

### Opções

| Opção | Descrição |
|---|---|
| `-i, --interval MS` | Intervalo entre amostras, em **milissegundos** (padrão `500`; inteiro, mínimo `100`) |
| `-d, --duration SEG` | Duração total (padrão `0` = até Ctrl+C) |
| `-o, --output ARQ` | Arquivo CSV (padrão `~/.monitor/log/monitor-AAAAMMDD-HHMMSS.csv`) |
| `-g, --gpu IDX` | Monitora só a GPU de índice `IDX` (padrão: todas) |
| `-b, --backend NOME` | Força um backend de GPU (padrão: autodetecção) |
| `-p, --procs MODO` | `all` (padrão) = compute e gráficos; `compute` = só CUDA; `off` = não coleta |
| `-f, --filter ALVO` | Monitora só estes processos — PID ou nome, separados por vírgula, opção repetível |
| `-D, --disk MODO` | `all` (padrão) = todos os discos físicos; `off` = não coleta; ou uma lista (`nvme0n1`, `sda,sdb`) |
| `-t, --top N` | Quantos processos no resumo final (padrão `5`; `0` desliga) |
| `-q, --quiet` | Só grava os CSVs, sem imprimir na tela |
| `-h, --help` | Ajuda |
| `-V, --version` | Versão |

Ctrl+C encerra de forma limpa: a última amostra é gravada, o resumo é exibido e
nenhum processo fica órfão.

## Suporte a GPU

| Backend | Métricas da GPU | VRAM por processo |
|---|---|---|
| `nvidia` | sim | sim |
| `amd` | sim | não |
| `intel` | sim\* | não |

O backend é autodetectado, ou forçado com `-b/--backend`.

**AMD** lê o sysfs do driver `amdgpu` — sem root, sem ferramenta externa.
Verificado contra uma Radeon Vega (Cezanne). Nessa APU o `mem_util_pct` sai
vazio porque a placa não expõe `mem_busy_percent`; placas dedicadas costumam
expor.

**\* Intel** foi escrito a partir da documentação do kernel e **nunca rodou em
hardware real** — não há GPU Intel na máquina de desenvolvimento. A leitura e a
conversão de unidades são exercitadas contra um sysfs simulado, mas os caminhos
em si não foram verificados. Ele avisa isso ao iniciar.
[Ajude a mudar isso →](CONTRIBUTING.pt-BR.md)

Nem AMD nem Intel têm equivalente ao `nvidia-smi -q -d PIDS`, então o `proc` é
recusado nelas com explicação, em vez de gerar um CSV vazio. Para coletar GPU e
disco na AMD:

```bash
monitor -b amd -p off
```

## Escolhendo o que monitorar

`-f/--filter` restringe o CSV de processos a alvos específicos. Cada alvo é um
**PID** (só dígitos) ou um **nome** (qualquer outra coisa):

```bash
monitor -f chrome                # um nome
monitor -f chrome,Xorg           # vários nomes
monitor -f 1598                  # um PID
monitor -f dota,4892 -f cinnamon # nomes e PIDs misturados
```

- **Nome** casa por trecho, ignorando maiúsculas: `-f steam` pega `steam` e
  `steamwebhelper`.
- O nome é comparado com o **executável**. Quando o alvo traz caminho ou
  argumentos, é comparado também com a **linha de comando inteira** — então dá
  para colar o que você vê no `ps` ou no `nvidia-smi -q`:

  ```bash
  monitor -f /opt/google/chrome/chrome
  monitor -f "python3 train.py"
  monitor -f "...rack-uuid=3190708988185955192"   # nome truncado pelo nvidia-smi
  ```

  A busca ampla vale só para esses alvos mais específicos. Um alvo curto como
  `-f gpu` olha apenas o executável, senão recolheria todo processo que tem
  `--type=gpu-process` entre os argumentos.
- **PID** casa exato: `-f 159` não pega o PID `1598`.
- Basta casar **um** alvo para o processo entrar — os alvos são alternativas,
  não requisitos simultâneos.
- Para um nome que é só dígitos, desfaça a ambiguidade com `name:` ou `pid:` —
  `-f name:1234` procura o processo *chamado* `1234`.
- Se nada casar, o script avisa e lista os processos que estavam na GPU, para
  você corrigir o alvo.

## Saídas

### `<saída>.csv` — uma linha por GPU por amostra

| Coluna | Significado |
|---|---|
| `timestamp` | ISO-8601 local com milissegundos |
| `gpu_index` / `gpu_name` | índice e modelo |
| `gpu_util_pct` | % de tempo com kernels ativos (ocupação do núcleo) |
| `mem_util_pct` | % de tempo com o barramento de memória em uso |
| `vram_total_mib` / `vram_used_mib` / `vram_free_mib` | VRAM em MiB |
| `vram_used_pct` | VRAM em uso, em % do total |
| `temp_c` | temperatura do núcleo, em °C |
| `power_w` | consumo em W (vazio se a GPU não reporta) |
| `sm_clock_mhz` / `mem_clock_mhz` | clocks dos SMs e da memória |

`gpu_util_pct` e `mem_util_pct` são percentuais de *tempo ocupado*, não de
capacidade: `mem_util_pct` alto com `vram_used_pct` baixo significa tráfego
intenso em pouca memória. Para saber quanta VRAM está sendo consumida, use
`vram_used_mib`.

### `<saída>-procs.csv` — uma linha por processo por amostra

| Coluna | Significado |
|---|---|
| `timestamp` | ISO-8601 local (resolução de 1s) |
| `gpu_index` / `pid` | índice da GPU e PID do processo |
| `type` | `C` = compute (CUDA), `G` = gráficos, `C+G` = os dois |
| `process_name` | nome do executável (a linha de comando completa é descartada) |
| `used_vram_mib` | VRAM atribuída a esse processo |

Ao terminar, os maiores consumidores da sessão:

```
top 5 processos por VRAM (media / pico):
  dota                     pid 60282   [C+G]    1404 MiB /   1404 MiB
  Xorg                     pid 1598    [G]      285 MiB /    285 MiB
```

### `<saída>-disk.csv` — uma linha por disco por amostra

| Coluna | Significado |
|---|---|
| `timestamp` / `device` | timestamp e nome do disco |
| `read_mb_s` / `write_mb_s` | taxa de leitura e escrita no intervalo, em MB/s |
| `read_iops` / `write_iops` | operações por segundo |
| `util_pct` | % de tempo com pelo menos uma requisição em voo |
| `temp_c` | temperatura do disco (vazio se não houver sensor) |

E no resumo final:

```
disco - leitura / escrita (media / pico):
  nvme0n1      59.5 /  554.5 MB/s     60.2 /  513.0 MB/s   temp 42.8 / 42.9 C
```

Detalhes que valem saber:

- As taxas são **deltas** entre amostras: a primeira leitura serve de base,
  então a primeira linha deste CSV sai um intervalo depois do início.
- `util_pct` é tempo com I/O em voo, não vazão. Um NVMe atende várias filas em
  paralelo, então pode estar a 40% de `util_pct` já saturando a banda.
- A temperatura vem do `hwmon` do próprio dispositivo. NVMe expõe direto; discos
  SATA dependem do módulo `drivetemp` (`sudo modprobe drivetemp`).
- Partições não são aceitas em `-D`: o I/O é contabilizado no disco inteiro.
  `dm-*`, `md*` e `loop*` ficam de fora do modo `all` porque espelhariam os
  discos reais, contando duas vezes.
- Não precisa de root nem de `smartctl`.

### Métrica não reportada fica vazia, nunca zero

Zero é um valor medido; vazio é a ausência de medida. Todo backend escreve as
mesmas colunas, na mesma ordem — é o que permite juntar coletas de máquinas
diferentes no mesmo gráfico — e deixa a célula vazia quando aquele hardware não
expõe a métrica.

## Idioma

O texto que aparece em execução — ajuda, erros, banner e resumos — segue o
locale do sistema. Português e inglês estão traduzidos; qualquer outro locale
cai para inglês.

```bash
LANG=en_US.UTF-8 monitor --help   # inglês
LANG=pt_BR.UTF-8 monitor --help   # português
MONITOR_LANG=en monitor --help    # força, ignorando o locale
```

A detecção segue a precedência POSIX (`LC_ALL` > `LC_MESSAGES` > `LANG`), com
`MONITOR_LANG` acima de todas. Os catálogos ficam em `lib/i18n/<idioma>.sh`;
adicionar um idioma é adicionar um arquivo.

**O CSV não muda com o idioma.** Cabeçalhos e separador decimal são formato de
dados, não texto — do contrário duas coletas da mesma máquina deixariam de ser
comparáveis. Há um teste dedicado a isso.

Os comentários do código seguem em português.

## Estrutura do código

```
monitor.sh              entrada: carrega lib/, monta main()
install.sh              instala/remove o comando no sistema
lib/
├── core.sh             die, run_source, FIFOs, traps, espera
├── backend.sh          contrato dos backends de GPU + autodetecção
├── csv.sh              cabeçalhos e abertura dos CSVs
├── args.sh             subcomando, opções, validação
├── filter.sh           alvos de --filter
├── disk.sh             coleta de disco (não depende de GPU)
├── report.sh           banner, resumos, rodapé
├── i18n.sh             detecção de idioma e catálogo
├── i18n/               mensagens e ajuda por idioma
└── backends/
    ├── nvidia.sh       via nvidia-smi — implementado
    ├── amd.sh          via sysfs amdgpu — implementado (sem VRAM/processo)
    └── intel.sh        via sysfs i915/xe — não testado em hardware
tests/                  suíte de testes e mocks
```

Tudo que é específico de um fabricante fica em `lib/backends/<nome>.sh`, atrás
do contrato descrito em `lib/backend.sh`. Um backend implementa sete funções; o
carregador confere se todas existem e recusa um arquivo incompleto listando o
que falta, em vez de falhar no meio de uma coleta.

## Testes

```bash
./tests/run-tests.sh          # 106 testes, cerca de um minuto
./tests/run-tests.sh -v amd   # filtra e mostra a saída das falhas
```

A suíte roda o script de verdade contra mocks — um `nvidia-smi` falso e árvores
de sysfs simuladas —, então dá o mesmo resultado numa máquina sem GPU nenhuma.
Cada fabricante é testado em duas gerações, moderna e antiga, porque é na
antiga, onde faltam métricas, que o contrato da célula vazia é posto à prova.

Detalhes em [tests/README.pt-BR.md](tests/README.pt-BR.md).

## Contribuindo

**Se você tem uma GPU AMD ou Intel, o mais útil que pode fazer leva um minuto:**
rodar dois comandos e colar a saída numa issue. O backend Intel nunca tocou
hardware real, e o AMD foi verificado contra uma única placa. Veja
[CONTRIBUTING.pt-BR.md](CONTRIBUTING.pt-BR.md).

## Exemplos de análise

```bash
# pico e média de VRAM usada
awk -F, 'NR>1 { s+=$7; if ($7>m) m=$7 } END { printf "media %.0f MiB | pico %d MiB\n", s/(NR-1), m }' \
    ~/.monitor/log/monitor-*.csv

# amostras em que a GPU passou de 80% de uso
awk -F, 'NR>1 && $4>80' ~/.monitor/log/monitor-*.csv

# a GPU esperou pelo disco? cruza util da GPU com util do disco no mesmo segundo
awk -F, 'FNR==1 { next }
         FILENAME ~ /-disk/ { d[substr($1,1,19)] = $7; next }
         { g = substr($1,1,19); if (g in d) printf "%s  gpu %3s%%  disco %5.1f%%\n", g, $4, d[g] }' \
    ~/.monitor/log/monitor-*-disk.csv ~/.monitor/log/monitor-*[0-9].csv

# quem cresceu durante a coleta: primeira vs última leitura de cada PID
awk -F, 'NR>1 { if (!(($3) in first)) first[$3]=$6; last[$3]=$6; name[$3]=$5 }
         END { for (p in last) printf "%-24s pid %-7s %+6d MiB\n", name[p], p, last[p]-first[p] }' \
    ~/.monitor/log/monitor-*-procs.csv | sort -k4 -n
```

## Por que não `--query-compute-apps`

`nvidia-smi --query-compute-apps=pid,used_memory` é o caminho canônico, mas só
enxerga contextos **CUDA**. Num desktop, a VRAM em uso costuma ser toda de
processos **gráficos** (Xorg, navegador, jogo, compositor), e a consulta volta
vazia — sem atribuir nada. Este script usa `nvidia-smi -q -d PIDS`, que traz as
duas famílias com o tipo explícito; `--procs compute` mantém quem tem contexto
de compute (`C` e também `C+G`, como um jogo que usa CUDA e vídeo ao mesmo
tempo) e reproduz o recorte do `--query-compute-apps`.

## Licença

MIT — veja [LICENSE](LICENSE).
