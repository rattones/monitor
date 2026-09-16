# gpu-monitor

Amostra o uso da GPU NVIDIA — incluindo VRAM — e grava em CSV, por padrão uma
linha por segundo. Grava também um CSV atribuindo a VRAM a cada processo, para
ligar o churn de memória a quem o causa, e um CSV com leitura/escrita e
temperatura dos discos.

## Uso

```bash
./gpu-monitor.sh                      # 1 amostra/s até Ctrl+C
./gpu-monitor.sh -d 300               # monitora por 5 minutos
./gpu-monitor.sh -i 0.5 -o run.csv    # 2 amostras/s em run.csv
./gpu-monitor.sh -p compute           # só contextos CUDA
./gpu-monitor.sh -q -d 60 &           # coleta em segundo plano, sem saída na tela
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
./gpu-monitor.sh disk -D nvme0n1 -d 60   # só o disco
./gpu-monitor.sh proc -f chrome          # só os processos, filtrando
./gpu-monitor.sh gpu -i 0.5              # só a GPU, 2 amostras/s
```

O subcomando vem **antes** das opções. `disk` não precisa de GPU NVIDIA: roda
numa máquina sem `nvidia-smi`, já que lê apenas `/proc` e `/sys`.

| Opção | Descrição |
|---|---|
| `-i, --interval SEG` | Intervalo entre amostras (padrão `1`; aceita fração, mínimo `0.1`) |
| `-d, --duration SEG` | Duração total (padrão `0` = até Ctrl+C) |
| `-o, --output ARQ` | Arquivo CSV (padrão `logs/gpu-AAAAMMDD-HHMMSS.csv`) |
| `-g, --gpu IDX` | Monitora só a GPU de índice `IDX` (padrão: todas) |
| `-p, --procs MODO` | `all` (padrão) = processos de compute e gráficos; `compute` = só CUDA; `off` = não coleta |
| `-f, --filter ALVO` | Monitora só estes processos — PID ou nome, vários por vírgula, opção repetível (ver abaixo) |
| `-D, --disk MODO` | `all` (padrão) = todos os discos físicos; `off` = não coleta; ou uma lista (`nvme0n1`, `sda,sdb`) |
| `-t, --top N` | Quantos processos no resumo final (padrão `5`; `0` desliga) |
| `-q, --quiet` | Só grava os CSVs, sem imprimir na tela |
| `-h, --help` | Ajuda |

Ctrl+C encerra de forma limpa: a última amostra é gravada, o resumo é exibido e
nenhum processo fica órfão.

## Escolhendo o que monitorar

`-f/--filter` restringe o CSV de processos a alvos específicos. Cada alvo é um
**PID** (só dígitos) ou um **nome** (qualquer outra coisa); vários alvos vão
separados por vírgula, e a opção pode repetir:

```bash
./gpu-monitor.sh -f chrome                # um nome
./gpu-monitor.sh -f chrome,Xorg           # vários nomes
./gpu-monitor.sh -f 1598                  # um PID
./gpu-monitor.sh -f dota,4892 -f cinnamon # nomes e PIDs misturados
```

- **Nome** casa por trecho, ignorando maiúsculas: `-f steam` pega `steam` e
  `steamwebhelper`; `-f XORG` pega `Xorg`.
- O nome é comparado com o **executável**. Quando o alvo traz caminho ou
  argumentos, ele é comparado também com a **linha de comando inteira** — então
  dá para colar o que você vê no `ps` ou no `nvidia-smi -q`:

  ```bash
  ./gpu-monitor.sh -f /opt/google/chrome/chrome
  ./gpu-monitor.sh -f "python3 train.py"
  ./gpu-monitor.sh -f "...rack-uuid=3190708988185955192"   # nome truncado pelo nvidia-smi
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
awk -F, 'NR>1 { s+=$7; if ($7>m) m=$7 } END { printf "media %.0f MiB | pico %d MiB\n", s/(NR-1), m }' logs/gpu-*.csv

# amostras em que a GPU passou de 80% de uso
awk -F, 'NR>1 && $4>80' logs/gpu-*.csv

# total de VRAM atribuída a processos, por amostra
awk -F, 'NR>1 { s[$1]+=$6 } END { for (t in s) print t, s[t] }' logs/gpu-*-procs.csv | sort

# acompanhar só um processo, do início ao fim
./gpu-monitor.sh -f dota -i 0.5

# picos de I/O e temperatura por disco
awk -F, 'NR>1 { if ($3>r[$2]) r[$2]=$3; if ($4>w[$2]) w[$2]=$4; if ($8>t[$2]) t[$2]=$8 }
         END { for (d in r) printf "%s: leitura %.1f MB/s | escrita %.1f MB/s | temp %.1f C\n", d, r[d], w[d], t[d] }' \
    logs/gpu-*-disk.csv

# momentos em que o disco passou de 50% de utilização
awk -F, 'NR>1 && $7>50' logs/gpu-*-disk.csv

# a GPU esperou pelo disco? cruza util da GPU com util do disco no mesmo segundo
awk -F, 'FNR==1 { next }
         FILENAME ~ /-disk/ { d[substr($1,1,19)] = $7; next }
         { g = substr($1,1,19); if (g in d) printf "%s  gpu %3s%%  disco %5.1f%%\n", g, $4, d[g] }' \
    logs/gpu-*-disk.csv logs/gpu-*[0-9].csv

# quem cresceu durante a coleta: primeira vs última leitura de cada PID
awk -F, 'NR>1 { if (!(($3) in first)) first[$3]=$6; last[$3]=$6; name[$3]=$5 }
         END { for (p in last) printf "%-24s pid %-7s %+6d MiB\n", name[p], p, last[p]-first[p] }' \
    logs/gpu-*-procs.csv | sort -k4 -n
```
