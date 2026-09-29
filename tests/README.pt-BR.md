# Testes

[English](README.md) · [Português](README.pt-BR.md)

```bash
./tests/run-tests.sh              # 184 testes, cerca de um minuto
./tests/run-tests.sh -v           # mostra a saída de cada falha
./tests/run-tests.sh amd          # só os testes cujo nome contém "amd"
```

A suíte roda o `monitor.sh` de verdade contra dados falsos: um `nvidia-smi`
mockado no `PATH` e árvores `/sys/class/drm` simuladas para AMD e Intel. Nada
toca o hardware da máquina, então **o resultado é o mesmo numa máquina sem GPU
nenhuma** — que é justamente como o backend Intel é testado, já que não há GPU
Intel aqui.

## Dois níveis por fabricante

Cada backend é exercitado com duas gerações. O nível antigo é o que importa:
é onde faltam métricas, e onde o contrato *"métrica ausente vira célula vazia,
nunca zero"* ou funciona ou quebra.

| Fabricante | Moderna | Antiga | O que a antiga exercita |
|---|---|---|---|
| NVIDIA | RTX 4070 | **GTX 1050** | `power.draw` = `[N/A]` → coluna vazia |
| AMD | RX 7800 XT | RX 560 (Polaris) | sem `mem_busy_percent`; usa `power1_average` |
| Intel | Arc A770 | HD 630 (integrada) | sem `lmem_*` → colunas `vram_*` vazias |

O que cada geração deixa de reportar não é invenção: é o que aquele hardware
de fato não expõe. Os valores ficam em [`mocks/gpu-profiles.sh`](mocks/gpu-profiles.sh).

## O que é coberto

- **Colunas e unidades** — cada backend, nos dois níveis: bytes→MiB,
  milésimos→°C, microwatts→W, Hz→MHz. O Intel confere o caso oposto:
  `gt_*_freq_mhz` já vem em MHz e **não** pode ser dividido.
- **Células vazias** — `[N/A]`, arquivo de sysfs ausente, GPU integrada sem VRAM.
- **Contrato entre backends** — mesmo cabeçalho, 13 colunas, timestamp com
  milissegundos nos três; nenhum `N/A` escrito em CSV.
- **Processos** — tipos `C`/`G`/`C+G`, `--procs compute` mantendo `C+G`,
  filtros por nome e por PID, aviso quando nada casa.
- **Argumentos** — as 9 opções com valor obrigatório (o travamento do
  `shift 2`), intervalo em ms, subcomandos, mensagens de erro.
- **Sinais** — `SIGTERM` encerrando com dados preservados, sem FIFOs órfãos,
  e o caso do backend sem produtor externo (AMD), onde o awk *é* a fonte.
- **Falhas de driver** — driver mudo, índice de GPU inexistente.
- **i18n** — detecção de idioma, precedência POSIX, fallback para inglês,
  `MONITOR_LANG` sobrepondo o locale, e que o **CSV não muda com o idioma**.

## Os mocks

| Arquivo | Papel |
|---|---|
| `mocks/gpu-profiles.sh` | os dados de cada perfil de hardware |
| `mocks/bin/nvidia-smi` | reproduz `-L`, `--query-gpu` e `-q -d PIDS` no formato exato do binário real |
| `mocks/bin/lspci` | a linha de classe PCI usada para o nome da placa |
| `mocks/make-sysfs.sh` | monta a árvore `/sys/class/drm` falsa de um perfil |

Detalhes dos mocks em [mocks/README.pt-BR.md](mocks/README.pt-BR.md).
Variáveis que os controlam:

| Variável | Efeito |
|---|---|
| `MOCK_PROFILE` | qual perfil de hardware usar |
| `MOCK_SAMPLES` | quantas amostras o fluxo emite (`0` = até ser morto) |
| `MOCK_FAIL` | `driver` (driver mudo) ou `nodevice` |
| `MONITOR_DRM_ROOT` | raiz do sysfs que os backends AMD/Intel leem |

`MONITOR_DRM_ROOT` é o ponto de injeção que torna os backends de sysfs
testáveis. Em uso normal fica em `/sys/class/drm`.

## Verificando que os testes detectam regressões

Uma suíte que só passa não prova nada. Estes três bugs foram injetados de
propósito e cada um foi detectado:

| Bug injetado | Teste que pegou |
|---|---|
| métrica ausente virando `0` em vez de vazio | `amd antiga: mem_util VAZIO` |
| dividir o clock do Intel, que já vem em MHz | `intel moderna: clock ja em MHz` |
| remover o guard do `shift 2` | `arg -i sem valor nao trava` |

Vale repetir esse exercício ao adicionar um teste novo: se ele passa tanto com
o código certo quanto com o errado, ele não está medindo nada.

## Limitações

- O mock do `nvidia-smi` emite várias amostras dentro do mesmo segundo, e o
  timestamp do CSV de processos tem resolução de 1s. Testes sobre processos
  contam PIDs distintos, não linhas por timestamp.
- O teste de disco lê o `/proc/diskstats` **real** (é só leitura, sem efeito
  colateral). Numa máquina sem ele, esse grupo é pulado.
- O teste de sistema usa um `/proc` falso (`MONITOR_PROC_ROOT`) com contadores
  parados, então as taxas de CPU e PSI saem como "não medido" e só a thread em
  `D` entra no CSV de threads. As taxas e a retenção de 10 s foram conferidas à
  mão contra processos reais. O `uptime` falso é um link para o real, porque o
  laço do coletor é cadenciado e encerrado por esse relógio.
- O backend Intel é validado contra sysfs simulado, o que exercita a lógica de
  leitura e conversão — **não** que os caminhos existam num i915 de verdade.
  Isso só um teste em hardware resolve.
