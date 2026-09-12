#!/usr/bin/env python3
"""
StreamChat — teste REAL ponta-a-ponta do backend pytchat (TDD).

Mede a latência de cada mensaje contra una live de verdade: compara o
timestamp que o próprio YouTube registró (snippet.publishedAt) com o momento
em que a ponte entregó a línea NDJSON.

Uso:
    python3 teste_pontae_ponta.py <video_id|url|channel:UC...> [duraçãon_seg]

Exit:
    0 = verde (latência dentro do contrato)
    1 = vermelho (contrato violado)
    2 = inconcluso (não chegó nenhuna mensaje: ninguén falou no chat)

Contrato TDD (o bug do delay):
    - a conexión deve estar de pé em CONEXION_TIMEOUT_SEG
    - mediana de (chegada − publishedAt) <= LATENCIA_LIMITE_SEG
      (o código antigo dormía ~5s por lote; o contrato exige <=2,5s)
"""

import datetime
import json
import os
import select
import statistics
import subprocess
import sys
import time

CONEXION_TIMEOUT_SEG = 25.0
LATENCIA_LIMITE_SEG = 2.5
DURACAO_DEFAULT_SEG = 45.0

# A ponte fica na MESMA pasta do teste. Nunca spawnar __file__ (fork-bomb!).
# STREAM_CHAT_BRIDGE permite rodar o teste contra outra variante (A/B cadência).
# Uma variável vazia deve cair no caminho padrão, não quebrar o spawn.
BRIDGE = os.environ.get("STREAM_CHAT_BRIDGE") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "pytchat_bridge.py"
)


def parse_published_utc(iso: str) -> float:
    """ISO8601 de pytchat ('...Z') -> epoch (float)."""
    if not iso:
        return 0.0
    dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return dt.timestamp()


def main() -> int:
    if len(sys.argv) < 2:
        print("uso: python3 teste_pontae_ponta.py <alvo> [duraçãon_seg]", file=sys.stderr)
        return 1

    alvo = sys.argv[1]
    duracao = float(sys.argv[2]) if len(sys.argv) > 2 else DURACAO_DEFAULT_SEG
    script = BRIDGE
    w0 = time.time()  # wall-clock no instante do lançamento (pareado com t0 monotonic)
    print("== teste real ponta-a-ponta (pytchat) ==")
    print("alvo        : %s" % alvo)
    print("duração     : %.0fs" % duracao)
    print("contrato    : mediana latência <= %.1fs" % LATENCIA_LIMITE_SEG)
    print(">> digite MENSAGEN no chat da live durante o teste (ex.: !teste 1 2 3)\n", flush=True)

    t0 = time.monotonic()
    proc = subprocess.Popen(
        [sys.executable, script, alvo],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )

    ready_at = None
    em_historia = False
    latencias: list[float] = []
    n_msg = 0
    errores = []

    try:
        # readline() puro bloquea quando a ponte está em silêncio (chat quieto)
        # e o teste nunca cumpriría o prazo. select() com deadline real.
        while True:
            sobra = duracao - (time.monotonic() - t0)
            if sobra <= 0:
                break
            rlist, _, _ = select.select([proc.stdout], [], [], min(sobra, 1.0))
            if not rlist:
                if proc.poll() is not None:
                    break
                continue  # janela esgotada, sem linha pendente

            line = proc.stdout.readline()
            if not line:
                if proc.poll() is not None:
                    break
                continue

            chegada = time.monotonic() - t0
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue

            if "_bridge" in o:
                kind = o["_bridge"]
                if kind == "ready":
                    ready_at = chegada
                    print("t=%6.2fs  ready  video_id=%s"
                          % (chegada, o.get("video_id", "?")), flush=True)
                elif kind == "history_start":
                    em_historia = True
                    print("t=%6.2fs  history_start (descarta %s msgs)"
                          % (chegada, o.get("count", "?")), flush=True)
                elif kind == "history_end":
                    em_historia = False
                    print("t=%6.2fs  history_end" % chegada, flush=True)
                elif kind == "ended":
                    print("t=%6.2fs  ended" % chegada, flush=True)
                    break
                elif kind == "error":
                    errores.append(o.get("reason", "?") + ": " + o.get("message", "")[:80])
                    print("t=%6.2fs  ERROR %s" % (chegada, errores[-1]), flush=True)
                continue

            if em_historia:
                continue  # backlog: NÃO conta na latência

            n_msg += 1
            snip = o.get("snippet", {}) if isinstance(o, dict) else {}
            publicado = parse_published_utc(snip.get("publishedAt", ""))
            chegada_wall = w0 + chegada
            lat = max(chegada_wall - publicado, 0.0) if publicado else None
            if lat is not None:
                latencias.append(lat)
            texto = (snip.get("displayMessage") or "").strip()
            print("t=%6.2fs  MSG lat=%.2fs  %r"
                  % (chegada, lat if lat is not None else float("nan"), texto[:42]), flush=True)

        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()

    # ------------------------------------------------------------- informe
    print("\n== informe ==")
    if ready_at is None:
        print("VERMELHO: nunca chegó 'ready' (%.0fs). Errores: %s"
              % (duracao, "; ".join(errores) or "ninguno"))
        return 1
    print("conexión    : %.2fs" % ready_at)
    if ready_at > CONEXION_TIMEOUT_SEG:
        print("VERMELHO: conexión acima de %.0fs" % CONEXION_TIMEOUT_SEG)
        return 1

    if n_msg == 0:
        print("INCONCLUSO: nenhuna mensaje chegó. Digite algo no chat da live "
              "durante o teste!")
        return 2
    if not latencias:
        print("INCONCLUSO: %d mensajes recebidos mas sem publishedAt útil." % n_msg)
        return 2

    med = statistics.median(latencias)
    print("mensajes    : %d (história descartada)" % n_msg)
    print("latência    : mediana=%.2fs  min=%.2fs  max=%.2fs"
          % (med, min(latencias), max(latencias)))

    if med <= LATENCIA_LIMITE_SEG:
        print("\nVERDE: mediana %.2f <= %.1fs — a ponte entrega no ritmo do contrato."
              % (med, LATENCIA_LIMITE_SEG))
        return 0
    print("\nVERMELHO: mediana %.2f > %.1fs — cadência do lote está acima do contrato."
          % (med, LATENCIA_LIMITE_SEG))
    return 1


if __name__ == "__main__":
    sys.exit(main())