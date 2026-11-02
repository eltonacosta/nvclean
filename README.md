# nvclean (Noise Vocal Clean) — limpador de voz do microfone para Linux

Equivalente Linux do **NVIDIA Broadcast** "Noise removal" (remoção de ruído do
microfone). Nasceu de engenharia reversa do instalador
`NVIDIA_Broadcast_v2.3.0.71988672.exe` — o mapa completo está em
[`docs/RELATORIO-LIMPADOR-DE-VOZ.md`](docs/RELATORIO-LIMPADOR-DE-VOZ.md).

## Nome

**Noise Vocal Clean** é o nome por extenso do projeto; **`nvclean`** é a forma
curta usada no dia a dia e em tudo que é técnico. Os dois se referem à mesma
coisa.

| Uso | Nome |
|---|---|
| Nome por extenso (por baixo dos panos) | **Noise Vocal Clean** |
| Nome curto, para conversa e documentação | `nvclean` |
| Pacote, binários, serviço, arquivos e nós do sistema | `nvclean` (inalterado) |

"Por baixo dos panos" vale no sentido de identidade do projeto: o nome por
extenso documenta o que ele é, mas **nada é renomeado**. Continuam exatamente
como estão:

- pacote `nvclean-<versão>-x86_64.AppImage`;
- binários `nvclean-app`, `nvclean-control` e `nvclean-reconnect`;
- serviço `nvclean-reconnect.service`;
- configuração `60-nvclean.conf` e plugin `nvclean_rnnoise_stereo.so`;
- nós do PipeWire **`nvclean`** (microfone virtual) e `nvclean.input` (entrada);
- diretório `~/.config/nvclean/` e o atalho `nvclean.desktop`.

Ou seja: **Noise Vocal Clean** é o nome; **`nvclean`** é como o projeto e o
microfone aparecem no sistema.

## O que é

Um microfone virtual chamado **`nvclean`** que qualquer aplicativo enxerga como
um microfone comum. O áudio do seu microfone real passa por um denoiser neural
(RNNoise, 48 kHz) antes de chegar aos apps.

```
microfone real ──► nvclean.input (Audio/Sink) ──► RNNoise 48 kHz ──► nvclean (Audio/Source) ──► Discord/OBS/Zoom/navegador
```

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

**O nvclean roda apenas em Linux.** Não é um app multiplataforma e não há
plano de port: o filtro é um módulo do PipeWire, o serviço usa `systemd --user`
e a interface depende de GTK 3 e D-Bus. Para Windows existe o NVIDIA Broadcast
original — o nvclean existe justamente para cobrir essa lacuna no Linux.

### O que o sistema precisa ter

| Requisito | Obrigatório? | Para quê |
|---|---|---|
| **Linux** | sim | AppImage, `systemd --user`, caminhos XDG (`~/.config`, `~/.local`) |
| **PipeWire** | sim | o filtro é um `libpipewire-module-filter-chain`; o controle chama `pw-dump`, `pw-cli`, `pw-link` e `pw-cat`. PulseAudio puro ou JACK não servem |
| **systemd --user** | sim, na prática | o serviço `nvclean-reconnect` remantém o microfone linkado quando o PipeWire reinicia ou o dispositivo é reconectado. O filtro até carrega sem ele, mas a reconexão automática não existe e o microfone virtual fica mudo |
| **Python 3 + PyGObject + GTK 3** | sim | janela e ícone de bandeja (`gi.require_version("Gtk", "3.0")`) |
| **x86_64** | sim para o AppImage publicado | o build fixa `ARCH=x86_64` e baixa o `appimagetool-x86_64` |
| `libdbusmenu-glib` (typelib `Dbusmenu-0.4`) | recomendado | menu da bandeja no Wayland. Sem ele o app abre a janela e avisa, mas não tem ícone nem menu |
| `pactl` | opcional | só para descobrir o microfone padrão quando não há preferência salva |
| `root` | **não** | tudo é instalado em `~/.local` e `~/.config` |

### Onde roda

| Sistema | Roda? | Observação |
|---|---|---|
| **Linux + PipeWire** (Arch, Debian, Ubuntu, Fedora…) | ✅ sim | único alvo suportado. As instruções de instalação cobrem Arch e Debian/Ubuntu |
| **Wayland** | ✅ sim | a bandeja usa StatusNotifierItem + DBusMenu |
| **X11** | ✅ sim | mesma bandeja SNI; `Gtk.StatusIcon` só como fallback quando não há SNI |
| **GNOME sem a extensão AppIndicator** | ⚠️ parcial | não há host de bandeja: o app abre a janela com um aviso em vez de ficar invisível |
| **Linux ARM (aarch64)** | ❌ não publicado | o plugin C e o restante compilam em tese, mas o build oficial é só x86_64; exigiria compilar do fonte |
| **Windows** | ❌ não | use o NVIDIA Broadcast original |
| **macOS** | ❌ não | não há backend CoreAudio/AudioServerPlugIn |
| **WSL** | ❌ não na prática | o WSLg expõe áudio via PulseAudio, não PipeWire |

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

