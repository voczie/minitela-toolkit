# Minitela Toolkit

Substituto leve para o app oficial "MiniTela" da Positivo (que trava
constantemente e só mostra os gifs que já vêm prontos). Roda na bandeja do
Windows, troca de tela com **Ctrl+D**, mostra CPU/RAM/bateria em tempo
real, e deixa trocar os 3 gifs customizados direto por um menu.

## O que tem aqui

```
app/
  minitela.ps1            programa principal (bandeja + atalho + métricas + troca de gif)
  watchdog.ps1            inicia o minitela.ps1 e reinicia sozinho se ele cair/travar
  Iniciar Minitela.bat    launcher de duplo-clique (chama o watchdog, não o app direto)
  icon.png                ícone da bandeja
tools/
  swap_gif.py                troca um gif dentro do file.zip via linha de comando
  rebuild_metrics_page.py    reconstrói a página de métricas sem os ícones fantasma
  add_nowplaying_page.py     cria a página "Tocando Agora" (gif + texto com scroll)
  prepare_gif.py             redimensiona/recorta, limita fps, chroma-key e põe margem num gif
  assets/blank_240x240.png   imagem de fundo em branco usada pelo rebuild_metrics_page.py
  assets/nowplaying_wave.gif imagem de onda sonora usada pela página "Tocando Agora"
docs/
  PROTOCOL.md              notas do protocolo serial, registradores, páginas, bugs conhecidos
```

## Requisitos

