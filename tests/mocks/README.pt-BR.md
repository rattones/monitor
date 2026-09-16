# Mocks

[English](README.md) · [Português](README.pt-BR.md)

Hardware falso para a suíte de testes. É o que permite os testes rodarem **numa
máquina sem GPU nenhuma** — e é a única forma de exercitar o backend Intel, já
que não há GPU Intel na máquina de desenvolvimento.

| Arquivo | Papel |
|---|---|
| `gpu-profiles.sh` | os dados de hardware que cada perfil reproduz |
| `bin/nvidia-smi` | finge `-L`, `--query-gpu` e `-q -d PIDS` |
| `bin/lspci` | a linha de classe PCI usada para nomear a placa |
| `make-sysfs.sh` | monta uma árvore `/sys/class/drm` falsa de um perfil |

## O ponto: quais arquivos existem, não só quais valores

Um mock que só troca números não testa nada interessante. O que importa aqui é
reproduzir **quais arquivos uma dada geração expõe** — porque é isso que
exercita o contrato *"métrica que o hardware não reporta vira célula vazia,
nunca zero"*.

Por isso o `amd_antiga` não cria `mem_busy_percent`, e o `intel_antiga` não cria
`lmem_*`. A ausência é o teste.

## Perfis

Dois por fabricante. O antigo é o que importa.

| Perfil | Hardware | O que exercita |
|---|---|---|
| `nvidia_moderna` | RTX 4070, 12 GiB | tudo reportado |
| `nvidia_antiga` | **GTX 1050**, 2 GiB | `power.draw` = `[N/A]` → célula vazia |
| `amd_moderna` | RX 7800 XT, 16 GiB | `mem_busy_percent` e `power1_input` presentes |
| `amd_antiga` | RX 560 (Polaris), 4 GiB | sem `mem_busy_percent`; usa `power1_average` |
| `intel_moderna` | Arc A770, 16 GiB | dedicada: tem `lmem_*` |
| `intel_antiga` | HD 630 (integrada) | sem `lmem_*` → `vram_*` vazias |

O que cada geração deixa de reportar não é invenção — é o que aquele hardware de
fato não expõe. A divisão entre `power1_average` e `power1_input` é real: a Vega
da máquina de desenvolvimento expõe `power1_input` onde a documentação dizia
`power1_average`, e é por isso que o backend procura os dois.

Os valores estão em unidades de sysfs — VRAM em bytes, temperatura em milésimos
de grau, potência em microwatts, clocks em Hz. Converter é trabalho do backend, e
conferir essa conversão é trabalho do teste.

## Variáveis

| Variável | Efeito |
|---|---|
| `MOCK_DIR` | onde os mocks ficam (a suíte exporta) |
| `MOCK_PROFILE` | qual perfil de hardware usar |
| `MOCK_SAMPLES` | quantas amostras o fluxo emite (`0` = até ser morto) |
| `MOCK_FAIL` | `driver` (driver mudo, sai com 9) ou `nodevice` |
| `MONITOR_DRM_ROOT` | raiz do sysfs que os backends AMD/Intel leem |

`MONITOR_DRM_ROOT` é o ponto de injeção que torna os backends de sysfs
testáveis. Está definido em `lib/backend.sh` e aponta para `/sys/class/drm` por
padrão.

## Rodando um mock à mão

Útil quando um teste falha e você quer ver o que o backend de fato recebeu:

```bash
export MOCK_DIR=tests/mocks

# O que o nvidia-smi devolve para uma placa antiga
MOCK_PROFILE=nvidia_antiga tests/mocks/bin/nvidia-smi \
  --query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.total,\
memory.used,memory.free,temperature.gpu,power.draw,clocks.sm,clocks.mem \
  --format=csv,noheader,nounits

# Monta um sysfs falso e aponta o backend para ele
tests/mocks/make-sysfs.sh /tmp/fakesys amd_antiga
MONITOR_DRM_ROOT=/tmp/fakesys/class/drm ./monitor.sh gpu -b amd -d 2

# O mesmo para Intel, que não tem hardware real aqui
tests/mocks/make-sysfs.sh /tmp/fakeintel intel_moderna
MONITOR_DRM_ROOT=/tmp/fakeintel/class/drm ./monitor.sh gpu -b intel -d 2
```

## Adicionando um perfil

1. Adicione uma função `profile_<nome>()` ao `gpu-profiles.sh`, exportando as
   mesmas variáveis das irmãs.
2. Se for AMD ou Intel, garanta que o `make-sysfs.sh` crie **apenas** os
   arquivos que aquela geração realmente tem — omitir um arquivo é como se testa
   a célula vazia.
3. Adicione as asserções ao `run-tests.sh`, incluindo o que deve sair **vazio**.

Depois quebre o backend de propósito e confirme que o teste novo falha. Um teste
que passa tanto com o código certo quanto com o errado não está medindo nada.

## Fidelidade

O mock do `nvidia-smi` reproduz o formato de saída do binário real, capturado de
uma RTX 3050 — incluindo o bloco indentado do `-q -d PIDS` e o `[N/A]` que
placas sem sensor de potência devolvem. Se o formato da ferramenta real mudar,
este mock precisa mudar junto, ou os testes passarão contra um formato que não
existe mais.

O mock do `lspci` devolve uma linha com a classe `VGA compatible controller`,
porque os backends filtram por ela antes de confiar no nome. Esse filtro existe
por um motivo: sem ele, um slot apontando para outra coisa daria a uma GPU o
nome de uma placa de rede, silenciosamente.
