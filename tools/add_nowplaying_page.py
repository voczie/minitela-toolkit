"""
Adiciona a pagina "Tocando Agora" ao projeto da minitela: uma linha de
texto com scroll continuo no topo (titulo/artista da musica atual) e um
gif decorativo ocupando o resto da tela, embaixo.

Usa a pagina 3 do pageList ("Weather") -- nao usada em nenhuma tela do
app (ver Screens em minitela.ps1). Pages 7/8/9 ("New-page", vazias)
PARECEM slots reservaveis mas na pratica o AHMISimGenDemo_og.exe as
ignora silenciosamente ("reading page 7" sem processar nada, mesmo com
JSON valido) -- provavelmente reservadas pro firmware pra paginas de
sistema (teclado/calibracao/erro/debug). Reaproveitar uma pagina real
(0-6) que o app nao usa, como fizemos com "SystemInfo" pra Metricas, e
o caminho confiavel.

Uso:
    python3 add_nowplaying_page.py <file.zip> <caminho/para/onda.gif>

O gif deve estar preparado com tools/prepare_gif.py primeiro (tamanho e
fps corretos) -- ver docs/PROTOCOL.md. Depois de rodar este script,
regenere o ACF, suba e reinicie o dispositivo. O registrador de texto e
o 1503 (string, ate 128 caracteres) -- o minitela.ps1 ja sabe escrever
nele.
"""
import sys
import os
import copy
import shutil
import zipfile
import json
import time
import datetime

TARGET_PAGE_INDEX = 3          # "Weather" -- pagina real, nao usada pelo app
TARGET_PAGE_ORIGINAL_NAME = "Weather"
GIF_RESOURCE_NAME = "nowplaying_wave.gif"
NOWPLAYING_TAG = "NowPlaying_Text"
NOWPLAYING_REG = 1503
NOWPLAYING_MAX_CHARS = 128      # tem que bater com now_tag["stringNum"] abaixo

