# Changelog

[English](CHANGELOG.md) · [Português](CHANGELOG.pt-BR.md)

Todas as mudanças relevantes do projeto. O formato segue o
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), e a versão é a que
`monitor --version` imprime.

## [3.4] — 2026-09-29

### Adicionado

- **`-P, --perf`** (`lib/perf.sh`): roda o `perf record` nos alvos de
  `-f pid:N` junto com os coletores, para mostrar *onde* uma thread que gira
  gasta CPU — em qual biblioteca e função —, e não só *qual* thread é.
  - `<saida>-perf.data`: amostras com pilha, comprimidas, 49 Hz por padrão
    (`MONITOR_PERF_FREQ`), no `CLOCK_MONOTONIC`.
  - `<saida>-perf.clock`: um par relógio real/monotônico lido no início, para
    levar o tempo do perf ao horário dos CSVs; `<saida>-perf.log`: a saída do
    perf.
  - Recusado logo no início, dizendo como resolver, quando não há alvo por PID,
    falta o `perf` ou o `perf_event_paranoid` bloqueia usuários comuns.
- `tools/perf-window.sh`: recebe uma janela no horário dos CSVs e imprime as
  amostras por thread, por biblioteca e pelo primeiro quadro fora do kernel.
- `<saida>-threads.csv` ganha quatro colunas: `user_pct` e `sys_pct` (o
  `cpu_pct` dividido entre o código do programa e o kernel), `last_cpu` e
  `affinity`.
- 58 testes novos (184 no total): o `-P` contra um `perf` falso, o
  `perf-window.sh`, a divisão usuário/kernel contra uma thread que gasta CPU de
  verdade no relógio do coletor, e erros de argumento, filtro e disco que não
  tinham teste.

### Alterado

- **Incompatível para quem lê o CSV:** `<saida>-threads.csv` passa de 7 para 11
  colunas; as novas vêm no fim.
- `-f/--filter` é aceito também quando só o `-P` o usaria.
- O `-P` lê o `perf_event_paranoid` sob o `MONITOR_PROC_ROOT`, como o coletor
  `sys`, para os testes não dependerem do sysctl da máquina.

### Corrigido

- O teste "sem FIFOs órfãos" contava todo `gpumon*` do `/tmp` e falhava sempre
  que um `monitor` de verdade rodava na mesma máquina; agora usa um `TMPDIR`
  próprio.
- O `tools/perf-window.sh` seguia com uma janela vazia depois de um horário
  inválido, em vez de parar.

## [3.3] — 2026-09-29

### Adicionado

- **Coletor `sys`** (`lib/sys.sh`): CPU, memória e pressão na mesma linha do
  tempo da GPU, para responder o que as métricas da GPU sozinhas não respondem —
  quando a GPU fica ociosa no meio de um jogo, quem parou de mandar trabalho
  para ela. Não depende de GPU; lê só o `/proc`.
  - `<saida>-sys.csv`: CPU total e iowait, o núcleo mais ocupado e qual é,
    memória em uso, disponível e swap, o % do intervalo com tarefas paradas
    esperando CPU, memória ou I/O (PSI) e — com `-f pid:N` — a CPU do alvo, a
    contagem de threads (total, rodando, em `D`) e page faults maiores por
    segundo.
  - `<saida>-threads.csv` (só com `-f pid:N`): uma linha por thread ativa do
    alvo por amostra, com estado, CPU e `wchan`. A thread continua no arquivo
    por 10 s depois de ficar ociosa, para a thread de render travada não sumir
    justo quando passa a importar. Threads em `D` entram sempre.
- Subcomando `sys` e opção `-S, --sys MODO` (`all` | `off`); o `all` passa a
  rodar quatro coletores.
- `MONITOR_THREADS_MIN_PCT` e `MONITOR_THREADS_HOLD_S` ajustam o limiar e a
  retenção das threads; `MONITOR_PROC_ROOT` aponta o coletor para outro `/proc`
  (usado pelos testes).
- Resumo final do sistema (CPU média/pico, núcleo mais ocupado, picos de PSI,
  CPU do alvo) e as threads que mais gastaram CPU, limitadas por `-t`.
- 20 testes novos (126 no total), contra um `/proc` falso.

### Alterado

- `-f/--filter` passa a ser aceito também pelo coletor `sys`, não só pelo `proc`.
- `-t/--top` limita também o resumo de threads.

## [3.2] — 2026-09-16

### Adicionado

- `install.sh`: instala o `monitor` como comando do sistema (`/usr/local` como
  root, `~/.local` como usuário comum); copia por padrão, `--link` para
  desenvolvimento.
- **Backend AMD** pelo sysfs do `amdgpu`, sem root e sem ferramenta externa.
  Verificado em uma GPU real.
- **Backend Intel** pelo sysfs do `i915`/`xe`, escrito a partir da documentação
  e ainda não rodado em hardware real; avisa disso ao iniciar.
- Suíte de testes (`tests/run-tests.sh`) com mocks de hardware: `nvidia-smi`
  falso e árvores `/sys/class/drm` simuladas para duas gerações de cada
  fabricante.
- i18n: ajuda, erros, banner e resumos em inglês e português, escolhidos pelo
  locale (`LC_ALL` > `LC_MESSAGES` > `LANG`) ou por `MONITOR_LANG`. Os CSVs são
  idênticos em qualquer idioma.
- README, INSTALL e CONTRIBUTING bilíngues; licença MIT.

### Alterado

- Os CSVs passam a ir para `~/.monitor/log` (sobreponha com `MONITOR_LOG_DIR`)
  em vez de `./logs` ao lado do script.
- Os backends AMD e Intel conferem a classe PCI antes de nomear a GPU: um slot
  apontando para outro dispositivo não dá mais à GPU o nome de, digamos, uma
  placa de rede.

## [3.1] — 2026-09-16

### Alterado

- `gpu-monitor.sh` renomeado para `monitor.sh`; os CSVs padrão passam a ser
  `monitor-<data>.csv`.
- **Incompatível:** `-i/--interval` recebe milissegundos inteiros, padrão `500`
  (era 1 s). `-i 0.5` é recusado com a sugestão de usar `-i 500`.

## [3.0] — 2026-09-16

### Alterado

- Código separado em módulos em `lib/`, com o que é de cada fabricante atrás de
  um contrato de sete funções em `lib/backend.sh`. O backend é escolhido por
  autodetecção ou por `-b/--backend`, e um incompleto é recusado logo no início.

## [2.0] — 2026-09-16

### Adicionado

- Subcomandos `gpu`, `disk` e `proc`; sem nenhum, o padrão `all` roda os três.
  O `disk` roda numa máquina sem `nvidia-smi`.

### Corrigido

- Uma opção sem valor no fim da linha entrava em loop infinito.
- Ctrl+C travava o script: o produtor ficava órfão segurando o FIFO.

## [1.1] — 2026-09-16

- Estado antes da refatoração em subcomandos: só NVIDIA, com os CSVs da GPU, da
  VRAM por processo e do disco.
