class_name YouTubeChatProvider
extends ChatProvider

## Adapta o chat do YouTube para a interface ChatProvider.
##
## Uso mínimo (pytchat, padrão — sem key):
##     var yt := YouTubeChatProvider.new()
##     yt.channel_id = "UCxxxxxxxxxxxxxxxxxxxxxx"   # ou setar video_id direto
##     add_child(yt)
##     yt.user_joined.connect(_spawn_player)
##     yt.user_command.connect(_handle_command)
##     yt.connect_chat()
##
## Uso com API oficial (precisa de key):
##     var yt := YouTubeChatProvider.new()
##     yt.backend = YouTubeChatProvider.Backend.OFFICIAL_API
##     yt.api_key = "AIza..."
##     yt.channel_id = "UCxxxxxxxxxxxxxxxxxxxxxx"
##     add_child(yt)
##     yt.connect_chat()

## Deixe VAZIO em produção. Vazio = o addon busca na variável de ambiente
## YOUTUBE_API_KEY ou em user://youtube_api_key.txt, mantendo a chave fora do
## .tscn e do Git. Preencher aqui só para teste rápido descartável.
## Qual backend usar.
##   PYTCHAT_SIDECAR — processo Python com pytchat. Sem key, sem cota,
##                    mais rápido (~1-2s de latência). Padrão.
##   OFFICIAL_API   — YouTube Data API v3. Precisa de key, consome cota,
##                    mais lento (~5s mínimo entre polls). Use se pytchat
##                    não estiver disponível ou se precisar de contrato
##                    documentado e estável.
enum Backend { OFFICIAL_API, PYTCHAT_SIDECAR }

@export var backend: Backend = Backend.PYTCHAT_SIDECAR

@export var api_key: String = ""

## Preencha UM dos dois. Se ambos estiverem preenchidos, video_id ganha.
@export var channel_id: String = ""   ## resolve a live ativa automaticamente
@export var video_id: String = ""     ## ID do vídeo da live (muda a cada stream)

## Repassado ao cliente. O YouTube devolve pollingIntervalMillis; isto é o piso.
@export var min_poll_interval: float = 5.0

## Só para o backend PYTCHAT_SIDECAR. Em distro com PEP 668 (Arch, Fedora,
## Debian recente) o pip global é bloqueado, então o pytchat costuma acabar num
## venv — aponte para o python de lá:
##     python3 -m venv ~/.venvs/streamchat
##     ~/.venvs/streamchat/bin/pip install pytchat
##     python_executable = "/home/voce/.venvs/streamchat/bin/python"
@export var python_executable: String = "python3"

var _client: Node


func _ready() -> void:
	if backend == Backend.PYTCHAT_SIDECAR:
		_client = YouTubeChatSidecar.new()
		_client.skip_history = true
		_client.python_executable = python_executable
	else:
		_client = YouTubeChatClient.new()
		_client.min_poll_interval = min_poll_interval
		_client.skip_history = true   # senão spawna o backlog inteiro de uma vez
	add_child(_client)

	_client.connected.connect(func(_id): provider_connected.emit())
	_client.chat_ended.connect(func(): provider_disconnected.emit("chatEnded"))
	_client.api_error.connect(_on_api_error)
	_client.message_received.connect(_on_message)


func platform_tag() -> String:
	return "yt"


func connect_chat() -> void:
	if backend == Backend.PYTCHAT_SIDECAR:
		# Sem key. A ponte resolve o canal sozinha lendo a página /live.
		if not video_id.is_empty():
			_client.start_from_video_id(video_id)
		elif not channel_id.is_empty():
			_client.start_from_channel_id(channel_id)
		else:
			push_error("YouTubeChatProvider: defina video_id ou channel_id.")
		return

	var key := StreamChatCredentials.youtube_api_key(api_key)
	if key.is_empty():
		return  # o helper já explicou o que fazer no console

	var vid := video_id
	if vid.is_empty():
		if channel_id.is_empty():
			push_error("YouTubeChatProvider: defina video_id ou channel_id.")
			return
		vid = await _client.resolve_live_video_id(channel_id, key)
		if vid.is_empty():
			return

	_client.start_from_video_id(vid, key)


func disconnect_chat() -> void:
	_client.stop()
	clear_users()
	provider_disconnected.emit("manual")


## --- Controle de atenção (economia de cota) ------------------------------
##
## Chame conforme o estado da partida. Em jogo por turnos isso costuma cortar
## o consumo pela metade ou mais, sem o jogador perceber diferença.
##
##   _on_turn_started()      -> attentive()
##   _on_shot_fired()        -> idle()      # animação, ninguém digita nada útil
##   _on_match_ended()       -> dormant()   # placar, downtime entre partidas
##   _on_lobby_opened()      -> attentive()

