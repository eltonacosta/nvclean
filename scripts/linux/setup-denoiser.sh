#!/bin/bash
# ============================================================================
# setup-denoiser.sh — instala o filtro de ruído de ENTRADA (microfone) no Linux.
#
# O que faz (idempotente — pode rodar de novo sem duplicar nada):
#   1. compila e instala o plugin LADSPA do RNNoise em ~/.local/lib/ladspa
#   2. instala o filter-chain em ~/.config/pipewire/pipewire.conf.d
#   3. instala nvclean-control e nvclean-app em ~/.local/bin
#   4. reinicia o pipewire só para carregar o filtro
#   5. conecta o microfone atual e mostra o diagnóstico
#
# O que NÃO faz: não toca na saída de áudio do sistema (nenhum filtro, sink
# virtual ou ganho é instalado no caminho de reprodução), não instala pacotes
# com sudo.
#
# Requisitos: pipewire, rnnoise (headers), gcc.
#   Arch:   sudo pacman -S rnnoise gcc python-gobject gtk3
#   Debian: sudo apt install librnnoise-dev build-essential python3-gi gir1.2-gtk-3.0
#
# Uso: ./scripts/linux/setup-denoiser.sh [--yes]
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$HERE/src/ladspa/rnnoise_stereo.c"
CONF_SRC="$HERE/config/pipewire/filter-chain-nvclean.conf"

LADSPA_DIR="$HOME/.local/lib/ladspa"
BIN_DIR="$HOME/.local/bin"
PW_CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF_DST="$PW_CONF_DIR/60-nvclean.conf"
PLUGIN_DST="$LADSPA_DIR/nvclean_rnnoise_stereo.so"

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

