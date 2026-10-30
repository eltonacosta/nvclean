# Limpador de voz do NVIDIA Broadcast — engenharia reversa e equivalente Linux

Análise do instalador `NVIDIA_Broadcast_v2.3.0.71988672.exe` (198 MB) para
entender como o **Noise removal** do microfone funciona, e o que foi
reproduzido no Linux. O que é observação está separado do que é inferência.

- **Artefato:** `NVIDIA_Broadcast_v2.3.0.71988672.exe`
  - SHA-256: `c59e4bcbdaee4b56d12447086ee761ca41244ae3e048d1d2a849abb8e106f684`
- **Ferramenta:** REA (Ghidra 12.1.4 como provider nativo) + extração 7-Zip
- **Data da análise:** 2026-10-30

---

## 1. O que é o pacote

O `.exe` **não é** um instalador monolítico: é um **7-Zip SFX** cujo PDB é
`7zSfxMod.pdb` (loader `PackageLauncher.exe`, x86, 2024-02-07). O payload real é
um arquivo 7z anexado no offset `1036800`, com 265 arquivos e 734 MB
descompactados.

Componentes:

| Caminho | Papel |
|---|---|
| `setup.cfg` | manifesto do instalador NVIDIA (NVI2) |
| `NvMaxineClient/` | app principal |
| `NvMaxineClient/ui/NVIDIA Broadcast.exe` | shell Electron (211 MB) |
| `NvMaxineClient/ui/resources/app.asar` | UI React + `electron/main.js` + gateway MCP |
| `NvMaxineClient/nv/NvBroadcastCore.dll` | **núcleo de processamento** |
| `NvMaxineClient/nv/NvBroadcastMCP.exe` | bridge MCP |
| `NvMaxineVAD/` | driver de áudio virtual ("NVIDIA Broadcast Voice") |
| `NvMaxineModels/` | utilitário de download de modelos (OTA) |
| `NvMaxineVirtualCamera/` | câmera virtual |

## 2. Onde está o limpador de voz

### 2.1 API usada

`NvBroadcastCore.dll` (PE32+ x86-64, SHA-256
`f0963aecbd452f79c7787cc7ddee09e473cc9a6b4f432d9c1ce0cb9d0020908f`)
exporta, entre outras, a API do **NVIDIA Maxine Audio Effects (AFX)**:

```
NvAFX_CreateEffect      NvAFX_Run             NvAFX_SetU32
NvAFX_Load              NvAFX_DestroyEffect    NvAFX_SetString
NvAFX_SetBool           NvAFX_GetU32           NvAFX_GetString
```

E o plugin de pipeline:

```
NvAFXPLUGIN_StartPipeline   NvAFXPLUGIN_StopPipeline
NvAFXPLUGIN_TestDenoiserEffect
NvAFXPLUGIN_EnumAudioEndpoints / SetEffectEndpoint / SetDefaultAudioEndpoint
NVAFXPLUGINAPI_PushAudioSamplesToDevice
```

A DLL **não implementa o denoiser**: ela carrega `NVAudioEffects.dll`
(`SetDllDirectoryW` + `LoadLibrary`, função `FUN_18010fcb0`) e resolve as
funções por `GetProcAddress`, num mapa de nomes (`NvAFX_CreateEffect` etc.).
Ou seja, o modelo e a inferência vivem fora do instalador (ver 2.3).

### 2.2 Cadeia de efeitos de microfone

Os nomes internos dos efeitos aparecem como strings e são montados em
`FUN_1801089a0`:

| id interno | efeito exposto na UI |
|---|---|
| `nvbcast_afx_bnr` | Noise removal |
| `nvbcast_afx_rec` | Room echo removal |
| `nvbcast_afx_bnrrec` | Noise removal + Room echo (combo) |
| `nvbcast_afx_stdvoice` | Studio voice |

Os modelos associados (`FUN_180111240`, que monta o caminho do `.trtpkg`):

```
/denoiser_48k.trtpkg
/dereverb_48k.trtpkg
/dereverb_denoiser_48k.trtpkg
/studio_voice_low_latency_48k.trtpkg
/studio_voice_mic_profiles_48k.trtpkg
```

### 2.3 Os modelos não estão no pacote

