# Avisos de terceiros — nvclean (Noise Vocal Clean)

O nvclean é distribuído sob a **GNU General Public License v3.0 ou posterior**
(veja [`LICENSE`](LICENSE)).

O pacote binário (`nvclean-<versão>-x86_64.AppImage`) **empacota** a biblioteca
`librnnoise.so.0`, que tem licença própria. Este arquivo cumpre o requisito de
reproduzir os avisos de copyright aplicáveis.

---

## RNNoise

`librnnoise.so.0` é empacotada dentro do AppImage
(`packaging/build-appimage.sh`), e o plugin LADSPA `nvclean_rnnoise_stereo.so`
liga contra ela.

Projeto: <https://github.com/xiph/rnnoise>
Licença: **BSD-3-Clause**

```
Copyright (c) 2017, Mozilla
Copyright (c) 2007-2017, Jean-Marc Valin
Copyright (c) 2005-2017, Xiph.Org Foundation
Copyright (c) 2003-2004, Mark Borgerding

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.Org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## Dependências do sistema (não redistribuídas)

Estas bibliotecas **não** acompanham o AppImage; são fornecidas pela
distribuição e carregadas em tempo de execução.

| Componente | Licença | Uso |
|---|---|---|
| PipeWire | MIT | módulo `filter-chain` e ferramentas `pw-*` |
| GTK 3 | LGPL-2.1-or-later | interface |
| PyGObject | LGPL-2.1-or-later | ligação Python ↔ GTK |
| libdbusmenu-glib | LGPL-2.1 / LGPL-3.0 | menu da bandeja (opcional) |
| Python 3 | PSF License | interpretador |
| systemd | LGPL-2.1-or-later | serviço `nvclean-reconnect` |

Todas são compatíveis com a GPL-3.0-or-later.
