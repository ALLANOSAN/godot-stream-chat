class_name YouTubeChatClient
extends Node

## Cliente de chat ao vivo do YouTube para Godot 4.
##
## Usa a YouTube Data API v3 (LiveChatMessages: list), que continua ativa.
## Endpoints usados:
##   GET https://www.googleapis.com/youtube/v3/videos
##   GET https://www.googleapis.com/youtube/v3/liveChat/messages
##
## Só precisa de API key (não precisa OAuth) para ler o chat de lives públicas.
## Pegue a key em: https://console.cloud.google.com  -> ativar "YouTube Data API v3".
##
## ATENÇÃO À COTA: o projeto tem 10.000 unidades/dia por padrão e cada chamada
## de liveChat/messages custa 5 unidades. Isso dá ~2.000 chamadas/dia.
## Respeitar o pollingIntervalMillis devolvido pela API não é opcional.

signal connected(live_chat_id: String)
signal message_received(msg: YouTubeChatMessage)
signal chat_ended()
signal api_error(http_code: int, reason: String, description: String)

const API_BASE := "https://www.googleapis.com/youtube/v3"

## Modos de atenção. Jogo por turnos tem muito tempo morto — usar ATTENTIVE o
## tempo todo é jogar cota fora.
##   ATTENTIVE — esperando input agora (turno de alguém, lobby aberto)
##   IDLE      — ninguém precisa ser ouvido (animação, placar, entre partidas)
##   DORMANT   — pausa quase total; a fila do YouTube segura as mensagens e
##               elas chegam todas juntas quando você voltar
enum PollMode { ATTENTIVE, IDLE, DORMANT }

## Intervalo mínimo entre polls, em segundos. Segura a cota mesmo se a API
## pedir um intervalo curto.
@export var min_poll_interval: float = 5.0

## Intervalo usado em PollMode.IDLE.
@export var idle_poll_interval: float = 20.0

## Intervalo usado em PollMode.DORMANT.
## Não zere isso nem deixe altíssimo: se você ficar tempo demais sem consumir,
## corre risco do nextPageToken envelhecer. 60s é conservador e seguro.
@export var dormant_poll_interval: float = 60.0

## Se true, descarta o primeiro lote (histórico do chat) e só emite
## mensagens novas a partir da conexão.
@export var skip_history: bool = true

var poll_mode: PollMode = PollMode.ATTENTIVE

var _api_key: String = ""
var _live_chat_id: String = ""
var _next_page_token: String = ""
var _running: bool = false
var _first_batch: bool = true
var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 20.0
	add_child(_http)


## --- API pública ---------------------------------------------------------

func start_from_video_id(video_id: String, api_key: String) -> void:
	_api_key = api_key
	_running = false
	_next_page_token = ""
	_first_batch = true

	var chat_id: String = await _fetch_live_chat_id(video_id)
	if chat_id.is_empty():
		return

	_live_chat_id = chat_id
	_running = true
	connected.emit(_live_chat_id)
	_poll_loop()


## Se você já tem o liveChatId (ex.: via liveBroadcasts.list com OAuth).
func start_from_chat_id(live_chat_id: String, api_key: String) -> void:
	_api_key = api_key
	_live_chat_id = live_chat_id
	_next_page_token = ""
	_first_batch = true
	_running = true
	connected.emit(_live_chat_id)
	_poll_loop()


func stop() -> void:
	_running = false


func is_running() -> bool:
	return _running


## Extrai o ID de um link do YouTube (watch?v=, youtu.be/, /live/).
static func extract_video_id(url_or_id: String) -> String:
	var s := url_or_id.strip_edges()
	if not s.contains("/") and not s.contains("?"):
		return s
	for marker in ["watch?v=", "youtu.be/", "/live/", "/embed/"]:
		var i := s.find(marker)
		if i != -1:
			var rest := s.substr(i + marker.length())
			for sep in ["&", "?", "/"]:
				var j := rest.find(sep)
				if j != -1:
					rest = rest.substr(0, j)
			return rest
	return ""