- Windows 11 (ou 10) com o dispositivo Positivo MiniTela conectado via USB.
- **O app oficial "Positivo MiniTela" precisa estar instalado pelo menos
  uma vez** — não redistribuímos os binários dele aqui (ver "O que falta
  configurar" abaixo).
- Go 1.23+ só se for compilar o `sidecar-fixed.exe` você mesmo (ver
  abaixo). Python 3 só para os scripts de `tools/`.
- `ffmpeg.exe` só para `tools/prepare_gif.py` — já vem junto da instalação
  do app oficial da Positivo (`...\Minitela\assets\ffmpeg.exe`), não
  precisa instalar nada à parte.

## O que falta configurar (não vai pro git)

Esses itens são grandes, específicos do seu computador, ou de terceiros —
por isso ficam de fora do repositório (ver `.gitignore`) e precisam ser
copiados manualmente:

1. **`app/Gen/`** — o compilador de ACF da própria Positivo
   (`AHMISimGenDemo_og.exe` + DLLs + fontes + configs). Copie de dentro da
   sua instalação do app oficial:
   ```
   C:\Users\<voce>\AppData\Local\Packages\PositivoInformticaS.A.PositivoMinitela_*\LocalState\Minitela\assets\minipanel\resources\IDE_utils\Gen
   ```
2. **`app/Zip/file.zip`** — o projeto atual da sua minitela (páginas,
   gifs, layout). Copie da mesma instalação:
   ```
   ...\IDE_utils\Zip\file.zip
   ```
   Guarde uma cópia (`file.zip.orig`) antes de editar qualquer coisa.
3. **`app/sidecar-fixed.exe`** — usado só para o upload/reboot do
   dispositivo. É um binário [SideCar](https://github.com/FreyreCorona/SideCar)
   compilado do branch `main` (a release oficial v0.1.26 tem um bug que
   impede o modo CLI). Para compilar:
   ```
   git clone https://github.com/FreyreCorona/SideCar.git
   cd SideCar
   go get github.com/FreyreCorona/SideCar@main
   GOOS=windows GOARCH=amd64 go build -o sidecar-fixed.exe .
   ```
4. **`app/ACF/`** — pasta vazia, só precisa existir (o gerador escreve o
   resultado ali).

## Uso

1. Dê duplo-clique em `app/Iniciar Minitela.bat`.
2. Um ícone aparece na bandeja. Clique direito (ou esquerdo) pra abrir o
   menu: trocar de tela, trocar um gif, ou sair.
3. **Ctrl+D** cicla entre GIF 1 → GIF 2 → GIF 3 → Métricas → Tocando Agora → GIF 1...
4. Pra trocar um gif: menu → "Trocar GIF N..." → escolha um arquivo
   `.gif` (idealmente 192x192px). Leva ~30s (regenera e sobe pro
   dispositivo) — não feche o app nesse meio tempo.

A porta serial está fixa em `COM3` no topo do `minitela.ps1` (`$Device`) —
troque se a sua for outra (confira no Gerenciador de Dispositivos).

## O que foi feito nesta sessão (com o Claude)

Documentando com transparência o que é obra desta sessão de trabalho com
IA, para quem for ler o histórico do repositório:

- Todo o `minitela.ps1`: a lógica de bandeja/atalho/métricas/troca-de-gif,
  a reimplementação do protocolo serial em C# embutido (evitando
  reconectar a cada comando), os workarounds pro Device Guard e pra
  codificação UTF-8 do Windows PowerShell 5.1.
- `tools/rebuild_metrics_page.py` e a descoberta de que os ícones da
  página de métricas vêm de uma imagem de fundo estática, não de widgets
  (documentado em `docs/PROTOCOL.md`).
- `docs/PROTOCOL.md` — consolidação das notas de protocolo, boa parte
  vinda do próprio [SideCar](https://github.com/FreyreCorona/SideCar) mas
  reorganizada e complementada com o que descobrimos na prática.
- `tools/swap_gif.py` — adaptado do fluxo documentado no `AGENTS.md` do
  SideCar, simplificado para uso direto no Windows (sem Wine/distrobox).
- A página "Tocando Agora": `tools/add_nowplaying_page.py`, a integração
  com a API nativa do Windows (GSMTC — `Windows.Media.Control`, via
  sintaxe WinRT do PowerShell 5.1) que pega título/artista tanto do
  Spotify quanto de abas com áudio no Vivaldi/YouTube automaticamente, e a
  configuração do scroll contínuo (recurso nativo do widget de texto da
  minitela, só precisou ser ligado).
- `tools/prepare_gif.py` — redimensiona/recorta sem distorcer, limita fps
  com paleta única (evita flicker de cor entre quadros), remove o fundo
  do gif por chroma-key (transparência de verdade, testada no
  dispositivo) e adiciona margem opcional. Depurado em várias rodadas
  reais no hardware — layout, transparência, tamanho de arquivo (limite
  de upload do dispositivo) e um bug de borda branca no loop, todos
  documentados em `docs/PROTOCOL.md`.

## Ideias futuras

- [ ] Redesenhar a página de Métricas no Figma (layout mais bonito que o
  texto puro atual).
- [x] Página de "Tocando Agora" (Spotify / YouTube no Vivaldi) com título
  rolando continuamente para títulos grandes. A "onda sonora" é um gif
  decorativo pronto (não é reativa ao áudio de verdade — decidido de
  propósito para evitar a complexidade de captura de áudio em tempo real
  e reenvio de textura por frame, que o hardware não suporta bem).
- [x] Iniciar o app automaticamente no login do Windows — uma cópia de
  `Iniciar Minitela.bat` em `shell:startup`
  (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`), que chama
  o `watchdog.ps1` em modo oculto. Pra desativar, apague esse `.bat` da
  pasta de inicialização.
- [x] Watchdog (`watchdog.ps1`): reinicia o app sozinho se ele cair ou
  travar (detecta processo morto, `Responding=$false`, ou um heartbeat
  que parou de atualizar). Reconhece trocas de gif em andamento (não
  reinicia no meio de um upload/reboot do dispositivo) e respeita o
  "Sair" do menu (não fica reiniciando à toa quando você fecha de
  propósito).
- [x] Redimensionamento/limite de fps automático ao trocar GIF pelo menu
  — `minitela.ps1` chama o `ffmpeg.exe` direto (mesma lógica do
  `tools/prepare_gif.py`, sem depender de Python no Windows) antes de
  subir o arquivo pro dispositivo.

## Créditos

- [FreyreCorona/SideCar](https://github.com/FreyreCorona/SideCar) —
  engenharia reversa original do protocolo serial da Minitela e do
  pipeline de geração de ACF. Este projeto reusa e adapta esse
  conhecimento; `sidecar-fixed.exe` é esse projeto compilado do source.
- Positivo Informática — `AHMISimGenDemo_og.exe` e o restante da pasta
  `Gen/` são binários proprietários da Positivo, obtidos da própria
  instalação do app oficial. Não redistribuídos aqui.
