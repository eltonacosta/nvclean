#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 eltonacosta
# ============================================================================
# build-appimage.sh — gera o AppImage do nvclean.
#
# O AppImage é autossuficiente no que dá para ser:
#   • plugin LADSPA + librnnoise empacotados (não depende da versão do sistema)
#   • controlador, GUI, config e ícone dentro do AppDir
#   • PipeWire, Python 3, PyGObject e GTK 3 vêm do sistema (são a integração)
#
# Saída: dist/nvclean-<versão>-x86_64.AppImage
#
# Uso: ./packaging/build-appimage.sh [--clean]
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${NVCLEAN_VERSION:-$(python3 - <<'PY'
import re, pathlib
p = pathlib.Path("app/nvclean-app")
text = p.read_text(encoding="utf-8")
m = re.search(r'^VERSION\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else "0.1.0")
PY
)}"

BUILD="$HERE/build"
APPDIR="$BUILD/AppDir"
DIST="$HERE/dist"
TOOL="${APPIMAGETOOL:-$HOME/.local/opt/nvclean-build/appimagetool}"

say()  { printf '\n\033[1;32m==\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mx\033[0m %s\n' "$*" >&2; exit 1; }

[ "${1:-}" = "--clean" ] && { rm -rf "$BUILD"; echo "build limpo"; }

command -v gcc >/dev/null || die "gcc não encontrado"

# RNNOISE_SO permite ao CI apontar para uma lib compilada do fonte (o Ubuntu
# LTS dos runners não empacota librnnoise-dev). Sem a variável, o
# comportamento local continua igual: procura nos caminhos do sistema.
RNNOISE_SO="${RNNOISE_SO:-}"

# header LADSPA (mesma lógica do setup-denoiser.sh)
LADSPA_HDR=""
for p in /usr/include /usr/local/include /usr/include/ladspa "$HOME/.cache/nvclean"; do
  [ -f "$p/ladspa.h" ] && LADSPA_HDR="$p" && break
done
if [ -z "$LADSPA_HDR" ]; then
  CACHE="$HOME/.cache/nvclean"; mkdir -p "$CACHE"
  [ -f "$CACHE/ladspa.tgz" ] || curl -fsSL -o "$CACHE/ladspa.tgz" \
    https://www.ladspa.org/download/ladspa_sdk_1.17.tgz
  tar xzf "$CACHE/ladspa.tgz" -C "$CACHE"
  found="$(find "$CACHE" -name ladspa.h -print -quit)"
  [ -n "$found" ] || die "ladspa.h não encontrado"
  cp "$found" "$CACHE/ladspa.h"; LADSPA_HDR="$CACHE"
fi

# header do RNNoise. O plugin inclui <rnnoise.h>; quando a lib vem de um build
# do fonte (RNNOISE_SO=...), o header está no prefixo do build, mas não no
# caminho padrão do compilador. RNNOISE_INCLUDE aponta para ele.
RNNOISE_HDR="${RNNOISE_INCLUDE:-}"
if [ -z "$RNNOISE_HDR" ] && [ -n "$RNNOISE_SO" ]; then
  for candidate in "$(dirname "$RNNOISE_SO")/../include" "$(dirname "$RNNOISE_SO")"; do
    [ -f "$candidate/rnnoise.h" ] && RNNOISE_HDR="$candidate" && break
  done
fi
if [ -z "$RNNOISE_HDR" ]; then
  for p in /usr/include /usr/local/include "$HOME/.local/include"; do
    [ -f "$p/rnnoise.h" ] && RNNOISE_HDR="$p" && break
  done
fi
[ -n "$RNNOISE_HDR" ] || die "rnnoise.h não encontrado (Arch: pacman -S rnnoise | Debian: compile o RNNoise do fonte e defina RNNOISE_INCLUDE=/caminho/include)"

# librnnoise: usa a do sistema e copia para dentro do AppImage.
if [ -n "$RNNOISE_SO" ]; then
  [ -r "$RNNOISE_SO" ] || die "RNNOISE_SO aponta para arquivo ilegível: $RNNOISE_SO"
  RNNOISE_SO="$(readlink -f "$RNNOISE_SO")"
else
  for p in /usr/lib /usr/lib64 /usr/local/lib "$HOME/.local/lib"; do
    for f in "$p"/librnnoise.so.0 "$p"/librnnoise.so; do
      [ -e "$f" ] && RNNOISE_SO="$(readlink -f "$f")" && break 2
    done
  done
fi
[ -n "$RNNOISE_SO" ] || die "librnnoise não encontrada (Arch: pacman -S rnnoise | Debian: apt install librnnoise0). Para compilar do fonte, defina RNNOISE_SO=/caminho/librnnoise.so.0"

say "nvclean $VERSION — montando AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"/usr/{bin,lib/nvclean,share/nvclean,share/applications,share/icons/hicolor/256x256/apps}

# --- plugin LADSPA, ligado à librnnoise empacotada -------------------------
say "compilando o plugin LADSPA"
mkdir -p "$APPDIR/usr/lib"
cp "$RNNOISE_SO" "$APPDIR/usr/lib/librnnoise.so.0"
ln -sf librnnoise.so.0 "$APPDIR/usr/lib/librnnoise.so"

gcc -O2 -fPIC -shared -Wall -Wextra \
  -I"$LADSPA_HDR" -I"$RNNOISE_HDR" -I/usr/include \
  -o "$APPDIR/usr/lib/nvclean/nvclean_rnnoise_stereo.so" \
  "$HERE/src/ladspa/rnnoise_stereo.c" \
  -L"$APPDIR/usr/lib" -l:librnnoise.so.0 \
  -Wl,-rpath,'$ORIGIN/..' \
  || die "falha ao compilar o plugin"

# confere que o plugin resolve a lib de dentro do AppImage
if ! LD_LIBRARY_PATH="$APPDIR/usr/lib" ldd "$APPDIR/usr/lib/nvclean/nvclean_rnnoise_stereo.so" \
     | grep -q "librnnoise"; then
  die "plugin não linkou contra a librnnoise empacotada"
fi
# e que não sobrou dependência fora do esperado (libc/ld são do sistema)
echo "  dependências do plugin:"
LD_LIBRARY_PATH="$APPDIR/usr/lib" ldd "$APPDIR/usr/lib/nvclean/nvclean_rnnoise_stereo.so" \
  | sed 's/^/    /'

# --- payload ---------------------------------------------------------------
say "copiando app, controlador, config e ícone"
install -m755 "$HERE/scripts/linux/nvclean-control" "$APPDIR/usr/share/nvclean/nvclean-control"
install -m755 "$HERE/scripts/linux/nvclean-reconnect" "$APPDIR/usr/share/nvclean/nvclean-reconnect"
install -m755 "$HERE/app/nvclean-app"             "$APPDIR/usr/share/nvclean/nvclean-app"
install -m644 "$HERE/config/pipewire/filter-chain-nvclean.conf" \
                "$APPDIR/usr/share/nvclean/filter-chain-nvclean.conf"
install -m644 "$HERE/packaging/nvclean-reconnect.service" \
                "$APPDIR/usr/share/nvclean/nvclean-reconnect.service"

# o AppRun instala em ~/.local a partir destes caminhos
install -m755 "$HERE/packaging/AppRun" "$APPDIR/AppRun"
install -m644 "$HERE/packaging/nvclean.desktop" "$APPDIR/nvclean.desktop"
install -m644 "$HERE/packaging/nvclean.desktop" "$APPDIR/usr/share/applications/nvclean.desktop"
install -m644 "$HERE/packaging/nvclean.png" "$APPDIR/nvclean.png"
install -m644 "$HERE/packaging/nvclean.png" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps/nvclean.png"
cp "$APPDIR/nvclean.png" "$APPDIR/.DirIcon"

# docs dentro do pacote
install -m644 "$HERE/README.md" "$APPDIR/usr/share/nvclean/README.md"
install -m644 "$HERE/CHANGELOG.md" "$APPDIR/usr/share/nvclean/CHANGELOG.md"
# GPL-3.0 §4 e §6: a licença precisa acompanhar o binário distribuído, e o
# aviso do RNNoise (BSD-3) é exigido na redistribuição da librnnoise.so.0.
install -m644 "$HERE/LICENSE" "$APPDIR/usr/share/nvclean/LICENSE"
install -m644 "$HERE/THIRD-PARTY.md" "$APPDIR/usr/share/nvclean/THIRD-PARTY.md"
install -m644 "$HERE/docs/RELATORIO-LIMPADOR-DE-VOZ.md" \
  "$APPDIR/usr/share/nvclean/RELATORIO-LIMPADOR-DE-VOZ.md"

# versão legível pelo app/desktop
printf '%s\n' "$VERSION" > "$APPDIR/usr/share/nvclean/VERSION"

# --- appimagetool ----------------------------------------------------------
if [ ! -x "$TOOL" ]; then
  say "baixando o appimagetool"
  mkdir -p "$(dirname "$TOOL")"
  curl -fsSL -o "$TOOL" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage \
    || die "falha ao baixar o appimagetool"
  chmod +x "$TOOL"
fi

say "gerando o AppImage"
mkdir -p "$DIST"
OUT="$DIST/nvclean-${VERSION}-x86_64.AppImage"
rm -f "$OUT"

# --appimage-extract-and-run evita exigir FUSE só para *gerar* o AppImage
ARCH=x86_64 VERSION="$VERSION" \
  "$TOOL" --appimage-extract-and-run \
    --comp zstd --mksquashfs-opt -Xcompression-level --mksquashfs-opt 19 \
    "$APPDIR" "$OUT"

chmod +x "$OUT"

# --- verificação pós-build -------------------------------------------------
say "verificando o AppImage gerado"
"$OUT" --appimage-offset >/dev/null 2>&1 || true
if ! "$OUT" --appimage-extract-and-run --check >/dev/null 2>&1; then
  warn "o teste --check não passou (pode ser ambiente, não o pacote)"
fi

ls -lh "$OUT"
echo
echo "pronto: $OUT"
echo "teste:  $OUT --check"
echo "uso:    $OUT          (abre a janela e instala na primeira execução)"
