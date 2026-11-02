# nvclean (Noise Vocal Clean) — limpador de voz do microfone para Linux

O **NVIDIA Broadcast** nunca foi lançado para Linux. Foi por isso que este
projeto nasceu de engenharia reversa do instalador
`NVIDIA_Broadcast_v2.3.0.71988672.exe` — o mapa completo está em
[`docs/RELATORIO-LIMPADOR-DE-VOZ.md`](docs/RELATORIO-LIMPADOR-DE-VOZ.md).

O resultado é o oposto do original em dois pontos que importam:

- **roda no Linux**, onde o Broadcast não existe;
- **roda em qualquer CPU**, sem GPU NVIDIA e sem RTX — o Broadcast exige uma
  placa RTX para funcionar.

**Noise Vocal Clean** é o nome por extenso do projeto; **`nvclean`** é a forma
curta usada em tudo que é técnico (pacote, binários, serviço, nós do sistema).
Os dois são a mesma coisa e nada é renomeado.

## O que é

Um microfone virtual chamado **`nvclean`** que qualquer aplicativo enxerga como
um microfone comum. O áudio do seu microfone real passa por um denoiser neural
(RNNoise, 48 kHz) antes de chegar aos apps.

```
microfone real ──► nvclean.input (Audio/Sink) ──► RNNoise 48 kHz ──► nvclean (Audio/Source) ──► Discord/OBS/Zoom/navegador
```

## nvclean vs NVIDIA Broadcast

| | NVIDIA Broadcast | nvclean |
|---|---|---|
| **Onde roda** | Windows 10/11 | **Linux** |
| **Hardware** | **exige GPU RTX** | **qualquer CPU** |
| Modelo | TensorRT `.trtpkg` proprietário | RNNoise (rede neural aberta) |
| Taxa | 48 kHz mono | 48 kHz (estéreo, 2 instâncias) |
| Dispositivo virtual | driver `nvrtxaudcap64v.dll` | filter-chain do PipeWire |
| Controle | gateway MCP local | `nvclean-control` + GUI |
| Estúdio de voz / eco / câmera | sim | **não** (só remoção de ruído) |

O que foi copiado do Broadcast é o essencial: capturar o microfone, processar
com rede neural em 48 kHz e expor um microfone virtual que os apps usam — com
um interruptor para ligar/desligar o efeito.

## Escopo: só a ENTRADA

Este projeto processa **apenas o microfone**. A saída de áudio do sistema
(alto-falantes, fones) **não é tocada**: nenhum filtro, sink virtual ou ganho é
instalado no caminho de reprodução.

Isso é verificado por um teste que falha de verdade se algo mudar:

```bash
python3 tools/check-output-untouched.py --save    # grava a referência
python3 tools/check-output-untouched.py --verify  # falha se a saída mudou
```

## Requisitos e plataformas

**O nvclean roda apenas em Linux.** O filtro é um módulo do PipeWire, o serviço
usa `systemd --user` e a interface depende de GTK 3 e D-Bus.

### O que o sistema precisa ter

| Requisito | Obrigatório? | Para quê |
|---|---|---|
| **Linux** | sim | AppImage, `systemd --user`, caminhos XDG (`~/.config`, `~/.local`) |
| **PipeWire** | sim | o filtro é um `libpipewire-module-filter-chain`; o controle chama `pw-dump`, `pw-cli`, `pw-link` e `pw-cat`. PulseAudio puro ou JACK não servem |
| **systemd --user** | sim, na prática | o serviço `nvclean-reconnect` remantém o microfone linkado quando o PipeWire reinicia. Sem ele o microfone virtual fica mudo |
| **Python 3 + PyGObject + GTK 3** | sim | janela e ícone de bandeja |
| **x86_64** | sim para o AppImage publicado | o build fixa `ARCH=x86_64` |
| `libdbusmenu-glib` | recomendado | menu da bandeja no Wayland |
| `pactl` | opcional | descobrir o microfone padrão sem preferência salva |
| `root` | **não** | tudo é instalado em `~/.local` e `~/.config` |

**Sem GPU:** o processamento é do RNNoise em CPU. Não há dependência de
CUDA, TensorRT ou placa NVIDIA — o nome "nvclean" é só referência ao app que
ele substitui.

### Onde roda

