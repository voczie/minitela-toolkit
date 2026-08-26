"""
Reconstroi a pagina "SystemInfo" (indice 2 do pageList, pagina 3 no
dispositivo) do projeto AHMI (file.zip) para mostrar CPU/RAM/Bateria como
texto puro, sem os icones de wifi/bluetooth que vem com o layout original.

Por que isso e necessario
--------------------------
A pagina "SystemInfo" original ja tinha widgets de texto ligados aos
registradores Wifi_SSID/BT_Name/Battery_Percent (pensados pra mostrar rede
wifi conectada, status de bluetooth e % de bateria). O minitela.ps1 escreve
CPU%/RAM%/Bateria% nesses mesmos registradores porque sao os unicos widgets
de texto "prontos" no layout original -- mas os icones de wifi/bluetooth/
bateria continuam aparecendo, incondicionalmente, por baixo do texto.

Investigando o file.zip (ver docs/PROTOCOL.md) descobrimos que esses icones
NAO vem de nenhum widget: a pagina tem uma IMAGEM DE FUNDO ESTATICA
(`r-2-0.png`, 240x240) com os icones e as bordas coloridas desenhados como
pixels fixos. Editar widgets/tags/estilos nao tem efeito nenhum sobre eles --
so removendo essa imagem de fundo (aqui, trocando por uma solida preta) e
que eles somem de fato.

O que este script faz
----------------------
1. Remove o widget de titulo "Monitor" (decorativo, sem tag).
2. Cria 3 tags de string novas, sem nome "conhecido" pelo firmware
   (CPU_Text=1500, RAM_Text=1501, Battery_Text=1502), clonadas do schema
   da tag Wifi_SSID.
3. Substitui os 3 widgets antigos (wifi/bluetooth/bateria) por clones
   simples de texto, ligados as tags novas, com estilo "New style 2"
   (o mesmo estilo usado pelo relogio, que nao carrega icone).
4. Substitui a imagem de fundo da pagina (r-2-0.png) por uma imagem preta
   solida 240x240 -- a correcao que de fato tira os icones.

Depois de rodar, gere o ACF de novo com o AHMISimGenDemo_og.exe (ver
docs/PROTOCOL.md ou o README) e faca o upload + reboot do dispositivo.

Uso
---
    python3 rebuild_metrics_page.py caminho/para/file.zip

Roda apenas UMA vez por file.zip -- rodar de novo em um zip ja processado
duplica os widgets (o script nao e idempotente de proposito, pra nao
mascarar erros silenciosamente).
"""
import os
import sys
import zipfile
import json
import copy
import shutil

# PNG preto solido 240x240, gerado com Go's image/png e validado em
# hardware real (upload+reboot confirmados por foto). Um PNG "a mao" via
# zlib puro em Python decodifica certinho no Go, mas o AHMISimGenDemo_og.exe
# (baseado em OpenCV) o rejeita com "File created error" -- por isso
# usamos este arquivo fixo em vez de gerar a imagem na hora.
BLANK_BG_PATH = os.path.join(os.path.dirname(__file__), "assets", "blank_240x240.png")


def make_text_widget(base, name, tag, wid, left, top, width, height):
    w = copy.deepcopy(base)
    w["name"] = name
    w["tag"] = tag
    w["wId"] = wid
    w["id"] = "custom.%d" % wid
    w["$$hashKey"] = "object:custom%d" % wid
    w["info"]["left"] = left
    w["info"]["top"] = top
    w["info"]["width"] = width
    w["info"]["height"] = height
    w["info"]["cSet"] = "New style 2"
    w["info"]["text"] = ""
    return w


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    zip_path = sys.argv[1]

    with zipfile.ZipFile(zip_path, "r") as z:
        data = json.loads(z.read("data.json"))
        other_names = [n for n in z.namelist() if n != "data.json" and n != "r-2-0.png"]
        other_data = {n: z.read(n) for n in other_names}

    page = data["pageList"][2]  # SystemInfo

    # 1. remove o titulo "Monitor"
    canvas0 = page["canvasList"][0]
    canvas0["subCanvasList"][0]["widgetList"] = [
        w for w in canvas0["subCanvasList"][0]["widgetList"] if w.get("name") != "Monitor"
    ]

    # 2. tags novas (string, sem nome reconhecido pelo firmware)
    template_tag = next(t for t in data["tagList"] if t["name"] == "Wifi_SSID")
    new_tags = [("CPU_Text", 1500), ("RAM_Text", 1501), ("Battery_Text", 1502)]
    for name, reg in new_tags:
        t = copy.deepcopy(template_tag)
        t["name"] = name
        t["showName"] = {"en": name, "zh": name}
        t["indexOfRegister"] = reg
        t["_indexOfRegister"] = reg
        data["tagList"].append(t)

    # 3. widgets novos (texto puro) nos 3 slots que tinham icone
    template_widget = next(
        w for w in page["canvasList"][2]["subCanvasList"][0]["widgetList"] if w["name"] == "wifiName"
    )

    canvas1 = page["canvasList"][1]  # era "Battery"
    canvas1["name"] = "Metric1"
    canvas1["subCanvasList"][0]["name"] = "Metric1"
    canvas1["subCanvasList"][0]["widgetList"] = [
        make_text_widget(template_widget, "batteryText", "Battery_Text", 101, 10, 25, 199, 30)
    ]

    canvas2 = page["canvasList"][2]  # era "Wifi"
    canvas2["name"] = "Metric2"
    canvas2["subCanvasList"][0]["name"] = "Metric2"
    canvas2["subCanvasList"][0]["widgetList"] = [
        make_text_widget(template_widget, "cpuText", "CPU_Text", 102, 0, 20, 90, 30)
    ]

    canvas3 = page["canvasList"][3]  # era "Bluetooth"
    canvas3["name"] = "Metric3"
    canvas3["subCanvasList"][0]["name"] = "Metric3"
    canvas3["subCanvasList"][0]["widgetList"] = [
        make_text_widget(template_widget, "ramText", "RAM_Text", 103, 0, 20, 90, 30)
    ]

    new_data_json = json.dumps(data, ensure_ascii=False).encode("utf-8")
    with open(BLANK_BG_PATH, "rb") as f:
        blank_bg = f.read()

    tmp_path = zip_path + ".tmp"
    with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zout:
        zout.writestr("data.json", new_data_json)
        zout.writestr("r-2-0.png", blank_bg)
        for n, content in other_data.items():
            zout.writestr(n, content)

    shutil.move(tmp_path, zip_path)
    print("OK: pagina SystemInfo reconstruida (texto puro, sem icones) em", zip_path)


if __name__ == "__main__":
    main()
