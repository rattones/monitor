# monitor

Amostra o uso da GPU NVIDIA — incluindo VRAM — e grava em CSV, por padrão duas
amostras por segundo. Grava também um CSV atribuindo a VRAM a cada processo, para
ligar o churn de memória a quem o causa, e um CSV com leitura/escrita e
temperatura dos discos.

## Instalação

```bash
./install.sh                # para o seu usuário (~/.local), sem root
sudo ./install.sh --system  # para todos (/usr/local)
./install.sh --uninstall    # remove
```

Instala o comando `monitor` e as bibliotecas em `<prefixo>/lib/monitor/`. O
executável é **copiado**, não ligado: mover ou apagar a pasta do projeto depois
não quebra o comando. Para desenvolver — editar aqui e ver o efeito na hora —
use `./install.sh --link`.

O instalador confere a sintaxe de todos os arquivos antes de copiar, avisa se o
diretório de destino não está no `PATH`, e recusa sobrescrever um `monitor`
que não seja dele (a menos que você passe `--force`).

Sem instalar, o script roda direto: `./monitor.sh`.

## Uso

```bash
./monitor.sh                      # 2 amostras/s até Ctrl+C
./monitor.sh -d 300               # monitora por 5 minutos
./monitor.sh -i 1000 -o run.csv   # 1 amostra/s em run.csv
./monitor.sh -p compute           # só contextos CUDA
./monitor.sh -q -d 60 &           # coleta em segundo plano, sem saída na tela
```

### Subcomandos

Os três coletores são independentes e podem rodar isolados. Sem subcomando, o
padrão é `all` — o mesmo comportamento de sempre.

| Subcomando | O que coleta | Arquivo gerado |
|---|---|---|
| `all` (padrão) | GPU, processos e disco | os três |
| `gpu` | só as métricas da GPU | `<saída>.csv` |
| `disk` | só I/O e temperatura dos discos | `<saída>-disk.csv` |
| `proc` | só a VRAM por processo | `<saída>-procs.csv` |

```bash
./monitor.sh disk -D nvme0n1 -d 60   # só o disco
./monitor.sh proc -f chrome          # só os processos, filtrando
./monitor.sh gpu -i 250              # só a GPU, 4 amostras/s
```

O subcomando vem **antes** das opções. `disk` não precisa de GPU NVIDIA: roda
numa máquina sem `nvidia-smi`, já que lê apenas `/proc` e `/sys`.

> **Mudança na v3.1:** `-i/--interval` agora recebe **milissegundos inteiros**,
> não segundos, e o padrão passou de 1s para 500ms. Um `-i 0.5` antigo vira
> `-i 500`; o script detecta o valor fracionário e sugere a tradução em vez de
> só recusar.

| Opção | Descrição |
|---|---|
| `-i, --interval MS` | Intervalo entre amostras, em **milissegundos** (padrão `500`; inteiro, mínimo `100`) |
| `-d, --duration SEG` | Duração total (padrão `0` = até Ctrl+C) |
| `-o, --output ARQ` | Arquivo CSV (padrão `~/.monitor/log/monitor-AAAAMMDD-HHMMSS.csv`) |
| `-g, --gpu IDX` | Monitora só a GPU de índice `IDX` (padrão: todas) |
| `-p, --procs MODO` | `all` (padrão) = processos de compute e gráficos; `compute` = só CUDA; `off` = não coleta |
| `-f, --filter ALVO` | Monitora só estes processos — PID ou nome, vários por vírgula, opção repetível (ver abaixo) |
| `-D, --disk MODO` | `all` (padrão) = todos os discos físicos; `off` = não coleta; ou uma lista (`nvme0n1`, `sda,sdb`) |
| `-t, --top N` | Quantos processos no resumo final (padrão `5`; `0` desliga) |
| `-q, --quiet` | Só grava os CSVs, sem imprimir na tela |
| `-b, --backend NOME` | Força um backend de GPU (padrão: autodetecção) |
| `-h, --help` | Ajuda |
| `-V, --version` | Versão |

Ctrl+C encerra de forma limpa: a última amostra é gravada, o resumo é exibido e
nenhum processo fica órfão.

## Escolhendo o que monitorar

`-f/--filter` restringe o CSV de processos a alvos específicos. Cada alvo é um
**PID** (só dígitos) ou um **nome** (qualquer outra coisa); vários alvos vão
separados por vírgula, e a opção pode repetir:

```bash
./monitor.sh -f chrome                # um nome
./monitor.sh -f chrome,Xorg           # vários nomes
./monitor.sh -f 1598                  # um PID
./monitor.sh -f dota,4892 -f cinnamon # nomes e PIDs misturados
```

- **Nome** casa por trecho, ignorando maiúsculas: `-f steam` pega `steam` e
  `steamwebhelper`; `-f XORG` pega `Xorg`.
