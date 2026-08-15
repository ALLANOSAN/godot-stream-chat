class_name YouTubeChatMessage
extends RefCounted

## Container para o conteúdo de uma mensagem do chat ao vivo do YouTube.
## Conversão do YoutubeChatMessage.cs (stat-void) para GDScript / Godot 4.
##
## Atualizado para o schema do liveChatMessage vigente em 2026:
##  - novo tipo "giftEvent" (Jewels / presentes) — adicionado em 26/03/2026
##  - novo tipo "pollEvent" (enquetes) + snippet.pollDetails
##  - parsing de timestamp tolerante (o Substring(0,22) do original quebra
##    quando o YouTube manda fração de segundo com nº de dígitos diferente)


enum Type {
	TEXT_MESSAGE,              ## usuário enviou mensagem de texto
	SUPER_CHAT,                ## usuário comprou um Super Chat
	SUPER_STICKER,             ## usuário comprou um Super Sticker
	NEW_MEMBER,                ## novo membro (ou upgrade de nível)
	MEMBER_MILESTONE,          ## membro renovou / marco de X meses
	MEMBERSHIP_GIFTING,        ## usuário presenteou memberships
	GIFT_MEMBERSHIP_RECEIVED,  ## usuário recebeu membership de presente
	GIFT_EVENT,                ## NOVO (2026): usuário trocou Jewels por um presente
	POLL_EVENT,                ## NOVO: enquete criada no chat
	MEMBER_ONLY_MODE_STARTED,  ## modo somente-membros ligado (sem conteúdo visual)
	MEMBER_ONLY_MODE_ENDED,    ## modo somente-membros desligado (sem conteúdo visual)
	MESSAGE_DELETED,           ## mensagem apagada por moderador
	USER_BANNED,               ## usuário banido; o author é o moderador
	CHAT_ENDED,                ## chat encerrado, não vêm mais mensagens
	TOMBSTONE,                 ## marcador de mensagem que existia e foi deletada
	UNKNOWN,                   ## tipo novo ainda não tratado
}

enum MembershipType { SELF, GIFTED, RECEIVED }


## --- Campos principais ---------------------------------------------------

var type: Type = Type.UNKNOWN
var id: String = ""                  ## id da mensagem (em giftEvent pode repetir p/ atualizar combo)
var channel_id: String = ""          ## id do canal do autor
var username: String = ""            ## nome exibido do autor
var profile_image_url: String = ""   ## avatar do autor
var message: String = ""             ## texto exibível / notificação do evento

var timestamp_unix: int = 0          ## UTC em segundos (Unix)
var timestamp_iso: String = ""       ## string original ISO 8601 devolvida pela API

var author: AuthorDetails = AuthorDetails.new()
var super_event: SuperEvent = null       ## só para SUPER_CHAT / SUPER_STICKER
var member_update: MemberUpdate = null   ## só para eventos de membership
var gift_event: GiftEvent = null         ## só para GIFT_EVENT
var poll: PollEvent = null               ## só para POLL_EVENT


## --- Subclasses ----------------------------------------------------------

class AuthorDetails extends RefCounted:
	var is_verified: bool = false    ## selo de verificado
	var is_owner: bool = false       ## dono da live
	var is_member: bool = false      ## membro do canal (isChatSponsor)
	var is_moderator: bool = false   ## moderador do chat
	var channel_url: String = ""


class SuperEvent extends RefCounted:
	var amount_display_string: String = ""  ## ex.: "R$ 5,00"
	var currency: String = ""               ## ISO 4217, ex.: "BRL"
	var amount_micros: int = 0              ## 1 unidade da moeda = 1_000_000
	var tier: int = 0                       ## 1 a 7 (define a cor)
	var sticker_id: String = ""             ## só em SUPER_STICKER
	var sticker_alt_text: String = ""       ## só em SUPER_STICKER


class MemberUpdate extends RefCounted:
	var member_type: int = YouTubeChatMessage.MembershipType.SELF
	var member_level_name: String = ""
	var member_month: int = 1
	var memberships_gifted: int = 0
	var membership_upgraded: bool = false
	var gifter_channel_id: String = ""


class GiftEvent extends RefCounted:
	var jewels_amount: int = 0
	var gift_name: String = ""
	var gift_url: String = ""
	var duration_seconds: float = 0.0
	var has_visual_effect: bool = false
	var combo_count: int = 0
	var alt_text: String = ""


class PollEvent extends RefCounted:
	var question_text: String = ""
	var status: String = ""      ## "unknown" | "active" | "closed"
	var options: Array = []      ## Array de { "text": String, "tally": int }