`NvMaxineModels/NvMaxineModels.nvi` tem `skipotadownload = true` e declara o
`NvBroadcastInstallerOTAUtility.exe`. Esse utilitário usa
`NVSDK_NGX_OTA_UPDATES_Register/GetPath/Install` e baixa os `.trtpkg`
por arquitetura de GPU (`sm_52`, `sm_75`, `sm_86`, …) do serviço OTA da NVIDIA.
Confirmação estática: `Detected GPU arch :`, `.target sm_52`,
`Downloading models for GPU index =`.

### 2.4 Parâmetros de controle

Em `FUN_18010bb90` (aplicação de força/intensidade) e
`FUN_180113a00` (carregamento do modelo):

| parâmetro | uso |
|---|---|
| `model_path` | caminho do `.trtpkg` |
| `mic_profile_model` | modelo de perfis do Studio Voice |
| `mic_profile_id` | perfil escolhido |
| `intensity_ratio` | intensidade do efeito (`0..1`) |
| `legacy_intensity_ratio` | modo de compatibilidade da intensidade |
| `user_cuda_context` | contexto CUDA |

O formato de áudio é **mono 48 kHz** — strings `48k_mono`,
`studio_voice_mic_profiles_48k`, e a mensagem
`num_input_samples_per_frame and num_input_channels didnt match with value in model params`.

### 2.5 Pipeline em tempo real

O caminho é WASAPI → Maxine → driver virtual:

```
microfone (WASAPI/IAudioClient)
  → NvAFXCapturePipeline (resample para 48 kHz)
  → NvAFX_Run (inferência CUDA/TensorRT)
  → NvAFXRenderPipeline
  → nvrtxaudcap64v.dll  (NVIDIA Broadcast Voice, driver de áudio virtual)
  → os apps gravam de "NVIDIA Broadcast"
```

Evidências: `AudioCaptureWindows: IAudioClient initialize failed`,
`Endpoint Type: NVAFX_CAPTURE_ENDPOINT` / `NVAFX_RENDER_ENDPOINT`,
`PushAudioFrameOffline: built resamplers`, e o INF `nvrtxvad.inf` instalando um
dispositivo de captura (`USB\VID_0956&PID_9001`, classe `MEDIA`) com
`nvrtxvad64v.sys` + `nvrtxaudcap64v.dll`.

### 2.6 Versão em arquivo (offline)

`NvMxnCltMediaFileIO_*` usa **Media Foundation** (`MFStartup`,
`MFCreateSourceReaderFromURL`, `MFCreateSinkWriterFromURL`) com
`NvMxnCltAudioFileOutputBridge`. É o que o gateway MCP expõe em
`submit_file_processing`.

### 2.7 O controlador (gateway MCP)

O app abre um servidor MCP em **loopback** (`127.0.0.1:18036–18045`) e grava a
porta em `%APPDATA%\nvidia-broadcast\gateway.json`. As ferramentas
(`set_effects`, `get_broadcast_state`, `list_devices`, …) chamam o renderer por
IPC (`effects.enable` → `GATEWAY_REQUEST_KIND.EffectsEnable`).

O efeito de microfone exposto é:

```json
{ "effectId": "noise_removal", "params": { "strength": 0.8 } }
```

com `strength` normalizado em `0..1` — mapeado internamente para
`intensity_ratio`.

> **Limite importante:** o gateway só existe dentro do processo no Windows
> (`NvBroadcastMCP.exe` + `gateway.json` em `%APPDATA%`). Não é uma API remota:
> no Linux não há como "chamar" o Broadcast.

## 3. O que foi reproduzido no Linux

### 3.1 Desenho equivalente

```
microfone real
  → nvclean.input  (Audio/Sink — recebe o mic)
  → RNNoise 48 kHz (LADSPA, 2 instâncias: L e R)
  → nvclean        (Audio/Source — o "microfone" que os apps usam)
```

É o mesmo desenho observado no Windows: captura do dispositivo real,
processamento neural em 48 kHz, e exposição de um dispositivo virtual.

| | Broadcast | nvclean |
|---|---|---|
| Captura | WASAPI | PipeWire |
| Inferência | Maxine AFX (TensorRT, proprietário) | RNNoise (aberto) |
| Dispositivo virtual | driver de kernel + DLL | `libpipewire-module-filter-chain` |
| Taxa | 48 kHz mono | 48 kHz estéreo |
| Controle | gateway MCP local | `nvclean-control` |

