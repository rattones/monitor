# shellcheck shell=bash
#
# pt.sh - catalogo em portugues.
#
# Carregado por cima do en.sh, entao so precisa das chaves que traduz: o que
# faltar aqui cai para o ingles em vez de virar buraco.
#
# Sem acentos, como o resto dos .sh do projeto. Isso nao e estetica: sob
# LC_ALL=C o padding de "%-Ns" no awk conta BYTES, e um acento desalinharia a
# coluna. Hoje nenhuma destas strings cai num campo de largura fixa, mas a
# convencao evita que uma futura caia.

# --- core ------------------------------------------------------------------
MSG[core_error_prefix]='erro: %s\n'
MSG[core_load_module]='erro: nao consegui carregar lib/%s.sh\n'
MSG[core_fifo_name]='nao consegui gerar o nome do FIFO'
MSG[core_fifo_create]='nao consegui criar o FIFO %s'

# --- args ------------------------------------------------------------------
MSG[args_need_value]='a opcao %s exige um valor'
MSG[args_subcmd_order]='o subcomando deve vir antes das opcoes: %s %s ...'
MSG[args_unknown_opt]='opcao desconhecida: %s (use --help)'
MSG[args_nothing_to_collect]='nada a coletar: o subcomando "%s" foi desligado por --procs/--disk/--sys off'
MSG[args_interval_ms]='--interval e em milissegundos inteiros: use -i %s em vez de -i %s'
MSG[args_interval_invalid]='intervalo invalido: %s (milissegundos inteiros)'
MSG[args_interval_min]='intervalo minimo e 100ms (voce pediu %sms)'
MSG[args_duration_invalid]='duracao invalida: %s'
MSG[args_gpu_idx_invalid]='indice de GPU invalido: %s'
MSG[args_top_invalid]='valor invalido para --top: %s'
MSG[args_procs_mode]='modo invalido para --procs: %s (use all, compute ou off)'
MSG[args_sys_mode]='modo invalido para --sys: %s (use all ou off)'
MSG[args_filter_needs_procs]='--filter so faz sentido com a coleta de processos ou de sistema ativa'

# --- filter ----------------------------------------------------------------
MSG[filter_needs_target]='--filter exige ao menos um PID ou nome'
MSG[filter_empty_target]='alvo vazio em --filter'
MSG[filter_bad_pid]='PID invalido em --filter: %s'
MSG[filter_no_match]='\naviso: nenhum processo casou com o filtro "%s".\n'
MSG[filter_on_gpu_now]='processos na GPU agora: %s\n'

# --- csv -------------------------------------------------------------------
MSG[csv_write_failed]='nao consegui escrever em %s'
MSG[csv_mkdir_failed]='nao consegui criar %s'

# --- disk ------------------------------------------------------------------
MSG[disk_none_found]='nenhum disco fisico encontrado (use --disk off)'
MSG[disk_unknown]='disco desconhecido: %s (veja lsblk -d)'
MSG[disk_none_selected]='nenhum disco selecionado em --disk'

# --- sys -------------------------------------------------------------------
MSG[sys_bad_env]='valor invalido em %s: %s (esperava um numero)'
MSG[sys_no_proc]='nao consegui ler %s/stat - o /proc esta montado? (use --sys off)'

# --- backend ---------------------------------------------------------------
MSG[backend_unknown]='backend desconhecido: %s (procurei em %s)'
MSG[backend_load_failed]='nao consegui carregar o backend %s'
MSG[backend_incomplete]='o backend %s nao implementa: %s'
MSG[backend_none_detected]='nenhuma GPU reconhecida (backends: %s) - use --backend para forcar'
MSG[backend_no_procs]='o backend %s nao coleta VRAM por processo (use --procs off ou o subcomando gpu)'

# --- NVIDIA ----------------------------------------------------------------
MSG[nvidia_not_found]='nvidia-smi nao encontrado - driver NVIDIA instalado?'
MSG[nvidia_no_driver]='nvidia-smi nao conseguiu falar com o driver'
MSG[nvidia_list_failed]='nvidia-smi nao conseguiu listar a GPU%s: %s'
MSG[nvidia_no_gpu]='nenhuma GPU encontrada%s'
MSG[nvidia_at_index]=' no indice %s'
MSG[nvidia_of_index]=' de indice %s'

# --- AMD / Intel -----------------------------------------------------------
MSG[amd_no_gpu]='nenhuma GPU AMD encontrada%s'
MSG[intel_no_gpu]='nenhuma GPU Intel encontrada%s'
MSG[intel_untested_1]='aviso: o backend Intel nunca foi testado em hardware real.\n'
MSG[intel_untested_2]='       confira os valores contra o sysfs e reporte o que divergir.\n'
MSG[intel_untested_3]='       gpu_util_pct sai vazio: a ocupacao exige i915_pmu (intel_gpu_top).\n'
MSG[intel_dbg_cards]='placas encontradas: %s\n'
MSG[intel_dbg_gpu]='\nGPU %s: %s\n'
MSG[intel_dbg_no_pmu]='<sem fonte: exige i915_pmu>'
MSG[intel_dbg_no_source]='<sem fonte>'
MSG[intel_dbg_integrated]='<sem fonte: integrada?>'
MSG[intel_dbg_no_mclk]='<sem equivalente no i915/xe>'

# --- banner / rodape -------------------------------------------------------
MSG[report_gpu]='GPU: %s (%s)\n'
MSG[report_one_card]='1 placa'
MSG[report_n_cards]='%s placas'
MSG[report_writing_to]='gravando em: %s\n'
MSG[report_procs_to]='processos em: %s (%s%s)\n'
MSG[report_filter_suffix]=', filtro: %s'
MSG[report_disk_to]='disco em: %s (%s)\n'
MSG[report_sys_to]='sistema em: %s\n'
MSG[report_threads_to]='threads em: %s (PID %s)\n'
MSG[report_interval]='intervalo: %sms | duracao: %s | Ctrl+C para parar\n\n'
MSG[report_unlimited]='ilimitada'
MSG[report_csv]='CSV: %s\n'
MSG[report_csv_procs]='CSV processos: %s\n'
MSG[report_csv_disk]='CSV disco: %s\n'
MSG[report_csv_sys]='CSV sistema: %s\n'
MSG[report_csv_threads]='CSV threads: %s\n'
MSG[report_samples]='\n%d amostras gravadas.\n'

# --- strings passadas ao awk -----------------------------------------------
MSG[awk_top_procs]='top %d processos por VRAM (media / pico)'
MSG[awk_disk_header]='disco - leitura / escrita (media / pico)'
MSG[awk_no_sensor]='sem sensor'
MSG[awk_samples]='%d amostras gravadas.'
MSG[awk_sys_header]='sistema - media / pico'
MSG[awk_sys_core]='pico do nucleo mais ocupado'
MSG[awk_sys_psi]='pico de espera:'
MSG[awk_sys_proc]='alvo    '
MSG[awk_top_threads]='top %d threads por CPU (media / pico, %% de um nucleo)'