TEXT_HEIGHT = 32                # area do texto, no topo, largura 240 (tela toda)
# O gif fica tela cheia (240x240) por baixo do texto -- ver comentario
# junto de gif_page_template mais abaixo pro motivo. Prepare o gif com
# tools/prepare_gif.py --width 240 --height 240.


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    zip_path, gif_path = sys.argv[1], sys.argv[2]

    with open(gif_path, "rb") as f:
        gif_bytes = f.read()
    if gif_bytes[:6] not in (b"GIF87a", b"GIF89a"):
        print(f"AVISO: {gif_path} não parece ser um GIF válido.")

    with zipfile.ZipFile(zip_path, "r") as z:
        data = json.loads(z.read("data.json"))
        other_names = [n for n in z.namelist() if n not in ("data.json", GIF_RESOURCE_NAME)]
        other_data = {n: z.read(n) for n in other_names}

    target_page = data["pageList"][TARGET_PAGE_INDEX]
    if target_page.get("name") not in (TARGET_PAGE_ORIGINAL_NAME, "NowPlaying"):
        print(f"ERRO: pageList[{TARGET_PAGE_INDEX}] não é '{TARGET_PAGE_ORIGINAL_NAME}' nem já é "
              f"'NowPlaying' (nome atual: {target_page.get('name')!r}) -- confira se o índice de "
              f"página ainda está certo antes de sobrescrever.")
        sys.exit(1)

    # clona a estrutura da pagina Gif1 (indice 4) SEM MEXER na posicao/
    # tamanho do canvas/widget do gif -- fica tela cheia (240x240), byte a
    # byte igual ao que ja funciona nos slots Gif1/2/3. Uma versao anterior
    # deste script encolhia o canvas do gif pra caber so embaixo do texto;
    # com um gif de fundo TRANSPARENTE isso causou um bug (o compressor de
    # textura parece re-posicionar/cortar o conteudo com base na area
    # opaca, ignorando o canvas declarado) -- o texto ficava coberto pelo
    # gif. Manter o gif tela cheia e o texto por cima (zIndex maior) evita
    # esse comportamento nao documentado por completo.
    gif_page_template = copy.deepcopy(data["pageList"][4])
    gif_canvas = gif_page_template["canvasList"][0]
    gif_widget = gif_canvas["subCanvasList"][0]["widgetList"][0]
    gif_widget["info"]["src"] = "/" + GIF_RESOURCE_NAME

    # tag de texto nova (string), clonada do schema da Wifi_SSID (mesmo
    # padrao ja usado pros textos de CPU/RAM/Bateria)
    template_tag = next(t for t in data["tagList"] if t["name"] == "Wifi_SSID")
    now_tag = copy.deepcopy(template_tag)
    now_tag["name"] = NOWPLAYING_TAG
    now_tag["showName"] = {"en": NOWPLAYING_TAG, "zh": NOWPLAYING_TAG}
    now_tag["indexOfRegister"] = NOWPLAYING_REG
    now_tag["_indexOfRegister"] = NOWPLAYING_REG
    now_tag["stringNum"] = NOWPLAYING_MAX_CHARS
    if not any(t["name"] == NOWPLAYING_TAG for t in data["tagList"]):
        data["tagList"].append(now_tag)

    # widget de texto (clonado do padrao CPU/RAM/Bateria), com scroll
    # continuo ligado -- os widgets de texto da minitela ja suportam isso
    # nativamente (scrollEnabled), nao precisa simular na mao. Fica no
    # topo, num canvas proprio (nao dentro do canvas do gif).
    text_template = next(
        w for w in data["pageList"][2]["canvasList"][2]["subCanvasList"][0]["widgetList"]
        if w["name"] == "cpuText"
    )
    now_widget = copy.deepcopy(text_template)
    now_widget["name"] = "nowPlayingText"
    now_widget["tag"] = NOWPLAYING_TAG
    now_widget["wId"] = 201
    now_widget["id"] = "custom.201"
    now_widget["$$hashKey"] = "object:custom201"
    now_widget["info"]["left"] = 0
    now_widget["info"]["top"] = 0
    now_widget["info"]["width"] = 240
    now_widget["info"]["height"] = TEXT_HEIGHT
    now_widget["info"]["cSet"] = "New style 2"
    now_widget["info"]["text"] = ""
    now_widget["info"]["scrollEnabled"] = 1
    now_widget["info"]["scrollDirection"] = 0   # se rolar do lado errado, troque pra 1
    now_widget["info"]["scrollMode"] = 1        # loop continuo (nao ping-pong)
    now_widget["info"]["scrollAutoReverse"] = 0
    now_widget["info"]["scrollDuration"] = 6000
    now_widget["info"]["scrollDelay"] = 500

    text_canvas = copy.deepcopy(gif_canvas)
    text_canvas["id"] = f"{TARGET_PAGE_INDEX}.1"
    text_canvas["name"] = "text"
    text_canvas["w"] = 240
    text_canvas["h"] = TEXT_HEIGHT
    text_canvas["x"] = 0
    text_canvas["y"] = 0
    text_canvas["zIndex"] = 4
    text_canvas["subCanvasList"][0]["id"] = f"{TARGET_PAGE_INDEX}.1.0"
    text_canvas["subCanvasList"][0]["widgetList"] = [now_widget]

    gif_page_template["canvasList"] = [gif_canvas, text_canvas]
    gif_page_template["id"] = str(TARGET_PAGE_INDEX)
    gif_page_template["name"] = "NowPlaying"
    gif_canvas["id"] = f"{TARGET_PAGE_INDEX}.0"
    gif_canvas["subCanvasList"][0]["id"] = f"{TARGET_PAGE_INDEX}.0.0"

    data["pageList"][TARGET_PAGE_INDEX] = gif_page_template

    # O gerador ignora silenciosamente qualquer recurso nao catalogado em
    # `resourceList` (achado por tentativa e erro -- sem isso a pagina
    # aparecia "reading page N" no log sem processar nada). Registra o
    # gif igual as entradas dos outros gifs do projeto.
    if not any(r.get("id") == GIF_RESOURCE_NAME for r in data["resourceList"]):
        now = datetime.datetime.now()
        max_index = max((r.get("index", 0) for r in data["resourceList"]), default=0)
        data["resourceList"].append({
            "updateDate": now.strftime("%Y-%m-%d %H:%M:%S"),
            "name": os.path.splitext(GIF_RESOURCE_NAME)[0],
            "lastModified": int(time.time() * 1000),
            "lastModifiedDate": now.isoformat() + "Z",
            "webkitRelativePath": "",
            "size": len(gif_bytes),
            "type": "image/gif",
            "id": GIF_RESOURCE_NAME,
            "src": "/project/" + data["projectId"] + "/resources/" + GIF_RESOURCE_NAME,
            "progress": "100%",
            "index": max_index + 1,
        })

    new_data_json = json.dumps(data, ensure_ascii=False).encode("utf-8")

    tmp_path = zip_path + ".tmp"
    with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zout:
        zout.writestr("data.json", new_data_json)
        zout.writestr(GIF_RESOURCE_NAME, gif_bytes)
        for n, content in other_data.items():
            zout.writestr(n, content)

    shutil.move(tmp_path, zip_path)
    print(f"OK: pagina 'Tocando Agora' criada em pageList[{TARGET_PAGE_INDEX}] "
          f"(registrador de pagina = {TARGET_PAGE_INDEX + 1}), "
          f"texto no registrador {NOWPLAYING_REG}, gif = {GIF_RESOURCE_NAME}")


if __name__ == "__main__":
    main()