- O nome é comparado com o **executável**. Quando o alvo traz caminho ou
  argumentos, ele é comparado também com a **linha de comando inteira** — então
  dá para colar o que você vê no `ps` ou no `nvidia-smi -q`:

  ```bash
  ./monitor.sh -f /opt/google/chrome/chrome
  ./monitor.sh -f "python3 train.py"
  ./monitor.sh -f "...rack-uuid=3190708988185955192"   # nome truncado pelo nvidia-smi
  ```

  A busca na linha de comando vale só para esses alvos mais específicos. Um alvo
  curto como `-f gpu` olha apenas o executável, senão recolheria todo processo
  que tem `--type=gpu-process` entre os argumentos.
- **PID** casa exato: `-f 159` não pega o PID `1598`.
- Basta casar **um** alvo para o processo entrar (os alvos são alternativas,
  não requisitos simultâneos).
- Para um nome que é só dígitos, desfaça a ambiguidade com `name:` ou `pid:` —
  `-f name:1234` procura o processo *chamado* `1234`.
- A vírgula separa alvos, sempre. Para um comando que tenha vírgula nos
  argumentos, filtre por um trecho sem vírgula.
- O filtro é aplicado a cada amostra: um processo que só nasce no meio da
  coleta aparece a partir daí.
- Se nada casar, o script avisa e lista os processos que estavam na GPU, para
  você corrigir o alvo.

## Saídas

### `<saída>.csv` — uma linha por GPU por amostra

| Coluna | Significado |
|---|---|
| `timestamp` | ISO-8601 local com milissegundos |
| `gpu_index` / `gpu_name` | índice e modelo da GPU |
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
`vram_used_mib` / `vram_used_pct`.

### `<saída>-procs.csv` — uma linha por processo por amostra

| Coluna | Significado |
|---|---|
| `timestamp` | ISO-8601 local (resolução de 1s) |
| `gpu_index` | índice da GPU |
| `pid` | PID do processo |
| `type` | `C` = compute (CUDA), `G` = gráficos, `C+G` = os dois contextos |
| `process_name` | nome do executável (a linha de comando completa é descartada) |
| `used_vram_mib` | VRAM atribuída a esse processo |

Ao terminar, o script imprime os maiores consumidores da sessão:

```
top 5 processos por VRAM (média / pico):
  dota                     pid 60282   [C+G]    1404 MiB /   1404 MiB
  Xorg                     pid 1598    [G]      285 MiB /    285 MiB
  chrome                   pid 4892    [G]      185 MiB /    190 MiB
```

### `<saída>-disk.csv` — uma linha por disco por amostra

| Coluna | Significado |
|---|---|
| `timestamp` | ISO-8601 local (resolução de 1s) |
| `device` | nome do disco (`nvme0n1`, `sda`...) |
| `read_mb_s` / `write_mb_s` | taxa de leitura e escrita no intervalo, em MB/s |
| `read_iops` / `write_iops` | operações por segundo |
| `util_pct` | % de tempo com pelo menos uma requisição em voo |
| `temp_c` | temperatura do disco (vazio se não houver sensor) |

```
timestamp,device,read_mb_s,write_mb_s,read_iops,write_iops,util_pct,temp_c
2026-09-15T23:15:44,nvme0n1,0.64,513.00,165,4610,47.7,42.9
2026-09-15T23:15:45,nvme0n1,554.46,0.58,4982,6,40.8,42.9
```

E no resumo final:

```
disco (média / pico):
  nvme0n1    leitura   59.5 /  554.5 MB/s   escrita   60.2 /  513.0 MB/s   temp 42.8 / 42.9 C
```

Detalhes que valem saber:

- As taxas são **deltas** entre amostras: a primeira leitura serve de base, então
  a primeira linha deste CSV sai um intervalo depois do início da coleta.
- `util_pct` é tempo com I/O em voo, não vazão. Um NVMe atende várias filas em
  paralelo, então pode estar a 40% de `util_pct` já saturando a banda.
- A temperatura vem do `hwmon` do próprio dispositivo. NVMe expõe direto (o
  sensor `Composite`); discos SATA dependem do módulo `drivetemp`
  (`sudo modprobe drivetemp`). Sem sensor, a coluna fica vazia — o script não
  falha por isso.
- Partições não são aceitas em `-D`: o I/O é contabilizado no disco inteiro.
  `dm-*`, `md*` e `loop*` ficam de fora do modo `all` porque espelhariam o I/O
  dos discos reais, contando duas vezes.
- Não precisa de root nem de `smartctl`: tudo vem de `/proc/diskstats` e
  `/sys/class/hwmon`.

## Por que não `--query-compute-apps`

`nvidia-smi --query-compute-apps=pid,used_memory` é o caminho canônico, mas só
enxerga contextos **CUDA**. Num desktop, a VRAM em uso costuma ser toda de
processos **gráficos** (Xorg, navegador, jogo, compositor), e a consulta volta
vazia — sem atribuir nada. O script usa `nvidia-smi -q -d PIDS`, que traz as
duas famílias com o tipo explícito; `--procs compute` mantém quem tem contexto
de compute (`C` e também `C+G`, como um jogo que usa CUDA e vídeo ao mesmo
tempo) e reproduz o recorte do `--query-compute-apps`.

## Onde ficam os arquivos

| O quê | Onde |
|---|---|
| CSVs | `~/.monitor/log/` (sobrepõe com `MONITOR_LOG_DIR`) |
| Comando instalado | `<prefixo>/bin/monitor` |
| Bibliotecas | `<prefixo>/lib/monitor/` |

