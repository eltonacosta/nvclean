#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 eltonacosta
"""Host LADSPA mínimo para testar o plugin nvclean fora do PipeWire.

Carrega o .so e processa um WAV, reportando o piso de ruído antes/depois.
Prova que o plugin realmente denoisa, independente de compilar.

O mapeamento de portas é derivado do DESCRITOR do plugin (PortDescriptors e
PortNames), não de índices fixos: a variante estéreo tem 5 portas
(InL, InR, OutL, OutR, Mix) e um mapeamento fixo de 3 portas escreveria no
buffer errado — inclusive corrompendo memória.

Uso: python3 tools/test-ladspa.py <plugin.so> <entrada.wav> <saida.wav> [mix]
"""
import ctypes
import sys
import wave

import numpy as np


class LADSPA_PortRangeHint(ctypes.Structure):
    _fields_ = [
        ("HintDescriptor", ctypes.c_int),
        ("LowerBound", ctypes.c_float),
        ("UpperBound", ctypes.c_float),
    ]


class LADSPA_Descriptor(ctypes.Structure):
    # Ordem exata dos campos segundo ladspa.h 1.1. Um campo faltando aqui
    # desloca os ponteiros de função e o host chama a função errada.
    _fields_ = [
        ("UniqueID", ctypes.c_ulong),
        ("Label", ctypes.c_char_p),
        ("Properties", ctypes.c_int),
        ("Name", ctypes.c_char_p),
        ("Maker", ctypes.c_char_p),
        ("Copyright", ctypes.c_char_p),
        ("PortCount", ctypes.c_ulong),
        ("PortDescriptors", ctypes.POINTER(ctypes.c_int)),
        ("PortNames", ctypes.POINTER(ctypes.c_char_p)),
        ("PortRangeHints", ctypes.POINTER(LADSPA_PortRangeHint)),
        ("ImplementationData", ctypes.c_void_p),
        ("instantiate", ctypes.c_void_p),
        ("connect_port", ctypes.c_void_p),
        ("activate", ctypes.c_void_p),
        ("run", ctypes.c_void_p),
        ("run_adding", ctypes.c_void_p),
        ("set_run_adding_gain", ctypes.c_void_p),
        ("deactivate", ctypes.c_void_p),
        ("cleanup", ctypes.c_void_p),
    ]


PORT_INPUT = 0x1
PORT_OUTPUT = 0x2
PORT_CONTROL = 0x4
PORT_AUDIO = 0x8


def load(path):
    lib = ctypes.CDLL(path)
    lib.ladspa_descriptor.restype = ctypes.POINTER(LADSPA_Descriptor)
    lib.ladspa_descriptor.argtypes = [ctypes.c_ulong]
    desc = lib.ladspa_descriptor(0)
    if not desc:
        raise SystemExit("ladspa_descriptor(0) retornou NULL")
    return lib, desc.contents


def classify(desc):
    """Devolve (portas_de_audio_entrada, portas_de_audio_saida, porta_de_mix)."""
    ins, outs, mix = [], [], None
    for i in range(desc.PortCount):
        flags = desc.PortDescriptors[i]
        name = (desc.PortNames[i] or b"").decode()
        if flags & PORT_AUDIO:
            if flags & PORT_INPUT:
                ins.append(i)
            if flags & PORT_OUTPUT:
                outs.append(i)
        elif flags & PORT_CONTROL:
            if mix is None:
                mix = i
    return ins, outs, mix


def read_wav(path, channels):
    with wave.open(path, "rb") as w:
        sr, ch, sw, n = (
            w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        )
        raw = w.readframes(n)
    dt = {2: np.int16, 4: np.int32}[sw]
    x = np.frombuffer(raw, dtype=dt).astype(np.float32) / float(2 ** (8 * sw - 1))
    if ch > 1:
        x = x.reshape(-1, ch)
    else:
        x = x.reshape(-1, 1)
    return x, sr


def floor_db(mono, sr, win=0.02):
    w = int(win * sr)
    n = len(mono) // w
    if n == 0:
        return -200.0, -200.0
    frames = mono[: n * w].reshape(n, w)
    rms = np.sqrt((frames ** 2).mean(axis=1) + 1e-20)
    db = 20 * np.log10(rms)
    return float(np.percentile(db, 10)), float(np.percentile(db, 95))


