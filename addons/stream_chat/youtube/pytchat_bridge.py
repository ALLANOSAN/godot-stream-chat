#!/usr/bin/env python3
"""
StreamChat — ponte pytchat -> Godot.

Roda como processo filho do jogo e escreve UMA linha JSON por evento no stdout
(formato NDJSON). O Godot lê linha a linha.

Por que pytchat e não requisição na mão: o truque todo desse caminho é a
InnerTube, a API interna do player do YouTube. Ela não é documentada e muda
sem aviso. O pytchat encapsula esse trabalho sujo — quando quebrar, o conserto
é `pip install -U pytchat`, não reescrever protocolo.

Usa o CompatibleProcessor, que devolve os dados no MESMO formato da API
oficial (snippet / authorDetails / pollingIntervalMillis). Assim o
youtube_chat_message.gd lê o resultado sem nenhuma alteração.

Uso:
    python3 pytchat_bridge.py <video_id | url | channel:UCxxxx>

Instalação da dependência:
    pip install --user pytchat
"""

import json
import re
import sys
import time

# stdout linha a linha: sem isso o Godot recebe tudo em blocos atrasados.
try:
    sys.stdout.reconfigure(line_buffering=True)
except AttributeError:
    pass


def emit(obj):
    """Escreve um evento no stdout como uma linha JSON."""
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def bridge(kind, **kw):
    """Mensagem de controle da ponte (não é mensagem de chat)."""
    payload = {"_bridge": kind}
    payload.update(kw)
    emit(payload)


def resolve_channel_live(channel_id):
    """
    Melhor-esforço: descobre o vídeo da live ativa de um canal lendo a página
    /live. FRÁGIL — depende do HTML do YouTube. Se falhar, passe o video_id.

    Quando NÃO há live no ar, o /live serve a página do canal, que também tem
    "videoId" no HTML — o do último vídeo publicado. Pegar o primeiro que
    aparecer devolve um VOD encerrado sem avisar, e o jogo conecta num chat
    morto achando que está tudo certo.

    O sinal confiável é o <link rel="canonical">, porque o YouTube entrega o
    conteúdo da página do vídeo sem trocar a URL (geturl() continua em /live):

        live no ar   -> canonical = .../watch?v=XXXXXXXXXXX
        sem live     -> canonical = .../channel/UC...
    """
    import urllib.request

    url = "https://www.youtube.com/channel/%s/live" % channel_id
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0",
        "Accept-Language": "en-US,en;q=0.9",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            final_url = r.geturl()
            html = r.read().decode("utf-8", errors="replace")
    except Exception as e:
        bridge("error", reason="channelFetchFailed", message=str(e))
        return None

    # Alguns caminhos redirecionam de fato; se acontecer, já resolve.
    m = re.search(r'[?&]v=([A-Za-z0-9_-]{11})', final_url)
    if m:
        return m.group(1)

    # Caso normal: URL não muda, o canonical é que aponta para o vídeo.
    m = re.search(r'<link rel="canonical" href="[^"]*[?&]v=([A-Za-z0-9_-]{11})"', html)
    if m:
        return m.group(1)

    # Rede de segurança para variação de layout.
    if re.search(r'"isLiveNow"\s*:\s*true', html):
        m = re.search(r'"videoId"\s*:\s*"([A-Za-z0-9_-]{11})"', html)
        if m:
            return m.group(1)

    bridge("error", reason="noActiveLive",
           message=("Nenhuma live pública no ar em %s. Se a transmissão for "
                    "não listada ou privada, o /live não a enxerga: passe o "
                    "video_id direto." % channel_id))
    return None


def extract_video_id(arg):
    if arg.startswith("channel:"):
        return resolve_channel_live(arg[len("channel:"):])
    if "/" not in arg and "?" not in arg and len(arg) <= 16:
        return arg
    m = re.search(r'(?:v=|youtu\.be/|/live/|/embed/)([A-Za-z0-9_-]{11})', arg)
    if m:
        return m.group(1)
    bridge("error", reason="badVideoId", message="Não consegui extrair o id de: %s" % arg)
    return None


def main():
    if len(sys.argv) < 2:
        bridge("error", reason="usage", message="uso: pytchat_bridge.py <video_id|url|channel:UC...>")
        return 2

    try:
        import pytchat
        from pytchat import CompatibleProcessor
    except ImportError:
        bridge("error", reason="missingDependency",
               message="pytchat não instalado. Rode: pip install --user pytchat")
        return 3

    video_id = extract_video_id(sys.argv[1])
    if not video_id:
        return 4

    try:
        chat = pytchat.create(video_id=video_id, processor=CompatibleProcessor())
    except TypeError:
        # API antiga de algumas versões/forks.
        chat = pytchat.LiveChat(video_id, processor=CompatibleProcessor())
    except Exception as e:
        bridge("error", reason="createFailed", message=str(e))
        return 5

    bridge("ready", video_id=video_id)

    first_batch = True
    try:
        while chat.is_alive():
            try:
                data = chat.get()
            except Exception as e:
                bridge("error", reason="fetchFailed", message=str(e))
                break

            items = data.get("items", []) if isinstance(data, dict) else []

            # O primeiro lote é histórico do chat. Sinalizamos para o Godot
            # decidir se descarta (senão o jogo spawna 200 pessoas de uma vez).
            if first_batch and items:
                bridge("history_start", count=len(items))

            for item in items:
                emit(item)

            if first_batch:
                bridge("history_end")
                first_batch = False

            polling = 1.0
            if isinstance(data, dict) and data.get("pollingIntervalMillis"):
                polling = max(float(data["pollingIntervalMillis"]) / 1000.0, 0.5)
            time.sleep(polling)

    except KeyboardInterrupt:
        pass
    finally:
        try:
            chat.terminate()
        except Exception:
            pass

    bridge("ended")
    return 0


if __name__ == "__main__":
    sys.exit(main())