## --- Construção ----------------------------------------------------------

## Cria a mensagem a partir de um item JSON já convertido em Dictionary.
static func from_json(item: Dictionary) -> YouTubeChatMessage:
	var msg := YouTubeChatMessage.new()
	msg._initialize(item)
	return msg


func _initialize(item: Dictionary) -> void:
	var snippet: Dictionary = _dict(item, "snippet")
	var author_details: Dictionary = _dict(item, "authorDetails")

	id = str(item.get("id", ""))
	type = parse_type_string(str(snippet.get("type", "")))

	channel_id = str(author_details.get("channelId", ""))
	username = str(author_details.get("displayName", ""))
	profile_image_url = str(author_details.get("profileImageUrl", ""))

	author.is_verified = bool(author_details.get("isVerified", false))
	author.is_owner = bool(author_details.get("isChatOwner", false))
	author.is_member = bool(author_details.get("isChatSponsor", false))
	author.is_moderator = bool(author_details.get("isChatModerator", false))
	author.channel_url = str(author_details.get("channelUrl", ""))

	timestamp_iso = str(snippet.get("publishedAt", ""))
	timestamp_unix = parse_iso_timestamp(timestamp_iso)

	match type:
		Type.TEXT_MESSAGE:
			message = str(snippet.get("displayMessage", ""))
		Type.SUPER_CHAT:
			_setup_super_event(snippet, "superChatDetails")
		Type.SUPER_STICKER:
			_setup_super_event(snippet, "superStickerDetails")
		Type.NEW_MEMBER:
			_setup_member_update(snippet, "newSponsorDetails")
		Type.MEMBER_MILESTONE:
			_setup_member_update(snippet, "memberMilestoneChatDetails")
		Type.MEMBERSHIP_GIFTING:
			_setup_member_update(snippet, "membershipGiftingDetails")
		Type.GIFT_MEMBERSHIP_RECEIVED:
			_setup_member_update(snippet, "giftMembershipReceivedDetails")
		Type.GIFT_EVENT:
			_setup_gift_event(snippet)
		Type.POLL_EVENT:
			_setup_poll_event(snippet)
		Type.MESSAGE_DELETED, Type.USER_BANNED, Type.CHAT_ENDED, Type.TOMBSTONE, \
		Type.MEMBER_ONLY_MODE_STARTED, Type.MEMBER_ONLY_MODE_ENDED:
			# Eventos administrativos: normalmente sem displayMessage.
			message = str(snippet.get("displayMessage", ""))
		_:
			message = str(snippet.get("displayMessage", ""))
			push_warning("YouTubeChatMessage: tipo não tratado '%s' | %s"
				% [snippet.get("type", "?"), message])


static func parse_type_string(t: String) -> Type:
	match t:
		"textMessageEvent": return Type.TEXT_MESSAGE
		"superChatEvent": return Type.SUPER_CHAT
		"superStickerEvent": return Type.SUPER_STICKER
		"newSponsorEvent": return Type.NEW_MEMBER
		"memberMilestoneChatEvent": return Type.MEMBER_MILESTONE
		"membershipGiftingEvent": return Type.MEMBERSHIP_GIFTING
		"giftMembershipReceivedEvent": return Type.GIFT_MEMBERSHIP_RECEIVED
		"giftEvent": return Type.GIFT_EVENT
		# A doc lista tanto "pollEvent" quanto "pollDetails" como valor de
		# snippet.type (aparente inconsistência da doc). Aceito os dois.
		"pollEvent", "pollDetails": return Type.POLL_EVENT
		"sponsorOnlyModeStartedEvent": return Type.MEMBER_ONLY_MODE_STARTED
		"sponsorOnlyModeEndedEvent": return Type.MEMBER_ONLY_MODE_ENDED
		"messageDeletedEvent": return Type.MESSAGE_DELETED
		"userBannedEvent": return Type.USER_BANNED
		"chatEndedEvent": return Type.CHAT_ENDED
		"tombstone": return Type.TOMBSTONE
		_: return Type.UNKNOWN


func _setup_super_event(snippet: Dictionary, node_name: String) -> void:
	var d: Dictionary = _dict(snippet, node_name)
	super_event = SuperEvent.new()
	super_event.amount_display_string = str(d.get("amountDisplayString", ""))
	super_event.currency = str(d.get("currency", ""))
	super_event.tier = int(d.get("tier", 0))
	# amountMicros vem como string no JSON (unsigned long).
	super_event.amount_micros = int(str(d.get("amountMicros", "0")))

	match node_name:
		"superChatDetails":
			message = "%s - %s" % [
				super_event.amount_display_string,
				str(d.get("userComment", ""))
			]
		"superStickerDetails":
			var meta: Dictionary = _dict(d, "superStickerMetadata")
			super_event.sticker_id = str(meta.get("stickerId", ""))
			super_event.sticker_alt_text = str(meta.get("altText", ""))
			message = "%s!" % str(snippet.get("displayMessage", ""))


