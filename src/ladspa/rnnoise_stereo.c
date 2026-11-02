/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 eltonacosta
 *
 * nvclean_rnnoise_stereo.c — LADSPA estéreo do RNNoise (2 instâncias).
 *
 * Por que estéreo: o microfone HyperX QuadCast entrega 2 canais. Linkar apenas
 * um canal do dispositivo num nó mono descarta metade do sinal; ligar os dois
 * canais na mesma porta mono gera fan-in (não soma). O caminho correto — o
 * mesmo do plugin oficial do PipeWire (`noise_suppressor_stereo`) — é processar
 * L e R de forma independente, mantendo 2 canais da ponta a ponta.
 *
 * Modelo 48 kHz e controle de intensidade 0..1 (dry/wet), equivalentes ao
 * "Noise removal" do NVIDIA Broadcast. Latência: 480 amostras = 10 ms.
 *
 * Build: ./packaging/build-appimage.sh (ou scripts/linux/setup-denoiser.sh)
 */
#include <stdlib.h>
#include <string.h>

#include <rnnoise.h>
#include "ladspa.h"

#define NV_FRAME 480

enum { PORT_IN_L = 0, PORT_IN_R, PORT_OUT_L, PORT_OUT_R, PORT_MIX, PORT_COUNT };

static const char *const port_names[PORT_COUNT] = {
    "Input L", "Input R", "Output L", "Output R", "Dry/Wet Mix"
};

static LADSPA_PortDescriptor port_descriptors[PORT_COUNT] = {
    LADSPA_PORT_INPUT  | LADSPA_PORT_AUDIO,
    LADSPA_PORT_INPUT  | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_INPUT  | LADSPA_PORT_CONTROL,
};

static LADSPA_PortRangeHint port_range_hints[PORT_COUNT] = {
    { 0, 0.0f, 0.0f },
    { 0, 0.0f, 0.0f },
    { 0, 0.0f, 0.0f },
    { 0, 0.0f, 0.0f },
    { LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE | LADSPA_HINT_DEFAULT_MIDDLE,
      0.0f, 1.0f },
};

typedef struct {
    float *in_l;
    float *in_r;
    float *out_l;
    float *out_r;
    float *mix;

    DenoiseState *st_l;
    DenoiseState *st_r;

    /* Acumuladores por canal. */
    float in_frame_l[NV_FRAME];
    float in_frame_r[NV_FRAME];
    unsigned int fill;

    /* Fila de saída (frames processados, alinhados com o dry). */
    float out_frame_l[NV_FRAME];
    float out_frame_r[NV_FRAME];
    float next_frame_l[NV_FRAME];
    float next_frame_r[NV_FRAME];
    float dry_l[NV_FRAME];
    float dry_r[NV_FRAME];
    unsigned int out_pos;
    unsigned int out_len;
    int pending;
} Plugin;

static LADSPA_Handle instantiate(const LADSPA_Descriptor *descriptor,
                                 unsigned long sample_rate)
{
    Plugin *p;
    (void)descriptor;

    if (sample_rate != 48000)
        return NULL;
    if (rnnoise_get_frame_size() != NV_FRAME)
        return NULL;

    p = (Plugin *)calloc(1, sizeof(*p));
    if (!p)
        return NULL;

    p->st_l = rnnoise_create(NULL);
    p->st_r = rnnoise_create(NULL);
    if (!p->st_l || !p->st_r) {
        if (p->st_l) rnnoise_destroy(p->st_l);
        if (p->st_r) rnnoise_destroy(p->st_r);
        free(p);
        return NULL;
    }
    return (LADSPA_Handle)p;
}

static void connect_port(LADSPA_Handle instance, unsigned long port, LADSPA_Data *data)
{
    Plugin *p = (Plugin *)instance;
    switch (port) {
    case PORT_IN_L:  p->in_l = data;  break;
    case PORT_IN_R:  p->in_r = data;  break;
    case PORT_OUT_L: p->out_l = data; break;
    case PORT_OUT_R: p->out_r = data; break;
    case PORT_MIX:   p->mix = data;   break;
    default: break;
    }
}