| Sistema | Roda? |
|---|---|
| **Linux + PipeWire** (Arch, Debian, Ubuntu, Fedora…) | ✅ sim |
| **Wayland** e **X11** | ✅ sim |
| **GNOME sem a extensão AppIndicator** | ⚠️ sem ícone de bandeja (abre a janela) |
| **Linux ARM (aarch64)** | ❌ não publicado (compila do fonte) |
| **Windows**, **macOS**, **WSL** | ❌ não |

## Instalação

### Opção 1 — AppImage (recomendado, sem root)

```bash
chmod +x nvclean-1.2.0-x86_64.AppImage
./nvclean-1.2.0-x86_64.AppImage            # instala na primeira execução e abre a janela
./nvclean-1.2.0-x86_64.AppImage --install  # só instala
./nvclean-1.2.0-x86_64.AppImage --check    # diagnóstico
./nvclean-1.2.0-x86_64.AppImage --uninstall
```

O AppImage é autossuficiente em relação ao filtro: leva o plugin LADSPA e a
`librnnoise`. Do sistema ele usa **PipeWire** e **Python 3 + PyGObject + GTK 3**
(é a integração com o desktop, não faz sentido duplicar).

Na primeira execução ele copia o necessário para `~/.local` (o AppImage monta
em `/tmp/.mount_*`, que desaparece ao fechar — o filtro precisa de um caminho
permanente), instala o serviço `nvclean-reconnect` e conecta o microfone.

### Opção 2 — a partir do código

Dependências (Arch):

```bash
sudo pacman -S rnnoise gcc python-gobject gtk3 libdbusmenu-glib
```

Debian/Ubuntu:

```bash
sudo apt install librnnoise-dev build-essential python3-gi gir1.2-gtk-3.0 gir1.2-dbusmenu-0.4
```

```bash
./scripts/linux/setup-denoiser.sh
```

## Uso

```bash
nvclean-app                 # janela + ícone na bandeja
nvclean-app --hidden        # apenas bandeja (autostart)
nvclean-app --toggle        # alterna e sai (atalho de teclado)
```

Na janela, **Configurações** permite iniciar junto com o sistema (cria
`~/.config/autostart/nvclean.desktop`) e continuar em segundo plano ao fechar.
As preferências ficam em `~/.config/nvclean/settings.json`.

A bandeja usa **StatusNotifierItem + DBusMenu** (o padrão do GNOME/KDE no
Wayland) e cai para `Gtk.StatusIcon` só em X11 sem SNI. O menu tem
*Cancelamento de ruído*, **Abrir**, **Configurações** e **Sair**.

Linha de comando:

```bash
nvclean-control on          # liga o filtro (restaura a intensidade salva)
nvclean-control off         # desliga (bypass)
nvclean-control toggle
nvclean-control status      # estado + microfone + intensidade
nvclean-control intensity 0.6
nvclean-control mic         # lista microfones
nvclean-control mic <nome>  # troca o microfone de origem
nvclean-control reconnect   # refaz o link (automático pelo serviço)
nvclean-control doctor      # diagnóstico
```

`intensity 0.0` equivale a bypass. Nos apps, escolha o microfone **`nvclean`**;
o microfone físico continua disponível normalmente.

## Como funciona

- O filtro é um `libpipewire-module-filter-chain` (mesmo mecanismo do
  `source-rnnoise.conf` que acompanha o PipeWire).
- O nó virtual existe **sempre**; ligar/desligar alterna o parâmetro
  `rnnoise:Dry/Wet Mix` (`1.0` = filtro, `0.0` = bypass) ao vivo. Não reinicia
  o PipeWire e não derruba chamadas em andamento.
- Plugin LADSPA próprio (`src/ladspa/rnnoise_stereo.c`): duas instâncias do
  RNNoise, uma por canal, para não descartar metade do sinal de microfones
  estéreo. Latência de processamento: **10 ms** (1 frame de 480 amostras).
- O serviço `nvclean-reconnect` (systemd --user) refaz o link do microfone
  sempre que o PipeWire reinicia ou o dispositivo é reconectado.
- A interface não trava: estado, troca de microfone, toggle e intensidade
  rodam fora da thread do GTK, e o medidor usa um único `pw-cat` em streaming.

## Estrutura

