#!/bin/bash
# Prova com o microfone REAL de que o filtro atua na ENTRADA.
#
# Mede o mesmo microfone em três situações:
#   1. mic cru            (captura direta do dispositivo)
#   2. nvclean filtro ON  (Dry/Wet Mix = 1.0)
#   3. nvclean filtro OFF (Dry/Wet Mix = 0.0, bypass)
#
# Ao final restaura a intensidade anterior e falha se:
#   - a captura não trouxer áudio
#   - o filtro não reduzir o piso de ruído
#   - a saída do sistema tiver sido alterada
#
# Uso: ./tools/test-entrada.sh [segundos] [mic]
set -uo pipefail

DUR="${1:-6}"
MIC="${2:-$(pactl get-default-source 2>/dev/null || true)}"
RATE=48000
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="${NVCLEAN_CONTROL:-$HOME/.local/bin/nvclean-control}"
OUT="$(mktemp -d)"

[ -n "$MIC" ] || { echo "nenhum microfone: passe como 2º argumento" >&2; exit 2; }
[ -x "$CONTROL" ] || { echo "nvclean-control não encontrado" >&2; exit 2; }

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\033[1;31mFALHA:\033[0m %s\n' "$*" >&2; exit 1; }

# guarda a intensidade atual para restaurar no final (inclusive em falha).
# `status --json` sai com código 3 quando não há microfone — e ainda assim
# devolve o JSON completo. Com `set -o pipefail`, o `|| echo 1.0` concatenava
# o valor do JSON com "1.0" e a restauração final falhava, deixando a
# intensidade do usuário no valor de bypass do teste.
PREV="$("$CONTROL" status --json 2>/dev/null | python3 -c \
  'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
v=d.get("intensity")
print(f"{float(v):.3f}" if isinstance(v,(int,float)) else "")' 2>/dev/null || true)"
# PREV vazio = estado desconhecido (falha do controlador). Nesse caso NÃO
# restaura nada: antes caía em 1.0 e sobrescrevia a escolha do usuário.
case "$PREV" in
  ''|*[!0-9.]*) PREV="" ;;
esac
# Restaura mesmo se um passo falhar no meio (antes o `exit 1` do fail()
# deixava o filtro em 1.0 ou em bypass).
trap '[ -n "$PREV" ] && NVCLEAN_REMEMBER=0 "$CONTROL" intensity "$PREV" >/dev/null 2>&1; rm -rf "$OUT"' EXIT

measure() {
  python3 - "$1" <<'PY'
import sys, wave, numpy as np
with wave.open(sys.argv[1]) as w:
    sr, sw = w.getframerate(), w.getsampwidth()
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)/32768
win = int(0.02*sr); n = len(x)//win
if n == 0:
    print("  (sem áudio)"); sys.exit(0)
db = 20*np.log10(np.sqrt((x[:n*win].reshape(n,win)**2).mean(axis=1))+1e-20)
floor, speech = np.percentile(db,10), np.percentile(db,95)
print(f"  piso={floor:7.2f} dBFS  fala={speech:7.2f} dBFS  SNR={speech-floor:6.2f} dB  pico={np.abs(x).max():.3f}")
PY
}

peak_of() {
  python3 - "$1" <<'PY'
import sys, wave, numpy as np
with wave.open(sys.argv[1]) as w:
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)/32768
print(f"{float(np.abs(x).max()):.4f}")
PY
}

rec() { # nome, alvo, canais
  local tries=0
  while [ "$tries" -lt 3 ]; do
    timeout $((DUR+3)) pw-cat --record --target="$2" --rate=$RATE --channels="${3:-1}" \
      --format=s16 --raw - > "$OUT/$1.raw" 2>/dev/null
    if [ -s "$OUT/$1.raw" ]; then
      ffmpeg -hide_banner -loglevel error -y -f s16le -ar $RATE -ac 1 \
        -i "$OUT/$1.raw" "$OUT/$1.wav" 2>/dev/null || true
      # captura sem nenhum sinal costuma ser dispositivo ainda suspenso:
      # tenta mais uma vez antes de considerar falha
      local peak
      peak="$(peak_of "$OUT/$1.wav" 2>/dev/null || echo 0)"
      awk -v p="$peak" 'BEGIN{exit !(p+0 > 0.0005)}' && return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  fail "captura '$1' vazia após ${tries} tentativas — microfone sem sinal"
}