static void run(LADSPA_Handle instance, unsigned long sample_count)
{
    Plugin *p = (Plugin *)instance;
    float mix;
    float in_l_sample;
    float in_r_sample;
    unsigned long i;

    if (!p->out_l || !p->out_r)
        return;

    if (!p->in_l) {
        memset(p->out_l, 0, sample_count * sizeof(float));
        if (p->in_r)
            memset(p->out_r, 0, sample_count * sizeof(float));
        return;
    }
    if (!p->in_r) {
        /* entrada mono no canal R: replica L */
        p->in_r = p->in_l;
    }

    mix = p->mix ? *p->mix : 1.0f;
    if (mix < 0.0f) mix = 0.0f;
    if (mix > 1.0f) mix = 1.0f;

    for (i = 0; i < sample_count; i++) {
        /* 1. promove o frame recém-processado para a fila de saída */
        if (!p->out_len && p->pending) {
            memcpy(p->out_frame_l, p->next_frame_l, sizeof(p->out_frame_l));
            memcpy(p->out_frame_r, p->next_frame_r, sizeof(p->out_frame_r));
            p->out_pos = 0;
            p->out_len = NV_FRAME;
            p->pending = 0;
        }

        /* 2. LÊ a entrada ANTES de escrever na saída. A LADSPA permite que o
         * host use o mesmo buffer para in e out; escrever primeiro destrói a
         * amostra que ainda seria consumida (a saída virava silêncio). */
        in_l_sample = p->in_l[i] * 32768.0f;
        in_r_sample = p->in_r[i] * 32768.0f;

        /* 3. emite uma amostra (silêncio só no priming de 10 ms) */
        if (p->out_len > 0) {
            float wl = p->out_frame_l[p->out_pos] / 32768.0f;
            float wr = p->out_frame_r[p->out_pos] / 32768.0f;
            /* dry_l/dry_r estão na escala int16 do RNNoise; normalizar antes
             * de misturar, senão o bypass (mix=0) satura em ±1.0. */
            float dl = p->dry_l[p->out_pos] / 32768.0f;
            float dr = p->dry_r[p->out_pos] / 32768.0f;
            p->out_l[i] = dl * (1.0f - mix) + wl * mix;
            p->out_r[i] = dr * (1.0f - mix) + wr * mix;
            p->out_pos++;
            p->out_len--;
        } else {
            p->out_l[i] = 0.0f;
            p->out_r[i] = 0.0f;
        }

        /* 4. consome a amostra de entrada (já lida no passo 2) */
        p->in_frame_l[p->fill] = in_l_sample;
        p->in_frame_r[p->fill] = in_r_sample;
        if (++p->fill == NV_FRAME) {
            memcpy(p->dry_l, p->in_frame_l, sizeof(p->dry_l));
            memcpy(p->dry_r, p->in_frame_r, sizeof(p->dry_r));
            rnnoise_process_frame(p->st_l, p->next_frame_l, p->in_frame_l);
            rnnoise_process_frame(p->st_r, p->next_frame_r, p->in_frame_r);
            p->fill = 0;
            p->pending = 1;
        }
    }
}

static void activate(LADSPA_Handle instance)
{
    Plugin *p = (Plugin *)instance;
    p->fill = 0;
    p->out_pos = 0;
    p->out_len = 0;
    p->pending = 0;
    rnnoise_init(p->st_l, NULL);
    rnnoise_init(p->st_r, NULL);
}

static void deactivate(LADSPA_Handle instance)
{
    (void)instance;
}

static void cleanup(LADSPA_Handle instance)
{
    Plugin *p = (Plugin *)instance;
    if (!p)
        return;
    if (p->st_l) rnnoise_destroy(p->st_l);
    if (p->st_r) rnnoise_destroy(p->st_r);
    free(p);
}

static const LADSPA_Descriptor descriptor = {
    0xC1EA4D02,
    "nvclean_rnnoise_stereo",
    LADSPA_PROPERTY_HARD_RT_CAPABLE,
    "nvclean RNNoise (stereo)",
    "nvclean",
    "MIT",
    PORT_COUNT,
    port_descriptors,
    port_names,
    port_range_hints,
    NULL,
    instantiate,
    connect_port,
    activate,
    run,
    NULL,
    NULL,
    deactivate,
    cleanup,
};

const LADSPA_Descriptor *ladspa_descriptor(unsigned long index)
{
    return index == 0 ? &descriptor : NULL;
}
