class_name ChatHub
extends Node

## Junta vários ChatProvider num fluxo único.
##
## Motivo prático: com isso, espectadores do Twitch e do YouTube jogam a MESMA
## partida de Worms, sem o jogo saber de onde cada um veio. Você adiciona os
## providers como filhos deste nó e conecta só os sinais daqui.
##
## Cena sugerida:
##   ChatHub
##    ├── TwitchChatProvider   (twitch_chat -> seu nó do Twitcher)
##    └── YouTubeChatProvider  (api_key + channel_id)

signal user_joined(user: ChatProvider.ChatUser)
signal user_left(user: ChatProvider.ChatUser)
signal user_message(user: ChatProvider.ChatUser, text: String)
signal user_command(user: ChatProvider.ChatUser, command: String, args: PackedStringArray)
signal user_donated(user: ChatProvider.ChatUser, tier: int, amount_display: String, text: String)
signal user_subscribed(user: ChatProvider.ChatUser, months: int)

var _providers: Array[ChatProvider] = []


func _ready() -> void:
	for child in get_children():
		if child is ChatProvider:
			register(child)


func register(p: ChatProvider) -> void:
	if p in _providers:
		return
	_providers.append(p)

	# Prefixa o id com a plataforma. Sem isso, um channelId do YouTube poderia
	# em teoria colidir com um user_id do Twitch e dois espectadores virariam
	# o mesmo boneco.
	var tag := p.platform_tag()

	p.user_joined.connect(func(u): _stamp(u, tag); user_joined.emit(u))
	p.user_left.connect(func(u): user_left.emit(u))
	p.user_message.connect(func(u, t): user_message.emit(u, t))
	p.user_command.connect(func(u, c, a): user_command.emit(u, c, a))
	p.user_donated.connect(func(u, ti, am, t): user_donated.emit(u, ti, am, t))
	p.user_subscribed.connect(func(u, m): user_subscribed.emit(u, m))


static func _stamp(user: ChatProvider.ChatUser, tag: String) -> void:
	if not user.id.begins_with(tag + ":"):
		user.id = "%s:%s" % [tag, user.id]


func connect_all() -> void:
	for p in _providers:
		p.connect_chat()


func disconnect_all() -> void:
	for p in _providers:
		p.disconnect_chat()


## Repassa o modo de atenção para quem suporta (só o YouTube precisa disso —
## o Twitch é push via EventSub e não consome cota por mensagem).
func set_attention(mode: String) -> void:
	for p in _providers:
		if p.has_method("attentive"):
			match mode:
				"attentive": p.attentive()
				"idle": p.idle()
				"dormant": p.dormant()


func get_active_users() -> Array:
	var all: Array = []
	for p in _providers:
		all.append_array(p.get_active_users())
	return all
