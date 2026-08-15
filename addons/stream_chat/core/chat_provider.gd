class_name ChatProvider
extends Node

## Interface única de chat para o jogo.
##
## A ideia: seu jogo NUNCA fala com Twitch nem com YouTube diretamente. Ele só
## escuta os sinais daqui. Trocar de plataforma (ou rodar as duas ao mesmo
## tempo) vira questão de instanciar um provider diferente.
##
## Herdam desta classe:
##   - TwitchChatProvider  (shim em volta do seu código IRC atual)
##   - YouTubeChatProvider (em volta do YouTubeChatClient)


## Um usuário apareceu pela primeira vez. É AQUI que o jogo spawna o player.
## Não use "join" de plataforma: no YouTube ele não existe, e no Twitch é
## atrasado e não confiável. Primeira mensagem é o único sinal honesto.
signal user_joined(user: ChatUser)

## Usuário sumiu (timeout de inatividade). O jogo despawna aqui.
signal user_left(user: ChatUser)

## Mensagem de texto normal.
signal user_message(user: ChatUser, text: String)

## Comando: mensagem que começa com o prefixo (ex.: "!pula 3").
signal user_command(user: ChatUser, command: String, args: PackedStringArray)

## Alguém pagou algo (bits no Twitch, Super Chat/Sticker/Jewels no YouTube).
## `tier` normalizado 1..7, `amount_display` é a string já formatada na moeda.
signal user_donated(user: ChatUser, tier: int, amount_display: String, text: String)

## Sub (Twitch) ou membership (YouTube).
signal user_subscribed(user: ChatUser, months: int)

signal provider_connected()
signal provider_disconnected(reason: String)


enum Platform { TWITCH, YOUTUBE }

## Prefixo de comando. Deixe vazio para desativar o parsing de comandos.
@export var command_prefix: String = "!"

## Segundos de silêncio até considerar que o usuário saiu.
## Ajuste conforme o ritmo do seu jogo: chat pequeno pede valor maior.
@export var inactivity_timeout: float = 300.0

## Intervalo entre varreduras de usuários inativos.
@export var presence_sweep_interval: float = 15.0

var _users: Dictionary = {}   ## user_id (String) -> ChatUser
var _sweep_accum: float = 0.0


class ChatUser extends RefCounted:
	var id: String = ""             ## identidade estável: login (Twitch) / channelId (YT)
	var display_name: String = ""   ## pode mudar e pode repetir — nunca use como chave
	var avatar_url: String = ""     ## YouTube fornece; Twitch precisa de call extra
	var platform: int = ChatProvider.Platform.TWITCH
	var is_broadcaster: bool = false
	var is_moderator: bool = false
	var is_subscriber: bool = false ## sub (Twitch) / membro (YouTube)
	var is_verified: bool = false
	var first_seen_unix: int = 0
	var last_seen_unix: int = 0
	var metadata: Dictionary = {}   ## espaço livre pro seu jogo (nó do player, score…)


func _process(delta: float) -> void:
	if inactivity_timeout <= 0.0:
		return
	_sweep_accum += delta
	if _sweep_accum < presence_sweep_interval:
		return
	_sweep_accum = 0.0
	_sweep_inactive()


## --- A ser sobrescrito pelas subclasses ----------------------------------

## Prefixo curto da plataforma ("tw", "yt", ...). O ChatHub usa isso para
## namespacear os ids. Existe como método virtual para o hub não precisar
## conhecer as classes concretas — assim você pode apagar a pasta twitch/ se
## só usa YouTube, e nada quebra.
func platform_tag() -> String:
	return "xx"


func connect_chat() -> void:
	push_error("ChatProvider.connect_chat() não implementado")


func disconnect_chat() -> void:
	push_error("ChatProvider.disconnect_chat() não implementado")


## --- Helpers para as subclasses usarem ----------------------------------

## Registra atividade de um usuário e devolve o ChatUser.
## Dispara user_joined automaticamente se for a primeira vez.
func _touch_user(user_id: String, display_name: String, platform: Platform) -> ChatUser:
	var now := int(Time.get_unix_time_from_system())
	var user: ChatUser

	if _users.has(user_id):
		user = _users[user_id]
		user.display_name = display_name  # pode ter mudado
		user.last_seen_unix = now
	else:
		user = ChatUser.new()
		user.id = user_id
		user.display_name = display_name
		user.platform = platform
		user.first_seen_unix = now
		user.last_seen_unix = now
		_users[user_id] = user
		user_joined.emit(user)

	return user


## Faz o parsing de comando e emite o sinal certo.
func _dispatch_text(user: ChatUser, text: String) -> void:
	user_message.emit(user, text)

	if command_prefix.is_empty() or not text.begins_with(command_prefix):
		return

	var body := text.substr(command_prefix.length()).strip_edges()
	if body.is_empty():
		return

	var parts := body.split(" ", false)
	var cmd := parts[0].to_lower()
	var args := PackedStringArray(parts.slice(1))
	user_command.emit(user, cmd, args)


func _sweep_inactive() -> void:
	var now := int(Time.get_unix_time_from_system())
	var expired: Array[String] = []

	for uid in _users:
		var user: ChatUser = _users[uid]
		if now - user.last_seen_unix > int(inactivity_timeout):
			expired.append(uid)

	for uid in expired:
		var user: ChatUser = _users[uid]
		_users.erase(uid)
		user_left.emit(user)


## --- Consulta ------------------------------------------------------------

func get_user(user_id: String) -> ChatUser:
	return _users.get(user_id)


func get_active_users() -> Array:
	return _users.values()


func get_active_count() -> int:
	return _users.size()


## Remove todo mundo (fim de partida, troca de live, etc.).
func clear_users(emit_left: bool = true) -> void:
	if emit_left:
		for user in _users.values():
			user_left.emit(user)
	_users.clear()