## Descobre o video ID da live ativa de um canal.
## Ao contrário do Twitch (nome do canal é fixo), no YouTube o vídeo muda a cada
## transmissão — então você quer resolver isso uma vez no início de cada sessão.
##
## Usa search.list, que tem bucket próprio de 100 chamadas/dia. Uma por live
## é tranquilo, mas NÃO chame isso em loop.
func resolve_live_video_id(channel_id: String, api_key: String) -> String:
	_api_key = api_key
	var url := "%s/search?part=snippet&channelId=%s&eventType=live&type=video&maxResults=1&key=%s" % [
		API_BASE, channel_id.uri_encode(), api_key.uri_encode()
	]
	var res: Dictionary = await _request(url)
	var items: Array = res.get("items", [])
	if items.is_empty():
		api_error.emit(404, "noActiveLive",
			"O canal '%s' não tem live ativa no momento." % channel_id)
		return ""
	return str(items[0].get("id", {}).get("videoId", ""))


## --- Interno -------------------------------------------------------------

func _fetch_live_chat_id(video_id: String) -> String:
	var url := "%s/videos?part=liveStreamingDetails&id=%s&key=%s" % [
		API_BASE, video_id.uri_encode(), _api_key.uri_encode()
	]
	var res: Dictionary = await _request(url)
	if res.is_empty():
		return ""

	var items: Array = res.get("items", [])
	if items.is_empty():
		api_error.emit(404, "videoNotFound",
			"Nenhum vídeo encontrado com o id '%s'." % video_id)
		return ""

	var details: Variant = items[0].get("liveStreamingDetails")
	if not (details is Dictionary):
		api_error.emit(400, "notALiveStream",
			"Esse vídeo não tem liveStreamingDetails — não é uma live.")
		return ""

	var chat_id: String = str(details.get("activeLiveChatId", ""))
	if chat_id.is_empty():
		api_error.emit(403, "liveChatNotActive",
			"A live não tem chat ativo (já terminou, ou o chat está desativado).")
	return chat_id


func _poll_loop() -> void:
	while _running:
		var url := "%s/liveChat/messages?liveChatId=%s&part=id,snippet,authorDetails&maxResults=200&key=%s" % [
			API_BASE, _live_chat_id.uri_encode(), _api_key.uri_encode()
		]
		if not _next_page_token.is_empty():
			url += "&pageToken=" + _next_page_token.uri_encode()

		var res: Dictionary = await _request(url)
		if res.is_empty():
			_running = false
			return

		_next_page_token = str(res.get("nextPageToken", ""))

		var emit_them: bool = not (_first_batch and skip_history)
		for item in res.get("items", []):
			if item is Dictionary:
				var msg := YouTubeChatMessage.from_json(item)
				if msg.type == YouTubeChatMessage.Type.CHAT_ENDED:
					_running = false
					chat_ended.emit()
					return
				if emit_them:
					message_received.emit(msg)
		_first_batch = false

		if res.has("offlineAt"):
			_running = false
			chat_ended.emit()
			return

		# O YouTube diz quanto esperar; nunca vá mais rápido que isso.
		# O modo atual só pode tornar o intervalo MAIOR, nunca menor.
		var api_wait: float = float(res.get("pollingIntervalMillis", 5000)) / 1000.0
		var floor_s: float = min_poll_interval
		match poll_mode:
			PollMode.IDLE: floor_s = idle_poll_interval
			PollMode.DORMANT: floor_s = dormant_poll_interval
		await get_tree().create_timer(maxf(api_wait, floor_s)).timeout


func _request(url: String) -> Dictionary:
	var err := _http.request(url)
	if err != OK:
		api_error.emit(0, "requestFailed", "HTTPRequest.request() retornou %d" % err)
		return {}

	var result: Array = await _http.request_completed
	var http_code: int = result[1]
	var body: PackedByteArray = result[3]
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())

	if not (parsed is Dictionary):
		api_error.emit(http_code, "badResponse", "Resposta não é JSON válido.")
		return {}

	if parsed.has("error"):
		var e: Dictionary = parsed["error"]
		var errors: Array = e.get("errors", [])
		var reason: String = str(errors[0].get("reason", "unknown")) if not errors.is_empty() else "unknown"
		api_error.emit(http_code, reason, str(e.get("message", "")))
		return {}

	if http_code < 200 or http_code >= 300:
		api_error.emit(http_code, "httpError", "HTTP %d" % http_code)
		return {}

	return parsed