def main():
    plugin, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    requested_mix = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0

    lib, desc = load(plugin)
    in_ports, out_ports, mix_port = classify(desc)

    print(f"plugin : {desc.Name.decode(errors='replace')}  (Label={desc.Label.decode()})")
    print(f"portas : {desc.PortCount}  audio_in={len(in_ports)} "
          f"audio_out={len(out_ports)} mix_port={mix_port}")
    for i in range(desc.PortCount):
        print(f"  [{i}] {desc.PortNames[i].decode(errors='replace')} "
              f"flags=0x{desc.PortDescriptors[i]:x}")

    if not in_ports or not out_ports:
        raise SystemExit("FALHA: plugin não declara portas de áudio in/out")

    x, sr = read_wav(src, len(in_ports))
    if sr != 48000:
        raise SystemExit(f"esperado 48 kHz, recebido {sr}")

    # adapta o número de canais ao plugin (mono -> replica; estéreo -> corta)
    n_in = len(in_ports)
    if x.shape[1] < n_in:
        x = np.repeat(x[:, :1], n_in, axis=1)
    elif x.shape[1] > n_in:
        x = x[:, :n_in]

    instantiate = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong)(
        desc.instantiate)
    connect = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_ulong,
                               ctypes.POINTER(ctypes.c_float))(desc.connect_port)
    activate = ctypes.CFUNCTYPE(None, ctypes.c_void_p)(desc.activate)
    run = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_ulong)(desc.run)
    cleanup = ctypes.CFUNCTYPE(None, ctypes.c_void_p)(desc.cleanup)

    h = instantiate(None, sr)
    if not h:
        raise SystemExit("instantiate() retornou NULL (sample rate incompatível)")

    # buffers por canal, mantidos vivos durante todo o processamento
    in_bufs = [np.ascontiguousarray(x[:, c], dtype=np.float32) for c in range(n_in)]
    out_bufs = [np.zeros(len(x), dtype=np.float32) for _ in out_ports]
    mix = ctypes.c_float(requested_mix)

    in_ptrs = [buf.ctypes.data_as(ctypes.POINTER(ctypes.c_float)) for buf in in_bufs]
    out_ptrs = [buf.ctypes.data_as(ctypes.POINTER(ctypes.c_float)) for buf in out_bufs]
    mix_ptr = ctypes.pointer(mix)

    activate(h)

    # Blocos de tamanhos variados (não múltiplos de 480), como o PipeWire faz.
    # A LADSPA só garante out[0..n-1] durante run(), então reconectamos a cada
    # bloco — é o que um host real faz.
    i = 0
    block = 1024
    while i < len(x):
        n = min(block, len(x) - i)
        for port, buf in zip(in_ports, in_bufs):
            connect(h, port, buf[i:].ctypes.data_as(ctypes.POINTER(ctypes.c_float)))
        for port, buf in zip(out_ports, out_bufs):
            connect(h, port, buf[i:].ctypes.data_as(ctypes.POINTER(ctypes.c_float)))
        if mix_port is not None:
            connect(h, mix_port, mix_ptr)
        run(h, n)
        i += n

    cleanup(h)

    mono_in = x.mean(axis=1)
    mono_out = np.mean([b for b in out_bufs], axis=0)
    f_in, s_in = floor_db(mono_in, sr)
    f_out, s_out = floor_db(mono_out, sr)
    peak = float(np.abs(mono_out).max())

    print(f"\nentrada : piso={f_in:7.2f} dBFS  fala={s_in:7.2f} dBFS  SNR={s_in - f_in:6.2f} dB")
    print(f"saida   : piso={f_out:7.2f} dBFS  fala={s_out:7.2f} dBFS  SNR={s_out - f_out:6.2f} dB  pico={peak:.3f}")
    print(f"reducao : {f_in - f_out:6.2f} dB   (mix={requested_mix})")

    # grava a saída como WAV mono, só para inspeção
    with wave.open(dst, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((np.clip(mono_out, -1, 1) * 32767).astype(np.int16).tobytes())
    print(f"escrito : {dst}")

    # Um plugin quebrado produz silêncio total ou saturação. Ambos são falha.
    if peak > 1.5:
        raise SystemExit("FALHA: saida saturou (escala int16 vazando no dry/wet)")
    if peak < 1e-6:
        raise SystemExit("FALHA: saida silenciosa (portas mal mapeadas ou DSP quebrado)")
    if requested_mix >= 0.99 and f_in - f_out < 3.0:
        raise SystemExit("FALHA: reducao de ruido abaixo de 3 dB")


if __name__ == "__main__":
    main()
