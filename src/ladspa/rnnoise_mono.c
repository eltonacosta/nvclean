/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 eltonacosta
 *
 * nvclean_rnnoise_mono.c — LADSPA mono wrapper para o RNNoise.
 *
 * Por que existe: o plugin LADSPA oficial do RNNoise (lib/rnnoise_ladspa.c no
 * repositório xiph/rnnoise) não é empacotado nesta distro, mas o
 * `source-rnnoise.conf` do PipeWire espera um plugin LADSPA. Em vez de instalar
 * pacote de terceiros ou depender de root, compilamos este wrapper mínimo.
 *
 * Equivalência com o NVIDIA Broadcast (ver RELATORIO-LIMPADOR-DE-VOZ.md):
 *   - o AFX usa modelo mono 48 kHz ("48k_mono");
 *   - o efeito "Noise removal" tem um controle de intensidade 0..1.
 * Aqui a intensidade vira mistura dry/wet: 0 = bypass, 1 = saída 100% denoised.
 *
 * Latência adicionada: 1 frame RNNoise = 480 amostras @ 48 kHz = 10 ms.
 *
 * Build: ./packaging/build-appimage.sh (ou scripts/linux/setup-denoiser.sh)
 */
#include <stdlib.h>
#include <string.h>

#include <rnnoise.h>
#include "ladspa.h"

/* O RNNoise fixa o frame em 480 amostras a 48 kHz; conferido em runtime. */
#define NV_FRAME 480

enum { PORT_INPUT = 0, PORT_OUTPUT, PORT_MIX, PORT_COUNT };

static const char *const port_names[PORT_COUNT] = {
    "Input", "Output", "Dry/Wet Mix"
};

static LADSPA_PortDescriptor port_descriptors[PORT_COUNT] = {
    LADSPA_PORT_INPUT  | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_INPUT  | LADSPA_PORT_CONTROL,
};

static LADSPA_PortRangeHint port_range_hints[PORT_COUNT] = {
    { 0, 0.0f, 0.0f },
    { 0, 0.0f, 0.0f },
    { LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE | LADSPA_HINT_DEFAULT_MIDDLE,
      0.0f, 1.0f },
};

typedef struct {
    float *input;
    float *output;
    float *mix;

    DenoiseState *st;

    /* Entrada acumulada até completar um frame do RNNoise. */
    float in_frame[NV_FRAME];
    unsigned int fill;

    /* Último frame processado e o frame seco correspondente. Emitir com um
     * frame de atraso mantém dry e wet alinhados na mistura. */
    float out_frame[NV_FRAME];
    float next_frame[NV_FRAME];
    float dry_frame[NV_FRAME];
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
        return NULL; /* o modelo é 48 kHz; o PipeWire é configurado em 48 kHz */
    if (rnnoise_get_frame_size() != NV_FRAME)
        return NULL; /* wrapper só cobre o frame canônico */

    p = (Plugin *)calloc(1, sizeof(*p));
    if (!p)
        return NULL;

    p->st = rnnoise_create(NULL);
    if (!p->st) {
        free(p);
        return NULL;
    }
    return (LADSPA_Handle)p;
}

static void connect_port(LADSPA_Handle instance, unsigned long port, LADSPA_Data *data)
{
    Plugin *p = (Plugin *)instance;
    switch (port) {
    case PORT_INPUT:  p->input = data;  break;
    case PORT_OUTPUT: p->output = data; break;
    case PORT_MIX:    p->mix = data;    break;
    default: break;
    }
}

static void run(LADSPA_Handle instance, unsigned long sample_count)
{
    Plugin *p = (Plugin *)instance;
    float mix;
    unsigned long i;

    if (!p->output)
        return;

    if (!p->input) {
        memset(p->output, 0, sample_count * sizeof(float));
        return;
    }

    mix = p->mix ? *p->mix : 1.0f;
    if (mix < 0.0f) mix = 0.0f;
    if (mix > 1.0f) mix = 1.0f;

    /* Duplo buffer: enquanto o frame N+1 é preenchido, o frame N já processado
     * é emitido. Isso mantém exatamente uma amostra de saída por amostra de
     * entrada, sem lacunas (a versão anterior reiniciava o buffer de saída no
     * mesmo instante em que processava e criava buracos periódicos). */
    for (i = 0; i < sample_count; i++) {
        /* 1. promove o frame recém-processado para a fila de saída */
        if (!p->out_len && p->pending) {
            memcpy(p->out_frame, p->next_frame, sizeof(p->out_frame));
            p->out_pos = 0;
            p->out_len = NV_FRAME;
            p->pending = 0;
        }

        /* 2. emite uma amostra (silêncio apenas no priming de 10 ms) */
        if (p->out_len > 0) {
            /* dry_frame está na escala int16 do RNNoise; normalizar antes de
             * misturar, senão o bypass (mix=0) satura (~+90 dB). */
            float dry = p->dry_frame[p->out_pos] / 32768.0f;
            float wet = p->out_frame[p->out_pos] / 32768.0f;
            p->output[i] = dry * (1.0f - mix) + wet * mix;
            p->out_pos++;
            p->out_len--;
        } else {
            p->output[i] = 0.0f;
        }

        /* 3. consome uma amostra de entrada */
        p->in_frame[p->fill] = p->input[i] * 32768.0f;
        if (++p->fill == NV_FRAME) {
            memcpy(p->dry_frame, p->in_frame, sizeof(p->dry_frame));
            rnnoise_process_frame(p->st, p->next_frame, p->in_frame);
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
    rnnoise_init(p->st, NULL);
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
    if (p->st)
        rnnoise_destroy(p->st);
    free(p);
}

static const LADSPA_Descriptor descriptor = {
    0xC1EA4D01, /* UniqueID arbitrário e estável */
    "nvclean_rnnoise_mono",
    LADSPA_PROPERTY_HARD_RT_CAPABLE,
    "nvclean RNNoise (mono)",
    "nvclean",
    "MIT",
    PORT_COUNT,
    port_descriptors,
    port_names,
    port_range_hints,
    NULL, /* ImplementationData */
    instantiate,
    connect_port,
    activate,
    run,
    NULL, /* run_adding */
    NULL, /* set_run_adding_gain */
    deactivate,
    cleanup,
};

const LADSPA_Descriptor *ladspa_descriptor(unsigned long index)
{
    return index == 0 ? &descriptor : NULL;
}