echo "Duração por captura: ${DUR}s   microfone: $MIC"
echo "Fale/faça ruído durante as capturas."

say "1/3 — microfone cru (sem filtro)"
rec mic_cru "$MIC" 2; measure "$OUT/mic_cru.wav"

say "2/3 — nvclean com filtro LIGADO (Dry/Wet = 1.0)"
NVCLEAN_REMEMBER=0 "$CONTROL" intensity 1.0 >/dev/null 2>&1 || fail "não foi possível ajustar a intensidade"
rec nvclean_on nvclean 2; measure "$OUT/nvclean_on.wav"

say "3/3 — nvclean com filtro DESLIGADO (Dry/Wet = 0.0, bypass)"
NVCLEAN_REMEMBER=0 "$CONTROL" intensity 0.0 >/dev/null 2>&1 || fail "não foi possível ajustar a intensidade"
rec nvclean_off nvclean 2; measure "$OUT/nvclean_off.wav"

# restaura a intensidade escolhida antes do teste (se conhecida)
[ -n "$PREV" ] && NVCLEAN_REMEMBER=0 "$CONTROL" intensity "$PREV" >/dev/null 2>&1 || true

say "verificando escopo (saída do sistema)"
if [ ! -f "$HOME/.local/state/nvclean/output-baseline.json" ]; then
  echo "  (sem baseline; gravando o estado atual como referência)"
  python3 "$HERE/tools/check-output-untouched.py" --save >/dev/null \
    || fail "não foi possível gravar o baseline da saída"
fi
python3 "$HERE/tools/check-output-untouched.py" --verify || fail "a saída do sistema foi alterada"

say "verificando efeito na entrada"
ON_PEAK="$(peak_of "$OUT/nvclean_on.wav")"
OFF_PEAK="$(peak_of "$OUT/nvclean_off.wav")"
awk -v p="$ON_PEAK" 'BEGIN{exit !(p+0 > 0.001)}' \
  || fail "saída do filtro silenciosa (pico $ON_PEAK) — microfone não está entrando no filtro"
awk -v p="$OFF_PEAK" 'BEGIN{exit !(p+0 > 0.001)}' \
  || fail "saída em bypass silenciosa (pico $OFF_PEAK) — link do microfone quebrado"

python3 - "$OUT/nvclean_on.wav" "$OUT/nvclean_off.wav" <<'PY'
import sys, wave, numpy as np

def stats(p):
    with wave.open(p) as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64)/32768
    win = int(0.02*sr); n = len(x)//win
    db = 20*np.log10(np.sqrt((x[:n*win].reshape(n,win)**2).mean(axis=1))+1e-20)
    return float(np.percentile(db,10)), float(np.abs(x).max())

on_floor, on_peak = stats(sys.argv[1])
off_floor, off_peak = stats(sys.argv[2])

# Um piso de -200 dBFS é silêncio digital: significa que a captura não trouxe
# áudio nenhum (janela perdida), não que o filtro "removeu tudo". Sem esta
# checagem o teste passava com dados vazios.
if on_floor < -150 or off_floor < -150:
    print(f"FALHA: captura silenciosa (ON={on_floor:.1f} OFF={off_floor:.1f} dBFS). "
          "Rode de novo com som no microfone.", file=sys.stderr)
    sys.exit(1)

gain = off_floor - on_floor
print(f"\npiso ON={on_floor:.2f} dBFS  piso OFF={off_floor:.2f} dBFS  reducao={gain:.2f} dB")
print(f"pico ON={on_peak:.4f}  pico OFF={off_peak:.4f}")
if gain < 3.0:
    print("FALHA: o filtro não reduziu o ruído (fale durante o teste)", file=sys.stderr)
    sys.exit(1)
if on_peak < 0.001:
    print("FALHA: saída do filtro silenciosa", file=sys.stderr)
    sys.exit(1)
print("OK — o filtro está atuando na entrada.")
PY