`libdbusmenu-glib` é o que permite o ícone de bandeja no Wayland/GNOME
(StatusNotifierItem). Sem ele o app abre a janela e avisa, mas não tem ícone
nem menu na bandeja.

```bash
./scripts/linux/setup-denoiser.sh
```

## Uso

```bash
nvclean-app                 # janela + ícone na bandeja
nvclean-app --hidden        # apenas bandeja (autostart)
nvclean-app --toggle        # alterna e sai (atalho de teclado)
```

Na janela, **Configurações** permite:

- **Iniciar junto com o sistema** — cria/remove
  `~/.config/autostart/nvclean.desktop` (sobe só na bandeja).
- **Continuar em segundo plano ao fechar a janela** — desligado, fechar a
  janela encerra o app (e o processo `pw-cat` do medidor).

As preferências ficam em `~/.config/nvclean/settings.json`.

A bandeja usa **StatusNotifierItem + DBusMenu** (o padrão do GNOME/KDE no
Wayland) e cai para `Gtk.StatusIcon` só em X11 sem SNI. O menu tem
*Cancelamento de ruído*, **Abrir**, **Configurações** e
**Sair (fechar de vez)**; um clique no ícone abre a janela, e no fallback X11
o duplo clique também abre.

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

`intensity 0.0` equivale a bypass (o filtro fica desligado de fato).

Nos apps, escolha o microfone **`nvclean`**. O microfone físico continua
disponível normalmente.

## Como funciona

- O filtro é um `libpipewire-module-filter-chain` (mesmo mecanismo do
  `source-rnnoise.conf` que acompanha o PipeWire).
- O nó virtual existe **sempre**; ligar/desligar alterna o parâmetro
  `rnnoise:Dry/Wet Mix` (`1.0` = filtro, `0.0` = bypass) ao vivo. Não reinicia
  o PipeWire e não derruba chamadas em andamento.
- Plugin LADSPA próprio (`src/ladspa/rnnoise_stereo.c`): duas instâncias do
  RNNoise, uma por canal, para não descartar metade do sinal de microfones
  estéreo. Latência de processamento: 1 frame = 480 amostras = **10 ms**
  (o total percebido inclui mais um buffer do PipeWire).
- O serviço `nvclean-reconnect` (systemd --user) refaz o link do microfone
  sempre que o PipeWire reinicia ou o dispositivo é reconectado — sem ele o
  microfone virtual ficaria mudo.

### Desempenho da interface

Nada roda na thread do GTK: leitura de estado, troca de microfone, toggle e
intensidade vão para threads de trabalho. O medidor usa **um único `pw-cat`
em streaming** (~20 leituras/s) em vez de criar um processo por amostra, e o
slider faz *debounce* de 120 ms.

Medido com um heartbeat de 60 Hz enquanto o slider e o switch são martelados:

| | antes | depois |
|---|---|---|
| mediana do loop | 16,1 ms | 16,1 ms |
| p95 | **10.540 ms** | **16,2 ms** |
| pior travamento | 10,7 s | 120 ms |

O congelamento de segundos vinha do `status` esperando até 6 s pela reconexão
do microfone; agora essa espera é opcional (`status --wait`).

## Medições reais

Plugin isolado (`tools/test-ladspa.py`), voz + ruído rosa:

```
entrada : piso=-34.11 dBFS  fala=-14.21 dBFS  SNR=19.90 dB
saida   : piso=-49.41 dBFS  fala=-14.40 dBFS  SNR=35.01 dB
reducao :  15.30 dB   (mix=1.0)
```

Pipeline completo no PipeWire, A/B com o mesmo áudio:

```
FILTRO ON : piso=-50.51 dBFS  fala=-16.77 dBFS  SNR=33.74  rms=0.06760
BYPASS    : piso=-36.86 dBFS  fala=-16.66 dBFS  SNR=20.20  rms=0.07149
=> reducao de piso: 13.7 dB | ganho de SNR: 13.5 dB | variacao de nivel: -0.49 dB
```

Microfone real (HyperX QuadCast S), `tools/test-entrada.sh`:

```
mic cru      : piso=-44.54 dBFS  fala=-20.55 dBFS  SNR=23.99 dB
nvclean ON   : piso=-80.58 dBFS  fala=-46.98 dBFS  SNR=33.60 dB
nvclean OFF  : piso=-46.24 dBFS  fala=-22.37 dBFS  SNR=23.86 dB
```

