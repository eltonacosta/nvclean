#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 eltonacosta
"""Verifica que a SAÍDA de áudio do sistema não foi alterada pelo nvclean.

Compara o estado atual com um baseline salvo antes de instalar/executar:
  • nome do sink padrão (metadata do WirePlumber)
  • conjunto de sinks de saída expostos pelo PipeWire
  • presença de filtros virtuais de saída (nós "effect_*", sinks de filtro)

Uso:
  ./tools/check-output-untouched.py --save     # grava o baseline
  ./tools/check-output-untouched.py --verify   # compara e falha se mudou

Sai com código 1 quando algo mudou, para poder rodar em CI/teste.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

BASELINE = os.path.expanduser("~/.local/state/nvclean/output-baseline.json")
DEFAULT_SINK_KEY = "default.configured.audio.sink"
NVCLEAN_SINK = "nvclean.input"


def run(cmd: list[str], timeout: int = 15) -> str:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f"não foi possível executar {cmd[0]}: {exc}")
    if proc.returncode != 0:
        raise SystemExit(f"{cmd[0]} falhou: {proc.stderr.strip()}")
    return proc.stdout


def dump() -> list[dict]:
    return json.loads(run(["pw-dump"]))


def default_sink() -> str | None:
    """Lê o sink padrão configurado na metadata 'default' do WirePlumber."""
    out = run(["pw-metadata", "-n", "default"])
    prefix = f"key:'{DEFAULT_SINK_KEY}' value:'"
    for line in out.splitlines():
        if prefix not in line:
            continue
        rest = line.split(prefix, 1)[1]
        # O valor termina no `'` antes de " type:"
        value = rest.split("' type:", 1)[0]
        try:
            return json.loads(value).get("name")
        except json.JSONDecodeError:
            return None
    return None


def snapshot() -> dict:
    sinks: list[str] = []
    virtual_filters: list[str] = []
    for obj in dump():
        info = obj.get("info") or {}
        props = info.get("props") or {}
        name = props.get("node.name")
        if not name:
            continue
        # Sinks de reprodução: Audio/Sink e Audio/Duplex. Os nós do próprio
        # nvclean (entrada do microfone) não fazem parte da saída.
        if props.get("media.class") not in ("Audio/Sink", "Audio/Duplex"):
            continue
        if name == NVCLEAN_SINK or name.startswith("nvclean."):
            continue
        sinks.append(name)
        # Filtros do PipeWire expõem-se com prefixo effect_ e costumam ser
        # marcados como filter.smart; qualquer um deles no caminho de
        # reprodução significa que a saída passou a ser processada.
        if name.startswith("effect_") or props.get("filter.smart") in (True, "true"):
            virtual_filters.append(name)

    return {
        "default_sink": default_sink(),
        "sinks": sorted(sinks),
        "virtual_filters": sorted(virtual_filters),
    }


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
        print(f"  sink padrão: {current['default_sink']}")
        for name in current["sinks"]:
            print(f"  sink: {name}")
        if current["virtual_filters"]:
            print(f"  ! filtros virtuais presentes: {', '.join(current['virtual_filters'])}")
        return 0

    if not os.path.isfile(BASELINE):
        print(f"sem baseline em {BASELINE}; rode com --save antes", file=sys.stderr)
        return 2

    with open(BASELINE, encoding="utf-8") as fh:
        base = json.load(fh)

    problems: list[str] = []

    if base.get("default_sink") != current["default_sink"]:
        problems.append(
            f"sink padrão mudou de {base.get('default_sink')} para {current['default_sink']}"
        )

    base_sinks = set(base.get("sinks") or [])
    cur_sinks = set(current["sinks"])
    # Dispositivos plugados depois do baseline (fones, HDMI, USB) não são
    # alteração do nvclean; o que importa é que nenhum sink existente tenha
    # sumido e que nenhum filtro virtual tenha aparecido.
    removed = base_sinks - cur_sinks
    if removed:
        problems.append(f"sinks removidos: {', '.join(sorted(removed))}")
    if current["virtual_filters"]:
        problems.append(
            f"filtros virtuais no caminho de reprodução: {', '.join(current['virtual_filters'])}"
        )

    if problems:
        print("FALHA — a saída de áudio do sistema foi alterada:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print("OK — saída do sistema intacta")
    print(f"  sink padrão: {current['default_sink']}")
    for name in current["sinks"]:
        print(f"  sink: {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