```
app/nvclean-app                     janela GTK + ícone de bandeja
app/*.desktop                       atalho e autostart
scripts/linux/nvclean-control       controlador (on/off/status/mic/intensity)
scripts/linux/nvclean-reconnect     guardião do link do microfone
scripts/linux/setup-denoiser.sh     instalador a partir do código
config/pipewire/filter-chain-nvclean.conf
packaging/AppRun                    lógica de instalação do AppImage
packaging/build-appimage.sh         gera o AppImage
src/ladspa/rnnoise_stereo.c         plugin LADSPA (RNNoise estéreo 48 kHz)
src/ladspa/rnnoise_mono.c           variante mono
tools/test-ladspa.py                testa o plugin isolado
tools/test-entrada.sh               testa a entrada real: cru vs ON vs bypass
tools/check-output-untouched.py     prova que a saída não foi alterada
docs/RELATORIO-LIMPADOR-DE-VOZ.md   engenharia reversa do Broadcast
CHANGELOG.md                        histórico de versões
```

## Desempenho

Plugin isolado (`tools/test-ladspa.py`), voz + ruído rosa:

```
entrada : piso=-34.11 dBFS  fala=-14.21 dBFS  SNR=19.90 dB
saida   : piso=-49.41 dBFS  fala=-14.40 dBFS  SNR=35.01 dB
reducao :  15.30 dB   (mix=1.0)
```

Microfone real (HyperX QuadCast S), `tools/test-entrada.sh`:

```
mic cru      : piso=-44.54 dBFS  fala=-20.55 dBFS  SNR=23.99 dB
nvclean ON   : piso=-80.58 dBFS  fala=-46.98 dBFS  SNR=33.60 dB
nvclean OFF  : piso=-46.24 dBFS  fala=-22.37 dBFS  SNR=23.86 dB
```

O ruído cai, a voz é preservada e o nível não muda de forma perceptível.

## Desenvolvimento

O repositório contém **apenas as fontes**; `build/` e `dist/` são gerados e
ficam fora do git.

```bash
./packaging/build-appimage.sh --clean   # saída: dist/nvclean-<versão>-x86_64.AppImage
```

Requisitos de build: `gcc`, `librnnoise` e o header `ladspa.h` (o script baixa
o LADSPA SDK se não encontrar). O `appimagetool` é baixado automaticamente.
Se a distro não empacota `librnnoise` (Ubuntu LTS), compile do fonte:

```bash
git clone --depth 1 --branch v0.2 https://github.com/xiph/rnnoise.git
cd rnnoise && ./autogen.sh && ./configure --disable-examples --disable-doc
make -j"$(nproc)" && make install
RNNOISE_SO=/usr/local/lib/librnnoise.so.0 ./packaging/build-appimage.sh
```

O workflow [`.github/workflows/appimage.yml`](.github/workflows/appimage.yml)
gera o AppImage a cada push (artefato em **Actions → AppImage**) e, em tags
`v*`, cria a **Release** com o AppImage anexado.

Para lançar uma versão: atualize `VERSION` em `app/nvclean-app` e o
`CHANGELOG.md`, rode o build, valide com `tools/test-ladspa.py`,
`tools/test-entrada.sh` e `tools/check-output-untouched.py --verify`, e crie a
tag `v<versão>`. O CI publica o resto.

**Licença:** **GPL-3.0-or-later** (GNU General Public License v3.0 ou
posterior). Veja [`LICENSE`](LICENSE) para o texto completo. Copyright (C)
2026 eltonacosta.

Este programa é software livre: você pode redistribuí-lo e/ou modificá-lo sob
os termos da GPL, e ele é distribuído **sem qualquer garantia**. O AppImage
empacota a `librnnoise` (BSD-3-Clause): os avisos correspondentes estão em
[`THIRD-PARTY.md`](THIRD-PARTY.md).

## Problemas comuns

**"Filtro indisponível"** — rode `nvclean-control doctor`. Se o filtro estiver
instalado mas o PipeWire ainda não releu a config:
`systemctl --user restart pipewire`.

**Microfone virtual mudo** — o link com o microfone físico se perdeu. Rode
`nvclean-control reconnect` (o serviço normalmente faz sozinho). Verifique com
`nvclean-control status`.

**O app não lista meu microfone** — o dispositivo precisa estar visível no
PipeWire (`pactl list short sources`).

**Latência alta em jogos** — o filtro adiciona ~10 ms de processamento. Para
desligar sem perder o dispositivo virtual: `nvclean-control off`.
