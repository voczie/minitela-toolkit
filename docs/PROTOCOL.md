# Protocolo da Minitela (notas de engenharia reversa)

Referência técnica para quem for tocar no `minitela.ps1` ou nos scripts de
`tools/`. A maior parte disso foi originalmente reverse-engineered pelo
projeto [FreyreCorona/SideCar](https://github.com/FreyreCorona/SideCar); o
que está aqui é o subconjunto que este projeto usa, mais o que descobrimos
sozinhos (a imagem de fundo estática, os bugs de reboot/ack).

## Hardware

- Dispositivo: Positivo MiniTela (Positivo Vision R15 M e similares).
- Tela 240x240, formato de pixel RGB565.
- Conexão: serial USB (aparece como porta COM no Windows), 115200 baud,
  8 bits, sem paridade, 1 stop bit.

## Frame do protocolo serial

```
[0x41, 0x48]   start flag (2 bytes)
controlFlag    2 bytes BE — bits[14:0] = tamanho(cmdType + content), bit[15] = CRC habilitado
cmdType        2 bytes BE
content        N bytes
crc16          2 bytes BE (0x0000 se CRC desabilitado)
[0x4D, 0x49]   end flag (2 bytes)
```

Todas as escritas usadas por este projeto vão com **CRC desabilitado**
(os 2 bytes de CRC são `0x00 0x00`) — é o que o próprio dispositivo/app
oficial faz para essas operações.

Tipos de comando usados aqui:

| Comando         | Valor    | Resposta esperada |
|-----------------|----------|--------------------|
| Handshake       | `0x0080` | `0x00C0`           |
| SetRegister     | `0x0090` | `0x00D0`           |
| RequestDownload | `0x0081` | `0x00C1`           |
| DownloadData    | `0x0082` | `0x00C2`           |
| DownloadComplete| `0x008F` | `0x00CF`           |
| Reboot          | `0x0070` | `0x00B0`           |

### SetRegister (0x0090) — como ler/escrever registradores

Byte de cabeçalho do `content`: `[replyFlag(1) | functionCode(3) | regCount(4)]`

- Escrita numérica: `[0x80 | (n-1)] [regId 2BE] [valor 4BE] ...` (até 16 por lote)
- Leitura numérica: `[0xC0 | (n-1)] [regId 2BE] ...`
- Escrita de string: `[0xD0] [regId 2BE] [tamanho 2BE] [bytes]`
- Leitura de string: `[0xE0] [regId 2BE] [tamanho maximo 2BE]`

## Registradores usados

| Registrador | Nome original      | O que fazemos aqui                          |
|-------------|---------------------|----------------------------------------------|
| 2           | Current Page        | trocar de tela (`Set-Screen` no minitela.ps1)|
| 1500        | (novo, custom)      | texto "CPU X%"                                |
| 1501        | (novo, custom)      | texto "RAM Y%"                                |
| 1502        | (novo, custom)      | texto "Bateria Z%"                            |
| 1503        | (novo, custom, `stringNum`=128) | texto "Artista - Título" (Tocando Agora) |

Os registradores 1082/1083/1085/1150 (`Battery_Percent`/`Wifi_SSID`/
`BT_Name`/`Battery_Type`) foram usados numa versão anterior (hijack dos
textos de wifi/bluetooth) — abandonados em favor de tags novas depois que
descobrimos a imagem de fundo estática (ver abaixo). Ficam documentados
aqui só como contexto histórico.

## Páginas / GIFs

O registrador "Current Page" é **1-indexado** e vale `índice no pageList + 1`.

| Slot          | Página (pageList index) | Valor do registrador | Arquivo gif dentro do file.zip     |
|---------------|--------------------------|------------------------|--------------------------------------|
| GIF 1         | 4                        | 5                      | `1i1h1e37393671471.gif`             |
| GIF 2         | 5                        | 6                      | `1h1k1e37393671464.gif`             |
| GIF 3         | 6                        | 7                      | `1h1m1e37393671466.gif`             |
| Métricas      | 2 ("SystemInfo")         | 3                      | n/a (widgets de texto)               |
| Tocando Agora | 3 ("Weather", reaproveitada) | 4                  | `nowplaying_wave.gif` (tela cheia)   |

Os 3 slots de gif esperam imagens de **192x192px**. Um gif de outro
tamanho é aceito mas pode distorcer/cortar (o app avisa e permite mesmo
assim). A página "Tocando Agora" usa uma estrutura diferente — um gif de
tela cheia (240x240, ver gotcha de canvas nao-quadrado abaixo) com um
canvas de texto separado por cima — construída em `add_nowplaying_page.py`,
clonando a estrutura da página Gif1 e adicionando um segundo canvas.

**As páginas 7/8/9 ("New-page", 0 canvas) PARECEM slots vazios
reservaveis, mas na prática o gerador (`AHMISimGenDemo_og.exe`) as ignora
silenciosamente** — mesmo com JSON válido e recursos catalogados, o log
mostra `reading page 7` sem nenhum conteúdo processado depois. Suspeita:
reservadas pelo firmware para páginas de sistema (teclado/calibração/
erro/debug, ver `KeyBoardSystemPage` etc. mais acima), independente do
conteúdo do JSON. **Não use essas páginas** — reaproveite uma página real
(0-6) que o app não usa, como fizemos aqui com "Weather".

`pageList` tem 10 posições; os índices 7, 8 e 9 vêm vazios de fábrica
("New-page", 0 canvas) — slots reservados, seguros pra usar sem mexer em
nada que já existe. Ainda sobram os índices 8 e 9 pra futuras páginas.

## Gotchas conhecidos

- **Reboot sempre "falha" no Windows.** O comando `reboot` retorna um erro
  de I/O do Windows (`O dispositivo não reconhece o comando`) porque o
  dispositivo desconecta/reenumera no meio da espera pela resposta. É
  esperado — o reboot acontece de verdade, só espere ~10-15s e reconecte.
- **Escritas de registrador retornam um erro de parsing cosmético.** O ack
  do dispositivo às vezes não bate exatamente com o formato esperado
  (`functionCode` diferente do previsto, ou CRC declarado como habilitado
  mas com valor `0x0000`). O valor é gravado corretamente mesmo assim —
  esse erro pode ser ignorado com segurança.
- **A página não troca de verdade logo depois de um reboot, mesmo que o
  comando seja aceito.** Depois de um upload+reboot (ex.: troca de gif), o
  dispositivo volta pro handshake rápido, mas ainda está terminando de
  carregar o conteúdo/página padrão ("WhatsApp") por baixo — um comando de
  troca de página mandado nessa janela é aceito sem erro mas não tem
  efeito visual (o dispositivo volta sozinho pra página padrão logo
  depois). `GetDownloadStatus` (0x0085) **não serve como sinal de
  prontidão** aqui — testado em operação normal e ele fica em `0x10`
  ("preparando"), nunca bate `0x20` ("AHMI normal") como o nome sugeriria.
  A solução que funciona: depois do reboot, **escreve a página desejada e
  LÊ DE VOLTA o registrador 2** repetidamente até o valor lido bater com o
  esperado (ver o loop em `Invoke-GifSwap` no `minitela.ps1`) — não confie
  só no retorno "sucesso" da escrita.
- **A pasta de saída do `AHMISimGenDemo_og.exe` precisa existir antes.**
  O gerador não cria o diretório passado em `-o`; se não existir, ele
  falha com a mensagem genérica `File created error` (sem indicar o motivo
  real). Sempre garanta que a pasta `ACF/` exista antes de chamar o
  gerador.
- **Ícones "fantasmas" na página de métricas.** A página "SystemInfo" do
  projeto original tem os ícones de wifi/bluetooth/bateria desenhados como
  pixels fixos numa **imagem de fundo estática da página**
  (`r-2-0.png`, 240x240), não como parte de nenhum widget. Editar
  tags/widgets/estilos não tem efeito algum sobre eles — só troca a
  imagem de fundo funciona. Ver `tools/rebuild_metrics_page.py`.
- **PNGs "feitos à mão" em Python podem ser rejeitados pelo gerador.** Um
  PNG minimalista gerado só com `zlib`/`struct` decodifica certinho em
  qualquer decoder padrão (testado com o `image/png` do Go), mas o
  `AHMISimGenDemo_og.exe` (baseado em OpenCV) o rejeitou silenciosamente.
  Por isso `rebuild_metrics_page.py` usa um PNG fixo
  (`tools/assets/blank_240x240.png`) já validado em hardware real, em vez
  de gerar a imagem na hora.
- **Windows PowerShell 5.1 sem BOM não lê UTF-8 corretamente.** Acentos em
  strings do `.ps1` (ex.: "Métricas") aparecem corrompidos na interface.
  Solução usada: escrever os caracteres acentuados via código
  (`$([char]0x00E9)` para "é") em vez de digitá-los literalmente no
  arquivo, o que funciona independente da codificação do arquivo.
- **Device Guard/Smart App Control do Windows bloqueia `.exe` novos e não
  assinados**, de forma pouco previsível (um binário recém-compilado pode
  rodar bem por semanas e ser bloqueado depois, sem mudar nada).
  `minitela.ps1` por isso é um script PowerShell, não um `.exe` compilado.
  No início do projeto o upload/reboot do dispositivo rodava via um `.exe`
  de terceiros (`sidecar-fixed.exe`, compilado do SideCar) chamado como
  processo separado — até o Smart App Control passar a bloquear esse `.exe`
  especificamente. Reimplementamos o protocolo de upload inteiro
  (RequestDownload/DownloadData/DownloadComplete, baseado em
  `core/upload.go` do SideCar) direto em C# embutido no `minitela.ps1`
  (classe `MinitelaLink`), eliminando essa dependência por completo.
- **Upload pela porta serial é lento: espere uns 8-10 minutos pra um ACF de
  ~5-6 MB.** O dispositivo responde a cada pedaço de 1024 bytes
  (`RequestDownload` devolve esse tamanho como `maxPageSize`), e a 115200
  baud isso vira o gargalo real — não é bug, é o limite físico da porta.
  Um ACF maior que ~6,3 MB (ver limite de upload mais abaixo) demoraria
  ainda mais, outro motivo pra manter os gifs dentro do limite de tamanho.
- **`Add-Type` não consegue referenciar `.winmd` diretamente** (erro
  `0x80131047`) — necessário para chamar APIs WinRT modernas do Windows
  (usamos isso para "Tocando Agora" via GSMTC —
  `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager`).
  O compilador clássico que o `Add-Type`/C# embutido usa não sabe lidar
  com metadata WinRT. Solução: usar a sintaxe nativa do Windows PowerShell
  5.1 para tipos WinRT (`[Namespace.Tipo, Assembly, ContentType=WindowsRuntime]`)
  em vez de C#, com um helper manual (`Wait-WinRTTask` no `minitela.ps1`)
  para "esperar" os métodos assíncronos do WinRT (que não têm
  `GetAwaiter()` nativo em PowerShell) via reflexão sobre
  `System.WindowsRuntimeSystemExtensions.AsTask`.
- **Os widgets de texto já suportam scroll contínuo nativamente**
  (`scrollEnabled`, `scrollDirection`, `scrollMode`, `scrollDuration`,
  `scrollAutoReverse` no `info` do widget) — não precisa simular na mão.
  `scrollMode=1` + `scrollAutoReverse=0` dá o loop contínuo numa direção só
  (sem ping-pong). Não descobrimos o significado exato de cada valor de
  `scrollDirection` por falta do editor visual — se rolar para o lado
  errado, é só trocar entre `0`/`1` e regenerar.
- **Limite de tamanho de upload: 6436 KB (~6,29 MB).** É um limite do
  próprio SideCar (`maxUploadFileSize` em `core/upload.go`), não do
  dispositivo em si até onde sabemos — mas na prática é o teto real. Um
  gif com muitos quadros em alta resolução estoura isso fácil (73 quadros
  a 240x240 já passou de 7 MB). `tools/prepare_gif.py --fps` é a válvula
  de escape mais direta pra cortar tamanho.
- **Gif com fundo transparente via chroma-key funciona de verdade no
  dispositivo** (`tools/prepare_gif.py --keycolor`) — a pagina "SystemInfo"
  ja tinha nos ensinado isso com PNGs estaticos (`onlyColor`/`rgba(0,0,0,0)`),
  e o mesmo vale pros quadros de um gif: a area transparente mostra a cor
  de fundo da PAGINA por baixo (normalmente preto), nao a cor de fundo
  original do gif.
- **Padding/margem transparente num gif causa uma borda branca por um
  instante a cada loop.** No frame de transicao (ultimo quadro -> primeiro
  quadro), a composicao de alpha do decodificador da minitela nao se
  comporta bem com padding transparente adicionado via `ffmpeg pad=...:
  color=black@0.0`. Corrigido usando padding **preto opaco** em vez de
  transparente (`tools/prepare_gif.py --margin`) -- visualmente identico
  já que o fundo da página também é preto, mas sem o glitch. Se um dia
  a página tiver outro `backgroundColor`, ajuste a cor do padding pra
  bater.
- **Uma área de gif não-quadrada (ex. 240x208) causou letterbox estranho**
  (barras vazias) quando testamos a página "Tocando Agora" com uma área
  reservada só pra baixo da tela. Ainda não sabemos a causa exata; o mais
  provável é o compressor de textura ter alguma suposição de proporção
  quadrada. **Contornado, não resolvido**: manter canvases de gif sempre
  quadrados (`w == h`), do mesmo jeito que Gif1/2/3.
- **Um gif com transparência posicionado num canvas menor que a tela
  cheia (ex. 208x208 dentro de 240x240, deslocado por `y`) fez o conteúdo
  "vazar" pra cima, cobrindo um canvas de texto separado que deveria estar
  por cima dele** — mesmo com o JSON declarando as posições/tamanhos
  corretos e o texto tendo `zIndex` maior. Suspeita: o compressor de
  textura pode recortar/reposicionar PNGs com bordas totalmente
  transparentes com base na área de conteúdo opaco, ignorando o canvas
  declarado. **Contornado, não resolvido**: manter o canvas do gif em tela
  cheia (0,0,240,240, igual a Gif1/2/3) e sobrepor o texto por cima num
  canvas próprio de zIndex maior, em vez de dar ao gif uma área
  reduzida/deslocada.

## Ferramenta de geração de ACF

`Gen/AHMISimGenDemo_og.exe` é o compilador oficial da Positivo (parte do
instalador do app oficial MiniTela). Roda nativo no Windows, sem precisar
de Wine/distrobox. Uso:

```
cd Gen
echo 13 | AHMISimGenDemo_og.exe -f ..\Zip\file.zip -m 2 -c 0 -e 0 -d 1 -o ..\ACF
```

- `-e 0` = perfil de dispositivo GC9002 (240x240) — confirmar no seu
  `Gen\configInfo\scr.cfg` (8 bytes: largura e altura em little-endian).
- Precisa do "13" no stdin (prompt "Press any key to continue...").
- Gera `ACF\Texture.acf` (só a textura) e `ACF\ConfigData&Texture.acf`
  (textura + configuração completa) — usamos sempre o primeiro.