say()  { printf '\n\033[1;32m==\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mx\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
  [ "$ASSUME_YES" = "1" ] && return 0
  # Sem terminal (pipe, cron, CI) NUNCA assume "sim": reiniciar o PipeWire
  # derruba o áudio por alguns segundos. Só age com confirmação explícita.
  [ -t 0 ] || return 1
  read -r -p "$1 [s/N] " ans
  case "${ans:-n}" in [sSyY]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
say "1/6 — verificando dependências"
# ---------------------------------------------------------------------------
command -v pw-dump  >/dev/null || die "pipewire não encontrado (pw-dump)"
command -v pw-cli   >/dev/null || die "pipewire não encontrado (pw-cli)"
command -v pw-link  >/dev/null || die "pipewire não encontrado (pw-link)"
command -v gcc      >/dev/null || die "gcc não encontrado (instale build-essential/gcc)"
[ -f "$SRC" ] || die "fonte do plugin não encontrada: $SRC"
[ -f "$CONF_SRC" ] || die "config do filter-chain não encontrada: $CONF_SRC"

RNNOISE_INC=""
for p in /usr/include /usr/local/include "$HOME/.local/include"; do
  [ -f "$p/rnnoise.h" ] && RNNOISE_INC="$p" && break
done
[ -n "$RNNOISE_INC" ] || die "rnnoise.h não encontrado. Arch: sudo pacman -S rnnoise | Debian: sudo apt install librnnoise-dev"

RNNOISE_LIB=""
for p in /usr/lib /usr/lib64 /usr/local/lib "$HOME/.local/lib"; do
  ls "$p"/librnnoise.so* >/dev/null 2>&1 && RNNOISE_LIB="$p" && break
done
[ -n "$RNNOISE_LIB" ] || die "librnnoise não encontrada"

# header LADSPA: usa o do sistema se existir, senão baixa o oficial uma vez
LADSPA_HDR=""
for p in /usr/include /usr/local/include /usr/include/ladspa "$HOME/.cache/nvclean"; do
  [ -f "$p/ladspa.h" ] && LADSPA_HDR="$p" && break
done
if [ -z "$LADSPA_HDR" ]; then
  say "1b — header LADSPA não encontrado; baixando o oficial"
  CACHE="$HOME/.cache/nvclean"
  mkdir -p "$CACHE"
  if [ ! -f "$CACHE/ladspa.h" ]; then
    curl -fsSL -o "$CACHE/ladspa.tgz" https://www.ladspa.org/download/ladspa_sdk_1.17.tgz \
      || die "não foi possível baixar o LADSPA SDK; instale ladspa-sdk pelo gerenciador"
    tar xzf "$CACHE/ladspa.tgz" -C "$CACHE"
    # o tarball extrai em ladspa_sdk_<versão>/src/ladspa.h
    found="$(find "$CACHE" -name ladspa.h -print -quit)"
    [ -n "$found" ] || die "ladspa.h não encontrado após extrair o SDK"
    cp "$found" "$CACHE/ladspa.h"
  fi
  LADSPA_HDR="$CACHE"
fi
echo "  rnnoise: $RNNOISE_INC   ladspa.h: $LADSPA_HDR"

# ---------------------------------------------------------------------------
say "2/6 — compilando o plugin LADSPA (RNNoise, 48 kHz, estéreo)"
# ---------------------------------------------------------------------------
mkdir -p "$LADSPA_DIR" "$BIN_DIR" "$PW_CONF_DIR"

TMP_SO="$(mktemp -u "$LADSPA_DIR/.nvclean.XXXXXX.so")"
gcc -O2 -fPIC -shared -Wall -Wextra \
  -I"$LADSPA_HDR" -I"$RNNOISE_INC" \
  -o "$TMP_SO" "$SRC" -L"$RNNOISE_LIB" -lrnnoise \
  || die "falha ao compilar o plugin"
mv -f "$TMP_SO" "$PLUGIN_DST"
echo "  instalado: $PLUGIN_DST"

# ---------------------------------------------------------------------------
say "3/6 — instalando o filter-chain do PipeWire"
# ---------------------------------------------------------------------------
if [ -f "$CONF_DST" ] && ! grep -q "nvclean" "$CONF_DST"; then
  cp "$CONF_DST" "$CONF_DST.bak.$(date +%s)"
  warn "config existente sem 'nvclean' foi salva como backup"
fi
sed "s|@PLUGIN_PATH@|$PLUGIN_DST|" "$CONF_SRC" > "$CONF_DST"
echo "  instalado: $CONF_DST"

# ---------------------------------------------------------------------------
say "4/6 — instalando controlador e app"
# ---------------------------------------------------------------------------
install -m755 "$HERE/scripts/linux/nvclean-control" "$BIN_DIR/nvclean-control"
install -m755 "$HERE/scripts/linux/nvclean-reconnect" "$BIN_DIR/nvclean-reconnect"
install -m755 "$HERE/app/nvclean-app" "$BIN_DIR/nvclean-app"
echo "  $BIN_DIR/nvclean-control"
echo "  $BIN_DIR/nvclean-app"

# atalho no menu de aplicativos.
# O ícone precisa existir no tema: Icon=nvclean só resolve se
# nvclean.png estiver em hicolor/<tamanho>/apps. Sem isso o menu e a barra
# de apps abertos caem no ícone genérico.
APPS_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$APPS_DIR" "$ICON_DIR"
install -m644 "$HERE/packaging/nvclean.png" "$ICON_DIR/nvclean.png"
install -m644 "$HERE/app/nvclean.desktop" "$APPS_DIR/nvclean.desktop"
# atualiza o cache de ícones quando a ferramenta existe (não é obrigatória:
# o GTK também procura no diretório hicolor diretamente)
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  gtk-update-icon-cache -q -t -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
echo "  $ICON_DIR/nvclean.png"
echo "  $APPS_DIR/nvclean.desktop"

# serviço que mantém o microfone ligado após reiniciar o PipeWire
if [ -f "$HERE/packaging/nvclean-reconnect.service" ]; then
  mkdir -p "$HOME/.config/systemd/user"
  install -m644 "$HERE/packaging/nvclean-reconnect.service" \
    "$HOME/.config/systemd/user/nvclean-reconnect.service"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now nvclean-reconnect >/dev/null 2>&1 || true
  echo "  serviço nvclean-reconnect habilitado"
fi

# autostart opcional: sobe só na bandeja ao entrar na sessão
AUTOSTART_DIR="$HOME/.config/autostart"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR não está no PATH."
    warn "Adicione ao seu shell:  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

# ---------------------------------------------------------------------------
say "5/6 — recarregando o PipeWire (só para carregar o filter-chain)"
# ---------------------------------------------------------------------------
if ask "Reiniciar o PipeWire agora? O áudio pausa por ~2s."; then
  systemctl --user restart pipewire 2>/dev/null \
    || warn "não foi possível reiniciar via systemd; reinicie a sessão depois"
  sleep 3
else
  warn "filtro só aparece depois de reiniciar o PipeWire/sessão"
fi

# ---------------------------------------------------------------------------
say "6/6 — conectando o microfone e diagnosticando"
# ---------------------------------------------------------------------------
CONTROL="$BIN_DIR/nvclean-control"

# escolhe o microfone (salvo, padrão do sistema, ou o primeiro que funcionar)
DEFAULT_MIC="$(pactl get-default-source 2>/dev/null || true)"
candidates=()
saved_mic="$(cat "$HOME/.config/nvclean/mic" 2>/dev/null || true)"
[ -n "$saved_mic" ] && candidates+=("$saved_mic")
[ -n "$DEFAULT_MIC" ] && candidates+=("$DEFAULT_MIC")
while IFS=$'\t' read -r name _desc; do
  name="${name#\* }"; name="${name# }"; name="${name#  }"
  [ -n "$name" ] || continue
  candidates+=("$name")
done < <("$CONTROL" mics 2>/dev/null || true)

connected=""
for mic in "${candidates[@]}"; do
  if "$CONTROL" mic "$mic" >/dev/null 2>&1; then
    connected="$mic"
    break
  fi
done

if [ -n "$connected" ]; then
  say "microfone conectado: $connected"
  "$CONTROL" on >/dev/null || true
else
  warn "nenhum microfone pôde ser conectado automaticamente."
  warn "Use: nvclean-control mic <nome>   (lista: nvclean-control mic)"
fi

# diagnóstico final — agora com o microfone já conectado
if ! "$CONTROL" doctor; then
  warn "o diagnóstico encontrou problemas (veja acima)."
  exit 1
fi

# autostart opcional (por último, para não consumir a resposta das perguntas
# anteriores quando a entrada não é interativa)
if [ "$ASSUME_YES" = "1" ] || ask "Iniciar o nvclean junto com a sessão (só na bandeja)?"; then
  mkdir -p "$AUTOSTART_DIR"
  install -m644 "$HERE/app/nvclean-autostart.desktop" "$AUTOSTART_DIR/nvclean.desktop"
  echo "  $AUTOSTART_DIR/nvclean.desktop"
fi

cat <<'EOF'

Pronto.

  nvclean-app                abre a janela (com ícone na bandeja)
  nvclean-control on|off     liga/desliga o filtro
  nvclean-control status     mostra o estado
  nvclean-control mic        lista/troca o microfone

Nos apps (Discord, OBS, navegador, Zoom) escolha o microfone "nvclean".
O microfone físico continua disponível normalmente; a saída de áudio do
sistema não é alterada.
EOF