func _setup_member_update(snippet: Dictionary, node_name: String) -> void:
	var d: Dictionary = _dict(snippet, node_name)
	member_update = MemberUpdate.new()
	var display: String = str(snippet.get("displayMessage", ""))

	match node_name:
		"memberMilestoneChatDetails":
			member_update.member_type = MembershipType.SELF
			member_update.member_level_name = str(d.get("memberLevelName", ""))
			member_update.member_month = int(str(d.get("memberMonth", "1")))
			message = display
		"newSponsorDetails":
			member_update.member_type = MembershipType.SELF
			member_update.member_level_name = str(d.get("memberLevelName", ""))
			member_update.membership_upgraded = bool(d.get("isUpgrade", false))
			message = display
		"membershipGiftingDetails":
			member_update.member_type = MembershipType.GIFTED
			member_update.member_level_name = str(d.get("giftMembershipsLevelName", ""))
			member_update.memberships_gifted = int(d.get("giftMembershipsCount", 0))
			message = "%s! - %s" % [display, member_update.member_level_name]
		"giftMembershipReceivedDetails":
			member_update.member_type = MembershipType.RECEIVED
			member_update.member_level_name = str(d.get("memberLevelName", ""))
			member_update.gifter_channel_id = str(d.get("gifterChannelId", ""))
			message = "%s! - %s" % [display, member_update.member_level_name]


func _setup_gift_event(snippet: Dictionary) -> void:
	var meta: Dictionary = _dict(_dict(snippet, "giftEventDetails"), "giftMetadata")
	gift_event = GiftEvent.new()
	gift_event.jewels_amount = int(meta.get("jewelsAmount", 0))
	gift_event.gift_name = str(meta.get("giftName", ""))
	gift_event.gift_url = str(meta.get("giftUrl", ""))
	gift_event.has_visual_effect = bool(meta.get("hasVisualEffect", false))
	gift_event.combo_count = int(meta.get("comboCount", 0))
	gift_event.alt_text = str(meta.get("altText", ""))

	var dur: Dictionary = _dict(meta, "giftDuration")
	gift_event.duration_seconds = float(int(dur.get("seconds", 0))) \
		+ float(int(dur.get("nanos", 0))) / 1_000_000_000.0

	var display: String = str(snippet.get("displayMessage", ""))
	if display.is_empty():
		display = "%s x%d" % [gift_event.gift_name, max(gift_event.combo_count, 1)]
	message = display


func _setup_poll_event(snippet: Dictionary) -> void:
	var meta: Dictionary = _dict(_dict(snippet, "pollDetails"), "metadata")
	poll = PollEvent.new()
	poll.question_text = str(meta.get("questionText", ""))
	poll.status = str(meta.get("status", "unknown"))

	# "options" pode vir como Array (esperado) ou como objeto único.
	var raw_options: Variant = meta.get("options", [])
	var list: Array = raw_options if raw_options is Array else [raw_options]
	for o in list:
		if o is Dictionary:
			poll.options.append({
				"text": str(o.get("optionText", "")),
				"tally": int(str(o.get("tally", "0"))),  # tally só vem p/ o dono do canal
			})

	message = poll.question_text


## --- Utilidades ----------------------------------------------------------

## Converte "2026-08-15T14:23:11.482731Z" -> unix time (UTC).
## O original em C# fazia Substring(0, 22) + ParseExact com ".FF" fixo, o que
## estoura se a fração tiver mais/menos dígitos ou se vier sem fração.
static func parse_iso_timestamp(iso: String) -> int:
	if iso.is_empty():
		return 0
	var clean: String = iso.strip_edges()
	# Descarta a fração de segundo e o sufixo de fuso.
	var dot: int = clean.find(".")
	if dot != -1:
		clean = clean.substr(0, dot)
	clean = clean.trim_suffix("Z")
	var plus: int = clean.find("+", 10)  # ignora possível "+" antes da data
	if plus != -1:
		clean = clean.substr(0, plus)
	return int(Time.get_unix_time_from_datetime_string(clean))


static func _dict(source: Dictionary, key: String) -> Dictionary:
	var v: Variant = source.get(key)
	return v if v is Dictionary else {}


func _to_string() -> String:
	return "[%s] %s: %s" % [Type.keys()[type], username, message]
