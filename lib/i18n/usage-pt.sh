# shellcheck shell=bash
#
# usage-pt.sh - texto de ajuda em portugues.
#
# Prosa, nao mensagens: mora num arquivo por idioma em vez de ~90 entradas de
# array, o que mantem as interpolacoes ($VERSION, $LOG_DIR, backend_list)
# funcionando e o texto editavel. Carregado por usage_text() em lib/i18n.sh.

cat <<EOF
monitor.sh v$VERSION - monitor de GPU/VRAM, processos, disco e sistema, em CSV

Uso: ${0##*/} [subcomando] [opcoes]

Subcomandos:
  all      Coleta GPU, processos, disco e sistema (padrao quando nenhum e informado)
  gpu      So as metricas da GPU
  disk     So o I/O e a temperatura dos discos
  proc     So a VRAM atribuida a cada processo
  sys      So CPU, memoria, PSI e as threads dos PIDs de -f

Opcoes comuns:
  -i, --interval MS    Intervalo entre amostras, em milissegundos
                       (padrao: 500; inteiro, minimo 100)
  -d, --duration SEG   Duracao total em segundos (padrao: 0 = ate Ctrl+C)
  -o, --output ARQ     Arquivo CSV de saida
                       (padrao: $LOG_DIR/monitor-AAAAMMDD-HHMMSS.csv)
  -q, --quiet          Nao imprime nada na tela, so grava os CSVs
  -h, --help           Mostra esta ajuda
  -V, --version        Mostra a versao

Opcoes de GPU (subcomandos all, gpu, proc):
  -g, --gpu IDX        Monitora apenas a GPU de indice IDX (padrao: todas)
  -b, --backend NOME   Forca um backend (padrao: autodeteccao)
                       Disponiveis: $(backend_list | paste -sd" ")
                       nouveau = NVIDIA no driver livre (NVK): so VRAM, lida
                       pelo vulkaninfo. So o nvidia coleta VRAM por processo.

Opcoes de processos (subcomandos all, proc; -f pid:N vale tambem para sys):
  -p, --procs MODO     Atribuicao de VRAM por processo (padrao: all)
                         all     - processos de compute (C) e graficos (G)
                         compute - so contextos CUDA/compute (C)
                         off     - nao coleta processos
  -f, --filter ALVO    Monitora so estes processos; ALVO e um PID ou um nome,
                       varios separados por virgula, e a opcao pode repetir.
                       So digitos = PID; qualquer outra coisa = nome, que casa
                       por trecho e ignorando maiusculas. O nome e comparado com
                       o executavel e, quando o alvo traz caminho ou argumentos,
                       tambem com a linha de comando inteira.
                         -f chrome                        so o chrome
                         -f chrome,Xorg                   os dois
                         -f 1598 -f python3               PID 1598 e python3
                         -f /opt/google/chrome/chrome     caminho completo
                         -f "python3 train.py"            nome + argumentos
                         -f name:1234                     processo chamado "1234"
                       A virgula separa alvos: para um comando que tenha virgula
                       nos argumentos, filtre por um trecho sem virgula.
  -t, --top N          Quantos processos no resumo final (padrao: 5; 0 desliga)

Opcoes de disco (subcomandos all, disk):
  -D, --disk MODO      Monitora I/O e temperatura de disco (padrao: all)
                         all     - todos os discos fisicos
                         off     - nao coleta disco
                         LISTA   - dispositivos separados por virgula
                                   (ex: -D nvme0n1 ou -D sda,sdb)

Opcoes de sistema (subcomandos all, sys):
  -S, --sys MODO       CPU, memoria, PSI e threads do alvo (padrao: all)
                         all     - coleta
                         off     - nao coleta
                       As threads so sao seguidas para PIDs dados em -f pid:N.
                       Uma thread entra no CSV quando gasta 1% de um nucleo e
                       fica por mais 10 s depois de parar: e nesse momento que o
                       wchan dela mostra o que a travou.
  -P, --perf           Amostra as pilhas dos PIDs de -f pid:N com perf record,
                       para ver em qual biblioteca e funcao uma thread gira.
                       Sem root, exige kernel.perf_event_paranoid <= 1.

Saidas (so os arquivos dos coletores ativos sao criados):
  <saida>.csv          uma linha por GPU por amostra (uso, VRAM, temperatura...)
  <saida>-procs.csv    uma linha por processo por amostra (VRAM atribuida ao PID)
  <saida>-disk.csv     uma linha por disco por amostra (leitura/escrita e temperatura)
  <saida>-sys.csv      uma linha por amostra (CPU, memoria, PSI e o alvo agregado)
  <saida>-threads.csv  uma linha por thread ativa do alvo por amostra (so com -f pid:N)
  <saida>-perf.data    amostras do perf (so com -P), com a propria referencia de
                       horario real - ver tools/perf-window.sh

Colunas de <saida>.csv:
  timestamp          ISO-8601 local, com milissegundos
  gpu_index          indice da GPU
  gpu_name           nome do modelo
  gpu_util_pct       % de tempo com kernels ativos (ocupacao do nucleo)
  mem_util_pct       % de tempo com o barramento de memoria em uso
  vram_total_mib     VRAM total
  vram_used_mib      VRAM em uso
  vram_free_mib      VRAM livre
  vram_used_pct      VRAM em uso, em % do total
  temp_c             temperatura do nucleo em C
  power_w            consumo em W (vazio se a GPU nao reporta)
  sm_clock_mhz       clock dos SMs
  mem_clock_mhz      clock da memoria

Colunas de <saida>-procs.csv:
  timestamp          ISO-8601 local (resolucao de 1s)
  gpu_index          indice da GPU
  pid                PID do processo
  type               C = compute (CUDA), G = graficos
  process_name       nome do executavel
  used_vram_mib      VRAM atribuida a esse processo

Colunas de <saida>-disk.csv:
  timestamp          ISO-8601 local (resolucao de 1s)
  device             nome do disco (nvme0n1, sda...)
  read_mb_s          leitura no intervalo, em MB/s
  write_mb_s         escrita no intervalo, em MB/s
  read_iops          operacoes de leitura por segundo
  write_iops         escritas por segundo
  util_pct           % de tempo com pelo menos uma requisicao em voo
  temp_c             temperatura do disco (vazio se nao houver sensor)

Colunas de <saida>-sys.csv:
  timestamp          ISO-8601 local, com milissegundos (resolucao de 10 ms)
  cpu_util_pct       % de CPU ocupada, media de todos os nucleos
  cpu_iowait_pct     % do tempo de CPU ocioso esperando I/O
  cpu_max_core_pct   % do nucleo mais ocupado - um jogo preso numa thread
                     satura um nucleo com a media ainda baixa
  cpu_max_core       qual nucleo foi esse
  mem_used_mib       memoria em uso (total - disponivel)
  mem_avail_mib      memoria disponivel
  swap_used_mib      swap em uso
  psi_cpu_pct        % do intervalo com alguma tarefa esperando CPU (PSI)
  psi_mem_pct        idem, esperando memoria
  psi_io_pct         idem, esperando I/O
  proc_cpu_pct       CPU dos PIDs de -f, em % de um nucleo (vazio sem alvo)
  proc_threads       threads do alvo
  proc_running       threads do alvo rodando (estado R)
  proc_dstate        threads do alvo em D (I/O ou kernel, nao interrompiveis)
  proc_majflt_s      page faults maiores por segundo (paginas vindas do disco)

Colunas de <saida>-threads.csv:
  timestamp          o mesmo da linha de <saida>-sys.csv
  pid, tid           processo e thread
  thread_name        nome da thread (virgulas viram _)
  state              R rodando, S dormindo, D nao interrompivel...
  cpu_pct            CPU da thread no intervalo, em % de um nucleo
  wchan              funcao do kernel onde a thread dorme: futex_* (lock entre
                     threads), poll/select (socket: X11, audio, rede), funcoes
                     do driver de video (esperando a GPU); 0 quando rodando
  user_pct, sys_pct  cpu_pct dividido entre o codigo do programa e o kernel:
                     uma thread a 100% em user_pct gira no proprio codigo
  last_cpu           ultimo nucleo em que a thread rodou
  affinity           nucleos em que ela pode rodar (ex.: 0-15; virgulas viram
                     espaco)

Uma metrica que o hardware nao reporta vira celula vazia, nunca zero: zero e um
valor medido, vazio e a ausencia de medida.

Os arquivos se juntam pelo segundo do timestamp (e pelo gpu_index, entre os dois
primeiros). A soma de used_vram_mib e menor que vram_used_mib, porque o driver e
o contexto de video tambem reservam memoria fora dos processos. As taxas de disco
sao deltas entre amostras, entao a primeira leitura serve de base e a primeira
linha de <saida>-disk.csv sai um intervalo depois do inicio.

Os CSVs recebem flush a cada amostra, entao podem ser lidos/plotados enquanto
a coleta ainda esta rodando.
Ambiente:
  MONITOR_LANG         Forca o idioma (ex.: en, pt), ignorando o locale
  MONITOR_LOG_DIR      Onde os CSVs vao (padrao: \$HOME/.monitor/log)
  MONITOR_THREADS_MIN_PCT  CPU minima para uma thread entrar no CSV (padrao: 1)
  MONITOR_THREADS_HOLD_S   Segundos que ela fica depois de parar (padrao: 10)
  MONITOR_PERF_FREQ        Amostras por segundo do -P (padrao: 49)
  MONITOR_NOUVEAU_MIN_MS   Minimo de ms entre leituras de VRAM no nouveau (padrao: 2000)
EOF
