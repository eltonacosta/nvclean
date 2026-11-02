# Changelog

Todas as mudanças relevantes do nvclean. O formato segue
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e o versionamento
usa [SemVer](https://semver.org/lang/pt-BR/).

## [1.2.0] — 2026-10-30

### Adicionado

- **Janela de Configurações** (`Configurações` no rodapé da janela):
  - *Iniciar junto com o sistema (só na bandeja)* — cria/remove
    `~/.config/autostart/nvclean.desktop`, com `Exec=` escapado e validado
    pelo GIO antes de publicar.
  - *Continuar em segundo plano ao fechar a janela* — quando desligado,
    fechar a janela encerra o app.
  - *Sair agora*.
- Preferências persistidas em `~/.config/nvclean/settings.json`.
- **Menu da bandeja** com *Cancelamento de ruído*, **Abrir**,
  **Configurações** e **Sair (fechar de vez)**.
- Bandeja via **StatusNotifierItem + DBusMenu** (Wayland/GNOME/KDE), com
  fallback para `Gtk.StatusIcon` em X11. `Gtk.StatusIcon` não aparece no
  Wayland, então o SNI é o caminho principal.
- Nova opção de linha de comando `NVCLEAN_REMEMBER=0` para aplicar
  intensidade sem alterar a preferência salva (usada pelos testes).
- `CHANGELOG.md`, `.gitignore` e `.gitattributes`.

### Corrigido

- **Knob do slider**: o `Gtk.Scale` nativo desalinhava o knob do cursor
  (erro de até meio knob, por causa de como o GTK calcula o *warp*). O slider
  de intensidade agora é um `Gtk.DrawingArea` próprio, com o centro do knob
  exatamente na posição do clique/drag (medido: erro ≤ 0,5 px).
- **Switch colorido**: `get_state()` ficava `False` mesmo com
  `get_active()` `True`, então o CSS `:checked` nunca aplicava. O estado é
  sincronizado explicitamente — verde ligado, cinza desligado.
- **Toggle concorrente**: dois cliques rápidos podiam concluir fora de ordem
  e deixar o servidor ligado com a interface mostrando desligado. Cada
  intenção recebe uma sequência; resultados obsoletos são descartados.
- **Status sem microfone**: `nvclean-control status --json` sai com código 3
  mas entrega JSON completo; o app descartava o payload e matava o caminho de
  reconexão justamente quando o microfone caía.
- **Intensidade apagada no `on`**: `on` forçava `1.0`. Agora restaura a
  intensidade salva; `on`/`off`/`toggle` não sobrescrevem a preferência.
- **Autostart com espaço no caminho**: `Exec=` sem aspas gerava um
  `.desktop` inválido (o GIO rejeita). Há escape e validação do executável.
- **App invisível no Wayland**: sem host de bandeja (GNOME sem a extensão
  AppIndicator), o app iniciado com `--hidden` ficava sem janela e sem ícone.
  Agora a janela abre com uma explicação.
- **Medidor**: a sentinela de prontidão era `0`, lida como `0 dBFS` (barra no
  máximo a cada reinício do stream); agora é `ready`. Falhas do `pw-cat`
  passam a ter backoff exponencial em vez de um processo por segundo.
- **Processo órfão**: o `pw-cat` do medidor é neto do app; agora o
  controlador e o `pw-cat` rodam em grupo próprio e são encerrados juntos
  (sem depender de SIGPIPE).
- **Instância única**: abrir o app de novo com ele escondido criava um
  segundo ícone; agora há lock por usuário e a segunda abertura traz a janela
  da instância viva.
- **Testes**: `tools/test-entrada.sh` não corrompe mais a intensidade salva
  (exit 3 com `pipefail`) e restaura a preferência mesmo em falha no meio.
- **Reconnect automático** não sobrescreve mais o microfone escolhido pelo
  usuário quando cai em um dispositivo de fallback.
- Erros de ação deixam de ser apagados ~100 ms depois pelo refresh de status.

### Notas

- Escopo inalterado: o app controla **somente** a entrada do microfone
  (`nvclean.input`/`nvclean`). A saída do sistema permanece intocada,
  verificado por `tools/check-output-untouched.py --verify`.

## [1.1.0] — 2026-10-30

- Interface refeita: cartões, medidor de nível, seletor de microfone e slider
  de intensidade.
- Desempenho: leitura de estado, troca de microfone e intensidade fora da
  thread do GTK; medidor com um único `pw-cat` contínuo.
- Correções de áudio da primeira revisão: `connect_mic` valida antes de
  destruir, `status`/`doctor` falham sem microfone, escala de dry em mono.

## [1.0.0] — 2026-10-30

- Primeira versão utilizável: plugin LADSPA de RNNoise, filter-chain do
  PipeWire, controlador, serviço de reconexão e AppImage.
