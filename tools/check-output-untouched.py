#!/usr/bin/env python3
"""Verifica que a SAÍDA de áudio do sistema não foi alterada pelo nvclean.

Compara o estado atual com um baseline salvo antes de instalar/executar:
  • presença dos nós effect_input.boost3x / effect_output.boost3x
  • valor do parâmetro boost:Mult (esperado 3.0)
  • hash do arquivo 51-boost3x.conf do usuário

Uso:
  ./tools/check-output-untouched.py --save     # grava o baseline
  ./tools/check-output-untouched.py --verify   # compara e falha se mudou

Sai com código 1 quando algo mudou, para poder rodar em CI/teste.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys

BOOST_CONF = os.path.expanduser(
    "~/.config/pipewire/pipewire.conf.d/51-boost3x.conf"
)
BASELINE = os.path.expanduser("~/.local/state/nvclean/output-baseline.json")
NODES = ("effect_input.boost3x", "effect_output.boost3x")


def dump() -> list[dict]:
    try:
        proc = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f"não foi possível ler o PipeWire: {exc}")
    if proc.returncode != 0:
        raise SystemExit(f"pw-dump falhou: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def snapshot() -> dict:
    objects = dump()
    found: dict[str, dict] = {}
    for obj in objects:
        props = (obj.get("info") or {}).get("props") or {}
        name = props.get("node.name")
        if name not in NODES:
            continue
        mult = None
        for item in ((obj.get("info") or {}).get("params") or {}).get("Props") or []:
            params = item.get("params") or []
            for i in range(0, len(params) - 1, 2):
                if str(params[i]).endswith("Mult"):
                    mult = params[i + 1]
        found[name] = {"media_class": props.get("media.class"), "mult": mult}

    conf_hash = None
    if os.path.isfile(BOOST_CONF):
        with open(BOOST_CONF, "rb") as fh:
            conf_hash = hashlib.sha256(fh.read()).hexdigest()

    return {"nodes": found, "conf_sha256": conf_hash, "conf_path": BOOST_CONF}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--save", action="store_true")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    current = snapshot()

    if args.save or not args.verify:
        os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
        with open(BASELINE, "w", encoding="utf-8") as fh:
            json.dump(current, fh, indent=1, ensure_ascii=False)
        print(f"baseline salvo em {BASELINE}")
        for name, info in current["nodes"].items():
            print(f"  {name}: mult={info['mult']} class={info['media_class']}")
        if not current["nodes"]:
            print("  (nenhum nó de boost encontrado — nada a proteger aqui)")
        return 0

    if not os.path.isfile(BASELINE):
        print(f"sem baseline em {BASELINE}; rode com --save antes", file=sys.stderr)
        return 2

    with open(BASELINE, encoding="utf-8") as fh:
        base = json.load(fh)

    problems: list[str] = []

    for name in NODES:
        before = base["nodes"].get(name)
        after = current["nodes"].get(name)
        if before and not after:
            problems.append(f"nó {name} DESAPARECEU")
        elif before and after:
            if before.get("mult") != after.get("mult"):
                problems.append(
                    f"{name}: Mult mudou de {before.get('mult')} para {after.get('mult')}"
                )
            if before.get("media_class") != after.get("media_class"):
                problems.append(f"{name}: media.class mudou")

    if base.get("conf_sha256") and current.get("conf_sha256") != base["conf_sha256"]:
        problems.append(
            f"{current['conf_path']} foi modificado (hash diferente)"
        )
    if base.get("conf_sha256") and current.get("conf_sha256") is None:
        problems.append(f"{current['conf_path']} foi REMOVIDO")

    if problems:
        print("FALHA — a saída de áudio do sistema foi alterada:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print("OK — saída do sistema intacta")
    for name, info in current["nodes"].items():
        print(f"  {name}: mult={info['mult']} class={info['media_class']}")
    if current.get("conf_sha256"):
        print(f"  {current['conf_path']}: hash preservado")
    return 0


if __name__ == "__main__":
    sys.exit(main())
