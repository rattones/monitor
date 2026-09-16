# shellcheck shell=bash
#
# usage-pt.sh - texto de ajuda em portugues.
#
# Prosa, nao mensagens: mora num arquivo por idioma em vez de ~90 entradas de
# array, o que mantem as interpolacoes ($VERSION, $LOG_DIR, backend_list)
# funcionando e o texto editavel. Carregado por usage_text() em lib/i18n.sh.

cat <<EOF
monitor.sh v$VERSION - monitor de GPU/VRAM, processos e disco, em CSV

Uso: ${0##*/} [subcomando] [opcoes]

Subcomandos:
  all      Coleta GPU, processos e disco (padrao quando nenhum e informado)
  gpu      So as metricas da GPU
  disk     So o I/O e a temperatura dos discos
  proc     So a VRAM atribuida a cada processo

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
                       So NVIDIA coleta hoje; AMD e Intel sao esqueletos.

Opcoes de processos (subcomandos all, proc):
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

Saidas (so os arquivos dos coletores ativos sao criados):
  <saida>.csv          uma linha por GPU por amostra (uso, VRAM, temperatura...)
  <saida>-procs.csv    uma linha por processo por amostra (VRAM atribuida ao PID)
  <saida>-disk.csv     uma linha por disco por amostra (leitura/escrita e temperatura)

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
EOF
