# Changelog

[English](CHANGELOG.md) · [Português](CHANGELOG.pt-BR.md)

Todas as mudanças relevantes do projeto. O formato segue o
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), e a versão é a que
`monitor --version` imprime.

## [3.6] — 2026-10-05

### Adicionado

- **Comando `freeze-probe`**: o `install.sh` agora instala a sonda ao lado do
  monitor (`<prefixo>/bin/freeze-probe`, com o `probe/` em
  `<prefixo>/lib/monitor/`), nos modos cópia e `--link`, e o `--uninstall` a
  remove. Instalar não dá privilégio nenhum: ela só roda quando chamada com
  `sudo`. Como o sudo procura no `secure_path` e não no `PATH` da pessoa, o
  instalador mostra a linha certa, `sudo freeze-probe` em `/usr/local` ou o
  caminho completo em `~/.local`, e a ajuda e as mensagens da sonda usam o mesmo
  nome. Um `freeze-probe` que não foi instalado por este script não é
  sobrescrito sem `--force` nem removido.
- `freeze-probe -V`: mostra a versão do monitor, sem precisar de root.
- **Subprojeto `probe/`: sonda das travadas da thread principal** (bpftrace,
  root), separada do monitor, que continua rodando como usuário sem mudança.
  `sudo ./probe/freeze-probe.sh` espera o jogo abrir e grava em
  `~/.monitor/log/<nome>-<data>-probe.txt` cada travada da principal acima do
  limiar (`futex`, `epoll` ou sem syscall): timeout pedido e retorno, pilha ao
  dormir, quem acordou e por qual mecanismo, `FUTEX_WAKE` no mesmo endereço,
  descritor do epoll que disparou e as threads que rodaram durante a parada.
  `--check` valida o programa no kernel. Guarda também
  `<nome>-<data>-probe.maps` (os trechos executáveis do processo) e no fim troca
  os quadros `0x... ([unknown])` das pilhas por `biblioteca.so+0xdeslocamento`.
  Todo o estado da sonda fica em mapas com chave, porque é lido de outras CPUs.
  Ver `probe/README.pt-BR.md`.
- INSTALL e README: como instalar a sonda e rodá-la com sudo.
- README: seção sobre a sonda, a pasta `probe/` na árvore do código e "Na
  prática", com o link da investigação para a qual as ferramentas foram feitas.
- 20 testes para o lançador da sonda, com `bpftrace` e `/proc` falsos, e os
  primeiros 15 do `install.sh` (239 no total).

### Corrigido

- A mensagem "precisa de root" da sonda perdia os argumentos (imprimia o `$*`
  depois de consumi-los). Agora repete o comando exato a rodar com sudo.

## [3.5] — 2026-09-29

### Adicionado

- **Backend `nouveau`** (`lib/backends/nouveau.sh`): placa NVIDIA na pilha livre
  (driver nouveau + NVK), onde o `nvidia-smi` não existe. Preenche VRAM total,
  usada, livre e porcentagem; com o firmware GSP o driver não expõe mais nada, e
  as outras colunas ficam vazias. A VRAM vem do `vulkaninfo`
  (`VK_EXT_memory_budget`: usada = total − budget / 0,9), lida no máximo a cada
  `MONITOR_NOUVEAU_MIN_MS` (2000 por padrão), porque cada leitura cria um
  dispositivo Vulkan. Produtor em `lib/helpers/nouveau-sampler.sh`.
  Autodetectado depois do `nvidia`.
- 20 testes novos (204 no total) para o backend nouveau, contra um sampler falso.

### Mudado

- O `all` com um backend sem VRAM por processo (nouveau, AMD, Intel) agora
  desliga o coletor de processos com um aviso, em vez de recusar; o `proc`
  explícito continua recusado.
- O `-P` não grava mais o `<saída>-perf.clock`: gravando em `CLOCK_MONOTONIC`,
  o perf guarda a referência de horário real no próprio `perf.data`, e o
  `tools/perf-window.sh` a lê com `perf script -F tod`. Gravações antigas com
  `.clock` continuam funcionando. Isso remove o único uso de `python3`.
- O `tools/perf-window.sh` roda o perf sem debuginfod: ele ficava 14 s parado na
  rede e mandava os build-ids das bibliotecas do jogo para um servidor externo.

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
