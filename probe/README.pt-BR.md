# freeze-probe: sonda das travadas da thread principal

*[English](README.md)*

Subprojeto do monitor para responder **o que segura e o que solta** uma
travada, coisa que os CSVs do monitor (amostras a cada 500 ms, só como usuário)
não alcançam. Usa eBPF (bpftrace), então precisa de root. **O monitor não muda
nada**: continua rodando como usuário pelo hook do GameMode. A sonda roda à
parte, com `sudo`, e as duas gravam no mesmo `~/.monitor/log`, no mesmo relógio
local, para cruzar os horários.

## Uso

```bash
sudo ./probe/freeze-probe.sh --check    # uma vez: valida o programa no seu kernel
sudo ./probe/freeze-probe.sh            # antes de jogar: espera o dota2 abrir
```

Depois é só jogar. A sonda se prende ao jogo quando ele abre e sai sozinha
quando ele fecha. O arquivo é
`~/.monitor/log/dota2-AAAAMMDD-HHMMSS-probe.txt`, com você como dono.

| Opção | O que faz |
|---|---|
| `-n NOME` | nome exato do processo (padrão `dota2`) |
| `-p PID` | prende num processo que já está rodando |
| `-t MS` | limiar da travada em ms (padrão 500, mínimo 50) |
| `-o DIR` | diretório de saída (padrão `~/.monitor/log` de quem chamou o sudo) |
| `--check` | só compila e prende as sondas (`bpftrace --dry-run`) e sai |

Requisitos: `bpftrace` (testado com 0.25), kernel com BTF
(`/sys/kernel/btf/vmlinux`).

## O que é uma travada para a sonda

A thread principal (tid = pid) parada por mais que o limiar:

| Variante | Como a principal está parada |
|---|---|
| **A** | dormindo num `futex` (`FUTEX_WAIT` / `FUTEX_WAIT_BITSET`) |
| **B** | dormindo num `epoll_wait` / `epoll_pwait` / `epoll_pwait2` |
| **C** | sem fazer nenhuma chamada de sistema: ela mesma está girando |

## O que cada bloco traz

```
=== TRAVADA 21:17:59.120000 var=A dur=3218ms
principal: futex cmd=9 op=0x89 uaddr=0x7f00aa0010 timeout_pedido_ms=-1 ret=0
WAKE_MESMO_ENDERECO ... tid=... comm=GlobPool/1 ...      (se houver)
--- pilha da principal ao dormir:
--- acordada por: comm=... pid=... tid=...
--- pilha do kernel de quem acordou:
--- pilha de usuario de quem acordou:
--- threads do jogo rodando durante a travada (amostras a 99 Hz: tid, nome, cpu, pilha):
--- chamadas de sistema das outras threads durante a travada (tid, nome, nr):
=== FIM
```

- **`timeout_pedido_ms` e `ret`**: o prazo que a principal pediu ao kernel
  (`-1` = sem prazo; `-2` = prazo absoluto em `CLOCK_REALTIME`) e o retorno
  (`-110` = `ETIMEDOUT` no futex; `0` = prazo esgotado no epoll). Diz se o teto
  de ~3,2 s é da principal ou de quem ela espera.
- **`WAKE_MESMO_ENDERECO`**: outra thread do jogo fez `FUTEX_WAKE` no endereço
  exato em que a principal dorme. Prova a dependência direta.
- **acordada por**: quem acordou a principal (`sched_waking`). A pilha do kernel
  mostra o mecanismo: `futex_wake` (outra thread liberou), `ep_poll_callback`
  vindo de `eventfd_write`/socket/pipe (evento no epoll) ou `hrtimer_wakeup`
  (o prazo esgotou).
- **`primeiro_evento ... data=`** (variante B): o cookie do evento que acordou o
  epoll. O lançador lê o `fdinfo` do epoll na hora e grava a tabela
  `# epfd=N ...` com o descritor e o alvo de cada cookie (`anon_inode:[eventfd]`,
  `socket:[...]`, ...).
- **threads rodando durante a travada**: amostras a 99 Hz com pilha de usuário,
  thread e núcleo. A thread que gira aparece aqui.
- **chamadas de sistema das outras threads**: o número de cada syscall
  (`ausyscall NR` ou `/usr/include/asm/unistd_64.h` traduzem). Um spin puro não
  faz nenhuma.

## Custo e limites

- Fora das travadas, só as chamadas `futex`/`epoll` e as entradas e saídas de
  syscall da **thread principal** são seguidas, mais um filtro barato em
  `sched_waking` e nas amostras de perfil. O resto só grava durante uma travada.
- As bibliotecas do jogo vêm sem símbolos de depuração: as pilhas mostram
  biblioteca, deslocamento e as poucas funções exportadas (como `ThreadSpin`).
  Pilhas podem sair curtas onde o código não preserva o frame pointer.
- A amostragem em `profile:hz:99` fica de fora de travadas mais curtas que
  ~10 ms, o que não importa para limiares de centenas de ms.

## Arquivos

| Arquivo | Papel |
|---|---|
| `freeze-probe.sh` | lançador (bash, root): espera o processo, grava o cabeçalho, roda o bpftrace, traduz o epoll e encerra com o jogo |
| `freeze.bt` | o programa bpftrace |
| `<saída>.maps` | gerado na partida: trechos executáveis do processo (gravado a cada 30 s e a cada travada). No fim, o lançador usa esse mapa para trocar `0x... ([unknown])` nas pilhas por `biblioteca.so+0xdeslocamento` |

Testes: `tests/run-tests.sh probe` (bpftrace falso em `tests/mocks/bin/` e um
`/proc` falso; não precisa de root).