Os logs ficam na home, e não ao lado do script, para o comando instalado em
`/usr/local` não tentar escrever num diretório do sistema — e para cada usuário
ter os próprios. Desinstalar não apaga os CSVs.

## Estrutura do código

```
install.sh              instala/remove o comando no sistema
monitor.sh              entrada: carrega lib/, monta main()
lib/
├── core.sh             die, run_source, FIFOs, traps, espera
├── backend.sh          contrato dos backends de GPU + autodetecção
├── csv.sh              cabeçalhos e abertura dos CSVs
├── args.sh             subcomando, opções, validação
├── filter.sh           alvos de --filter
├── disk.sh             coleta de disco (não depende de GPU)
├── report.sh           banner, resumos, rodapé
└── backends/
    ├── nvidia.sh       via nvidia-smi — implementado
    ├── amd.sh          via sysfs amdgpu — esqueleto
    └── intel.sh        via sysfs i915/xe — esqueleto
```

Tudo que é específico de um fabricante fica em `lib/backends/<nome>.sh`, atrás
do contrato descrito em `lib/backend.sh`. Um backend implementa sete funções
(`probe`, `name`, `init`, `supports_procs`, `start_gpu`, `start_proc`,
`list_procs`); o carregador confere se todas existem e recusa um arquivo
incompleto listando o que falta, em vez de falhar no meio de uma coleta.

O backend é escolhido por autodetecção, ou forçado com `-b/--backend`:

```bash
./monitor.sh -b nvidia       # força um backend
./monitor.sh --help          # lista os disponíveis
```

**Estado atual:** só o backend NVIDIA coleta. AMD e Intel têm o `probe`
funcionando — a autodetecção já os enxerga — mas as funções de coleta ainda
falham com uma mensagem explícita. Os arquivos documentam onde cada métrica
mora em sysfs e como a coleta deve ser feita.

Um backend que não sabe atribuir VRAM por processo declara isso em
`supports_procs`, e o subcomando `proc` é recusado com explicação em vez de
gerar um CSV vazio. É o caso de AMD e Intel: nenhuma das duas tem equivalente
direto ao `nvidia-smi -q -d PIDS`.

## Notas

- Os CSVs recebem flush a cada amostra, então podem ser lidos ou plotados
  durante a coleta.
- Os três arquivos se juntam pelo segundo do timestamp (e pelo `gpu_index`,
  entre os dois primeiros).
- Apontar `-o` para um CSV já existente faz append sem repetir o cabeçalho; o
  resumo final considera só a sessão atual.
- A soma de `used_vram_mib` é menor que `vram_used_mib`: o driver e o contexto
  de vídeo reservam memória fora dos processos.
- A cadência vem do próprio `nvidia-smi` (`-lms`), que mantém uma única sessão
  NVML aberta — sem o custo e o drift de reabrir o driver a cada amostra.
- Requer `nvidia-smi` (pacote `nvidia-utils-*`).

## Exemplos de análise

```bash
# pico e média de VRAM usada
awk -F, 'NR>1 { s+=$7; if ($7>m) m=$7 } END { printf "media %.0f MiB | pico %d MiB\n", s/(NR-1), m }' logs/monitor-*.csv

# amostras em que a GPU passou de 80% de uso
awk -F, 'NR>1 && $4>80' logs/monitor-*.csv

# total de VRAM atribuída a processos, por amostra
awk -F, 'NR>1 { s[$1]+=$6 } END { for (t in s) print t, s[t] }' logs/monitor-*-procs.csv | sort

# acompanhar só um processo, do início ao fim
./monitor.sh -f dota -i 500

# picos de I/O e temperatura por disco
awk -F, 'NR>1 { if ($3>r[$2]) r[$2]=$3; if ($4>w[$2]) w[$2]=$4; if ($8>t[$2]) t[$2]=$8 }
         END { for (d in r) printf "%s: leitura %.1f MB/s | escrita %.1f MB/s | temp %.1f C\n", d, r[d], w[d], t[d] }' \
    logs/monitor-*-disk.csv

# momentos em que o disco passou de 50% de utilização
awk -F, 'NR>1 && $7>50' logs/monitor-*-disk.csv

# a GPU esperou pelo disco? cruza util da GPU com util do disco no mesmo segundo
awk -F, 'FNR==1 { next }
         FILENAME ~ /-disk/ { d[substr($1,1,19)] = $7; next }
         { g = substr($1,1,19); if (g in d) printf "%s  gpu %3s%%  disco %5.1f%%\n", g, $4, d[g] }' \
    logs/monitor-*-disk.csv logs/monitor-*[0-9].csv

# quem cresceu durante a coleta: primeira vs última leitura de cada PID
awk -F, 'NR>1 { if (!(($3) in first)) first[$3]=$6; last[$3]=$6; name[$3]=$5 }
         END { for (p in last) printf "%-24s pid %-7s %+6d MiB\n", name[p], p, last[p]-first[p] }' \
    logs/monitor-*-procs.csv | sort -k4 -n
```