## No sidecar não há cota para economizar, então os modos viram no-op.
func attentive() -> void:
	if _client is YouTubeChatClient:
		_client.poll_mode = YouTubeChatClient.PollMode.ATTENTIVE

func idle() -> void:
	if _client is YouTubeChatClient:
		_client.poll_mode = YouTubeChatClient.PollMode.IDLE

func dormant() -> void:
	if _client is YouTubeChatClient:
		_client.poll_mode = YouTubeChatClient.PollMode.DORMANT


## --- Tradução YouTube -> ChatProvider ------------------------------------

func _on_message(msg: YouTubeChatMessage) -> void:
	# Eventos administrativos não têm autor jogável.
	match msg.type:
		YouTubeChatMessage.Type.CHAT_ENDED, \
		YouTubeChatMessage.Type.TOMBSTONE, \
		YouTubeChatMessage.Type.MESSAGE_DELETED, \
		YouTubeChatMessage.Type.MEMBER_ONLY_MODE_STARTED, \
		YouTubeChatMessage.Type.MEMBER_ONLY_MODE_ENDED:
			return
		YouTubeChatMessage.Type.USER_BANNED:
			# O author aqui é o MODERADOR, não o banido. Remove o banido do jogo.
			# (o channelId do banido está em snippet.userBannedDetails, que a
			#  classe de mensagem não expõe por padrão — adicione se precisar)
			return

	if msg.channel_id.is_empty():
		return

	var user := _touch_user(msg.channel_id, msg.username, Platform.YOUTUBE)
	user.avatar_url = msg.profile_image_url
	user.is_broadcaster = msg.author.is_owner
	user.is_moderator = msg.author.is_moderator
	user.is_subscriber = msg.author.is_member
	user.is_verified = msg.author.is_verified

	match msg.type:
		YouTubeChatMessage.Type.TEXT_MESSAGE:
			_dispatch_text(user, msg.message)

		YouTubeChatMessage.Type.SUPER_CHAT, YouTubeChatMessage.Type.SUPER_STICKER:
			var tier: int = msg.super_event.tier if msg.super_event else 1
			var display: String = msg.super_event.amount_display_string if msg.super_event else ""
			user_donated.emit(user, tier, display, msg.message)

		YouTubeChatMessage.Type.GIFT_EVENT:
			# Jewels: não tem tier. Normalizo pra 1..7 por faixa de jewels.
			var jewels: int = msg.gift_event.jewels_amount if msg.gift_event else 0
			var name: String = msg.gift_event.gift_name if msg.gift_event else "presente"
			user_donated.emit(user, _jewels_to_tier(jewels), "%d Jewels" % jewels, name)

		YouTubeChatMessage.Type.NEW_MEMBER:
			user_subscribed.emit(user, 1)

		YouTubeChatMessage.Type.MEMBER_MILESTONE:
			var months: int = msg.member_update.member_month if msg.member_update else 1
			user_subscribed.emit(user, months)

		YouTubeChatMessage.Type.GIFT_MEMBERSHIP_RECEIVED:
			user_subscribed.emit(user, 1)

		YouTubeChatMessage.Type.MEMBERSHIP_GIFTING:
			# Quem presenteou. Os presenteados chegam como eventos separados.
			var count: int = msg.member_update.memberships_gifted if msg.member_update else 1
			user_donated.emit(user, mini(count, 7), "%dx membership" % count, msg.message)

		YouTubeChatMessage.Type.POLL_EVENT:
			# Enquete nativa do YouTube. Se o seu jogo já faz votação por
			# comando, provavelmente dá pra ignorar.
			pass


## Faixas aproximadas — ajuste ao gosto do seu jogo.
static func _jewels_to_tier(jewels: int) -> int:
	if jewels >= 5000: return 7
	if jewels >= 2000: return 6
	if jewels >= 1000: return 5
	if jewels >= 500: return 4
	if jewels >= 200: return 3
	if jewels >= 50: return 2
	return 1


func _on_api_error(code: int, reason: String, description: String) -> void:
	push_warning("[YouTube %d] %s: %s" % [code, reason, description])
	match reason:
		"quotaExceeded", "dailyLimitExceeded":
			provider_disconnected.emit("quota")
		"liveChatEnded", "liveChatDisabled", "liveChatNotActive", "noActiveLive":
			provider_disconnected.emit("chatEnded")
		"rateLimitExceeded":
			# Não desconecta: o loop já respeita pollingIntervalMillis.
			# Se aparecer com frequência, aumente min_poll_interval.
			pass
