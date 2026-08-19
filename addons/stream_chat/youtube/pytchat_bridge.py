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


## Quantas falhas SEGUIDAS de leitura até desistir da live. O contador zera a
## cada leitura boa, então erro esparso ao longo de horas nunca acumula.
MAX_FALHAS_SEGUIDAS = 5


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


def bombear_chat(chat, dormir=time.sleep):
    """
    Lê o chat até acabar. Devolve "ended" no fim normal e "fetchFailed" quando
    desiste por erro repetido.

    Uma falha isolada do pytchat NÃO pode derrubar a conexão. A versão anterior
    saía do loop na primeira exceção de chat.get(), e o jogo ficava sem chat
    pelo resto da transmissão — aconteceu de verdade, 10 minutos adentro, com
    "'NoneType' object has no attribute 'get'" vindo de dentro do pytchat.
    Numa live de duas horas isso é fatal: ninguém vai reiniciar o jogo no ar.

    Espera crescente entre tentativas (2s, 4s, 8s, 16s) porque a causa costuma
    ser hipo momentâneo da InnerTube — insistir rápido só piora.
    """
    first_batch = True
    falhas = 0

    while chat.is_alive():
        try:
            data = chat.get()
        except Exception as e:
            falhas += 1
            if falhas >= MAX_FALHAS_SEGUIDAS:
                bridge("error", reason="fetchFailed",
                       message="%s (desisti após %d tentativas seguidas)" % (e, falhas))
                return "fetchFailed"
            bridge("error", reason="fetchRetry",
                   message="%s (tentativa %d de %d)" % (e, falhas, MAX_FALHAS_SEGUIDAS))
            dormir(min(2 ** falhas, 30))
            continue

        falhas = 0
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
        dormir(polling)

    return "ended"


def autoteste():
    """
    Confere a resiliência do loop sem precisar de live:

        python3 pytchat_bridge.py --autoteste
    """
    class ChatFalso:
        def __init__(self, roteiro):
            self.roteiro = list(roteiro)

        def is_alive(self):
            return bool(self.roteiro)

        def get(self):
            passo = self.roteiro.pop(0)
            if isinstance(passo, Exception):
                raise passo
            return passo

    def sem_espera(_s):
        return None
    lote = {"items": [{"ok": 1}], "pollingIntervalMillis": 500}
    falhas = []

    # O erro que derrubou a live de verdade, seguido de leitura boa.
    chat = ChatFalso([AttributeError("'NoneType' object has no attribute 'get'"), lote])
    if bombear_chat(chat, dormir=sem_espera) != "ended":
        falhas.append("falha isolada derrubou a conexão")

    # Quatro seguidas ainda não podem desistir (MAX_FALHAS_SEGUIDAS = 5).
    chat = ChatFalso([RuntimeError("boom")] * 4 + [lote])
    if bombear_chat(chat, dormir=sem_espera) != "ended":
        falhas.append("desistiu antes de MAX_FALHAS_SEGUIDAS")

    # Erro permanente precisa terminar, senão o jogo trava esperando para sempre.
    chat = ChatFalso([RuntimeError("boom")] * 50)
    if bombear_chat(chat, dormir=sem_espera) != "fetchFailed":
        falhas.append("erro permanente não terminou em fetchFailed")

    for f in falhas:
        print("FALHA: " + f, file=sys.stderr)
    print("autoteste: %d falha(s)" % len(falhas), file=sys.stderr)
    return 1 if falhas else 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--autoteste":
        return autoteste()

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

    try:
        bombear_chat(chat)
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
