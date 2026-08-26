"""
Prepara um gif pra minitela: redimensiona pro tamanho do slot (com crop,
sem distorcer) e limita a taxa de quadros (fps), pra evitar loops curtos e
"piscantes". Usa o ffmpeg (bundlado com o instalador do app oficial da
Positivo -- FFMPEG_PATH abaixo, ou informe outro com -ffmpeg).

Uso:
    python3 prepare_gif.py <entrada.gif> <saida.gif> [--size 192] [--fps 8] [--ffmpeg CAMINHO]
    python3 prepare_gif.py <entrada.gif> <saida.gif> --width 240 --height 205 --fps 6

Exemplos:
    # slot de gif normal (192x192), 8 fps
    python3 prepare_gif.py onda.gif onda_pronta.gif

    # pagina "Tocando Agora" (area do gif, nao quadrada), 6 fps (mais lento)
    python3 prepare_gif.py onda.gif onda_pronta.gif --width 240 --height 205 --fps 6
"""
import argparse
import os
import subprocess
import sys

# Caminho padrao do ffmpeg.exe -- bundlado com o instalador do app oficial
# da Positivo, nao precisa instalar nada a parte. Em formato POSIX (uso via
# WSL); se for rodar isso direto no PowerShell do Windows, passe --ffmpeg
# com o caminho em "C:\..." em vez de usar o padrao.
FFMPEG_PATH = (
    "/mnt/c/Users/distopia/AppData/Local/Packages"
    "/PositivoInformticaS.A.PositivoMinitela_6yhrh9dmgepzj/LocalState"
    "/Minitela/assets/ffmpeg.exe"
)


def to_windows_path(path):
    """Converte /mnt/c/... (WSL) para C:\\... -- o ffmpeg.exe eh um binario
    Windows e nao entende caminhos POSIX, mesmo quando invocado via WSL."""
    if path.startswith("/mnt/") and len(path) > 6 and path[6] == "/":
        drive = path[5].upper()
        return drive + ":\\" + path[7:].replace("/", "\\")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--size", type=int, default=None, help="lado do quadrado final em px (atalho para --width/--height iguais; padrao 192 se nenhum dos tres for passado)")
    parser.add_argument("--width", type=int, default=None, help="largura final em px")
    parser.add_argument("--height", type=int, default=None, help="altura final em px")
    parser.add_argument("--fps", type=int, default=8, help="taxa maxima de quadros (padrao 8)")
    parser.add_argument("--ffmpeg", default=FFMPEG_PATH, help="caminho do ffmpeg.exe")
    parser.add_argument("--keycolor", default=None,
                         help="cor de fundo a tornar transparente, ex. 'white' ou '0xFFFFFF' "
                              "(a minitela mostra transparencia como a cor de fundo da pagina, "
                              "normalmente preto). Omitido = mantem o fundo do gif original.")
    parser.add_argument("--similarity", type=float, default=0.18,
                         help="o quanto uma cor precisa se parecer com --keycolor pra virar "
                              "transparente (0-1, padrao 0.18). Baixo demais deixa sobras da cor "
                              "de fundo; alto demais come partes do desenho.")
    parser.add_argument("--margin", type=int, default=0,
                         help="margem transparente ao redor do conteudo, em px (padrao 0 = "
                              "preenche tudo). O conteudo fica centralizado, encolhido pra caber.")
    args = parser.parse_args()

    width = args.width or args.size or 192
    height = args.height or args.size or 192

    if not os.path.exists(args.ffmpeg):
        print(f"ERRO: ffmpeg nao encontrado em {args.ffmpeg}\n"
              f"Informe o caminho certo com --ffmpeg, ou instale o ffmpeg e aponte pra ele.")
        sys.exit(1)

    inner_w = width - 2 * args.margin
    inner_h = height - 2 * args.margin

    # scale com force_original_aspect_ratio=increase + crop = enche o
    # retangulo (interno, jah descontando a margem) sem esticar/distorcer.
    base_vf = f"fps={args.fps},scale={inner_w}:{inner_h}:force_original_aspect_ratio=increase,crop={inner_w}:{inner_h}"
    if args.keycolor:
        base_vf += f",colorkey={args.keycolor}:{args.similarity}:0.1,format=rgba"
    if args.margin:
        # pad de volta pro tamanho final, centralizado. Preto OPACO (nao
        # transparente) de proposito -- a pagina ja tem fundo preto, entao
        # visualmente da no mesmo, mas evita um bug real: com padding
        # transparente, no instante em que o loop do gif reinicia (ultimo
        # quadro -> primeiro quadro) aparecia uma borda branca ao redor da
        # tela inteira por um instante (a composicao de alpha nao se
        # comporta bem nessa transicao no decodificador da minitela).
        base_vf += f",pad={width}:{height}:{args.margin}:{args.margin}:color=black"

    # Paleta unica compartilhada entre todos os quadros (2 passos:
    # palettegen + paletteuse). Sem isso, o encoder padrao do ffmpeg gera
    # uma paleta OTIMIZADA POR QUADRO -- cada frame fica com cores levemente
    # diferentes, e o decoder da minitela mostra isso como um "piscar" de
    # fundo (branco/azul/preto alternando) em vez de um fundo estavel.
    # reserve_transparent/alpha_threshold preservam a transparencia do
    # colorkey acima (se usado) atraves da paleta indexada do GIF.
    palette = args.output + ".palette.png"
    cmd1 = [args.ffmpeg, "-y", "-i", to_windows_path(args.input),
            "-vf", f"{base_vf},palettegen=reserve_transparent=1", to_windows_path(palette)]
    result = subprocess.run(cmd1, capture_output=True, text=True)
    if result.returncode != 0:
        print("ERRO ao gerar paleta:")
        print(result.stderr[-2000:])
        sys.exit(1)

    cmd2 = [args.ffmpeg, "-y", "-i", to_windows_path(args.input), "-i", to_windows_path(palette),
            "-lavfi", f"{base_vf}[x];[x][1:v]paletteuse=alpha_threshold=128", to_windows_path(args.output)]
    result = subprocess.run(cmd2, capture_output=True, text=True)
    os.remove(palette)
    if result.returncode != 0:
        print("ERRO ao rodar ffmpeg:")
        print(result.stderr[-2000:])
        sys.exit(1)

    print(f"OK: {args.output} ({width}x{height}px, {args.fps}fps, paleta unica"
          f"{', transparencia em ' + args.keycolor if args.keycolor else ''})")


if __name__ == "__main__":
    main()