### 3.2 Por que RNNoise

Três motivos objetivos:

1. O modelo original está em `.trtpkg` (TensorRT), **não embarcado** e
   licenciado para uso com o produto NVIDIA.
2. O SDK Maxine AFX para Linux é distribuído sob licença enterprise
   (o pacote Windows é gratuito; o Linux não).
3. O RNNoise é uma rede neural recorrente, 48 kHz, aberta, com custo de CPU
   baixo — atende ao caso de uso sem GPU dedicada.

### 3.3 Como o efeito é ligado/desligado

O filtro fica sempre carregado. O toggle altera o parâmetro
`rnnoise:Dry/Wet Mix`:

- `1.0` → saída 100% processada
- `0.0` → bypass, áudio original

Isso evita reiniciar o PipeWire (que derrubaria chamadas em andamento) — e é
verificado em runtime com `pw-cli set-param`.

## 4. Resultados medidos

Plugin isolado (`tools/test-ladspa.py`), voz sintética + ruído rosa:

```
entrada : piso=-34.11 dBFS  fala=-14.21 dBFS  SNR=19.90 dB
saida   : piso=-49.41 dBFS  fala=-14.40 dBFS  SNR=35.01 dB
reducao de ruido : 15.30 dB
```

Pipeline completo no PipeWire, A/B com o mesmo áudio
(`tools/test-entrada.sh` / medição dedicada):

```
FILTRO ON : piso=-50.51 dBFS  fala=-16.77 dBFS  SNR=33.74  rms=0.06760
BYPASS    : piso=-36.86 dBFS  fala=-16.66 dBFS  SNR=20.20  rms=0.07149
=> reducao de piso: 13.7 dB | ganho de SNR: 13.5 dB | variacao de nivel: -0.49 dB
```

E com o microfone real (HyperX QuadCast S):

```
mic cru      : piso=-44.54 dBFS  fala=-20.55 dBFS  SNR=23.99 dB
nvclean ON   : piso=-80.58 dBFS  fala=-46.98 dBFS  SNR=33.60 dB
nvclean OFF  : piso=-46.24 dBFS  fala=-22.37 dBFS  SNR=23.86 dB
```

A saída do sistema foi verificada depois de todos os testes:
`effect_input.boost3x` → `boost:Mult = 3.0`, inalterado.

## 5. Limites desta análise

- **Não foi executado** nenhum componente do Broadcast: é Windows-only e
  depende de GPU/CUDA. Tudo o que está acima vem de leitura estática
  (exports, imports, strings, pseudo-código) e da documentação embarcada.
- Os `.trtpkg` **não foram analisados**: não vêm no instalador.
- O pseudo-código é saída do decompilador Ghidra, não código-fonte original; os
  nomes `FUN_*` são atribuídos pela ferramenta.
- A latência do Broadcast não foi medida (exigiria execução em Windows).
  A do nvclean é 10 ms de processamento (1 frame RNNoise); o total percebido
inclui mais um buffer do PipeWire.
- Studio Voice, remoção de eco e os efeitos de câmera **não** foram
  reproduzidos.

## 6. Evidências REA

Principais IDs de evidência da sessão (exportáveis pelo REA):

| Evidência | Conteúdo |
|---|---|
| `ev_5d6f39ab…` | overview do PE (segmentos, 3016 funções, 1551 strings) |
| `ev_6a266622…` | imports do `NvBroadcastCore.dll` (WASAPI, MF, CUDA, D3D11) |
| `ev_61c5ac01…` | busca de strings no instalador |
| `ev_3c0f535a…` | pseudo-código de `FUN_180039f20` (pipeline de mídia) |

Endereços citados:

| símbolo/string | endereço |
|---|---|
| `NvAFX_SetU32 NVAFX_PARAM_MODEL_PATH…` | `0x180242f28` |
| `Init()` com `studio_voice_low_latency` | `0x180111240` |
| carga do `dereverb_denoiser` | `0x180111240` |
| `TRTpkg is missing from the ` | `0x180242798` |
| lista de effect ids (`nvbcast_afx_*`) | `0x180241ca8` |
| `NVAudioEffects.dll` | `0x180241f48` |
| `bnr_strength=` | `0x18022d1b0` |
| `input_sample_rate` | `0x1802429f8` |
| `48k_mono` | `0x1802425b0` |