O ruído cai, a voz é preservada e o nível não muda de forma perceptível.

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
packaging/nvclean.svg/.png          ícone
src/ladspa/rnnoise_stereo.c         plugin LADSPA (RNNoise estéreo 48 kHz)
src/ladspa/rnnoise_mono.c           variante mono
tools/test-ladspa.py                testa o plugin isolado
tools/test-entrada.sh               testa a entrada real: cru vs ON vs bypass
tools/check-output-untouched.py     prova que a saída não foi alterada
docs/RELATORIO-LIMPADOR-DE-VOZ.md   engenharia reversa do Broadcast
CHANGELOG.md                        histórico de versões
.gitignore / .gitattributes         controle de artefatos e finais de linha
```

## Gerar o AppImage

```bash
./packaging/build-appimage.sh          # ou --clean para rebuild total
# saída: dist/nvclean-<versão>-x86_64.AppImage
```

Requisitos de build: `gcc`, `librnnoise` e o header `ladspa.h` (o script baixa
o LADSPA SDK oficial se não encontrar no sistema). O `appimagetool` é baixado
automaticamente em `~/.local/opt/nvclean-build`.

Se a sua distro não empacota `librnnoise` (é o caso do Ubuntu LTS), compile
do fonte e aponte o caminho:

```bash
git clone --depth 1 --branch v0.2 https://github.com/xiph/rnnoise.git
cd rnnoise && ./autogen.sh && ./configure --disable-examples --disable-doc
make -j"$(nproc)" && make install     # gera librnnoise.so.0
RNNOISE_SO=/usr/local/lib/librnnoise.so.0 ./packaging/build-appimage.sh
```

## CI — artefato a cada push

O workflow [`.github/workflows/appimage.yml`](.github/workflows/appimage.yml)
roda a cada push (e em pull requests / manualmente) e:

1. instala as dependências de build no Ubuntu do runner;
2. compila o **RNNoise `v0.2`** do fonte (o Ubuntu LTS não tem
   `librnnoise-dev`; a tag fixa também mantém o AppImage em ~2 MB);
3. gera o AppImage com `packaging/build-appimage.sh --clean`;
4. confere o conteúdo do pacote e guarda como artefato do run;
5. em **tags `v*`**, cria/atualiza uma **Release** com o AppImage anexado.

Para baixar o artefato: aba **Actions** → run do workflow `AppImage` →
seção **Artifacts** → `nvclean-appimage`. O arquivo fica disponível por 30
dias.

## Desenvolvimento e publicação

O repositório contém **apenas as fontes**. `build/` e `dist/` são artefatos
gerados e ficam fora do git (veja `.gitignore`).

```bash
git clone <url> nvclean && cd nvclean
./packaging/build-appimage.sh --clean   # build reproduzível
./dist/nvclean-<versão>-x86_64.AppImage --check
```

Fluxo de versão:

1. Atualize `VERSION` em `app/nvclean-app` (o build lê daqui) e o
   `CHANGELOG.md`.
2. `./packaging/build-appimage.sh --clean`
3. Valide: `tools/test-ladspa.py`, `tools/test-entrada.sh` (com o microfone
   real) e `tools/check-output-untouched.py --verify`.
4. `git tag -a v<versão> -m "nvclean <versão>"` e publique.
5. **O AppImage vai em GitHub Releases** (anexo da tag), não no histórico do
   git: é um binário de 2,2 MB, reproduzível pelo script.

Para publicar no GitHub:

```bash
git remote add origin git@github.com:<usuário>/nvclean.git
git push -u origin main --tags
```

Depois de dar push, o workflow já publica o artefato do run. Em tags `v*` ele
também cria a Release e anexa o AppImage automaticamente — não é preciso
anexar à mão. Se preferir publicar localmente:

```bash
gh release create v1.2.0 dist/nvclean-1.2.0-x86_64.AppImage --generate-notes
```

**Licença:** ainda não definida pelo autor. Antes de tornar o repositório
público, adicione um arquivo `LICENSE` (por exemplo MIT, GPL-3.0 ou
Apache-2.0) — o código é original, mas o projeto usa `librnnoise` (BSD) em
tempo de execução.

## O que é igual e o que é diferente do NVIDIA Broadcast

| | NVIDIA Broadcast | nvclean |
|---|---|---|
| Onde roda | Windows 10/11 + GPU RTX | Linux + PipeWire (único alvo suportado) |
| Modelo | TensorRT `.trtpkg` proprietário | RNNoise (rede neural aberta) |
| Taxa | 48 kHz mono | 48 kHz (estéreo, 2 instâncias) |
| Dispositivo virtual | driver `nvrtxaudcap64v.dll` | filter-chain do PipeWire |
| Controle | gateway MCP local | `nvclean-control` + GUI |
| Estúdio de voz / eco / câmera | sim | **não** (só remoção de ruído) |
| Custo | GPU NVIDIA | CPU (leve) |

O desenho copiado do Broadcast é o essencial: capturar o microfone, processar
com rede neural em 48 kHz e expor um microfone virtual que os apps usam — com
um interruptor para ligar/desligar o efeito.

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
