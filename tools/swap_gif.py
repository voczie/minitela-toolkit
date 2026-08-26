"""
Troca um dos GIFs embutidos num file.zip do projeto Minitela por um GIF
customizado. Faz backup do zip original no primeiro uso (<file.zip>.orig).

Uso:
    python3 swap_gif.py <caminho/para/file.zip> <slot> <caminho_do_seu_gif.gif>

Slots disponiveis (nome do arquivo original -> pagina no data.json):
    gif1  -> 1i1h1e37393671471.gif  (pagina index 4, "Gif1")
    gif2  -> 1h1k1e37393671464.gif  (pagina index 5, "Gif2")
    gif3  -> 1h1m1e37393671466.gif  (pagina index 6, "Gif3")

Os 3 slots originais sao 192x192 px. Este script NAO redimensiona --
so avisa se o tamanho nao bater (o app pode distorcer/cortar a imagem).
O menu "Trocar GIF..." do app (minitela.ps1) chama esta mesma logica.

Depois de trocar, regenere o ACF (ver docs/PROTOCOL.md) e faca upload +
reboot do dispositivo.
"""
import os
import sys
import shutil
import struct
import zipfile

SLOTS = {
    "gif1": "1i1h1e37393671471.gif",
    "gif2": "1h1k1e37393671464.gif",
    "gif3": "1h1m1e37393671466.gif",
}


def gif_dims(data):
    return struct.unpack("<HH", data[6:10])


def main():
    if len(sys.argv) != 4 or sys.argv[2] not in SLOTS:
        print(__doc__)
        sys.exit(1)

    zip_path, slot, custom_path = sys.argv[1], sys.argv[2], sys.argv[3]
    backup_path = zip_path + ".orig"
    target_name = SLOTS[slot]

    with open(custom_path, "rb") as f:
        new_data = f.read()

    if new_data[:6] not in (b"GIF87a", b"GIF89a"):
        print(f"AVISO: {custom_path} não parece ser um GIF válido (header inesperado).")

    w, h = gif_dims(new_data)
    if (w, h) != (192, 192):
        print(f"AVISO: seu GIF é {w}x{h}px; o slot original é 192x192px. "
              f"Pode distorcer ou cortar. Redimensione antes se possível.")

    if not os.path.exists(backup_path):
        shutil.copy(zip_path, backup_path)
        print(f"backup salvo em {backup_path}")

    tmp_path = zip_path + ".tmp"
    with zipfile.ZipFile(zip_path, "r") as zin, \
         zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zout:
        replaced = False
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == target_name:
                data = new_data
                replaced = True
            zout.writestr(item, data)

    if not replaced:
        os.remove(tmp_path)
        print(f"ERRO: {target_name} não encontrado em {zip_path}.")
        sys.exit(1)

    shutil.move(tmp_path, zip_path)
    print(f"OK: {target_name} (slot {slot}) substituído por {custom_path} em {zip_path}")


if __name__ == "__main__":
    main()
