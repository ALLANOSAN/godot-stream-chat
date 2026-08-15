extends Node

## StreamChat — teste de conexão.
##
## COMO USAR
##   1. Cena nova, nó raiz Node, este script anexado.
##   2. Adicione um filho YouTubeChatProvider.
##   3. No inspector do provider, preencha channel_id (ou video_id).
##   4. Abra uma live no seu canal.
##   5. Rode a cena (F6) e digite "!teste 45 80" no chat da live.
##
## O que este script faz que um print solto não faz: valida cada camada em
## ordem e diz exatamente onde parou. Se falhar no passo 2, não adianta olhar
## o passo 4.

@export var timeout_segundos: float = 90.0

var _provider: ChatProvider
var _conectou: bool = false
var _recebeu_mensagem: bool = false
var _recebeu_comando: bool = false


func _ready() -> void:
	print_rich("\n[b]=== StreamChat — teste de conexão ===[/b]\n")

	if not _passo_1_encontrar_provider():
		return
	if not _passo_2_credencial():
		return
	_passo_3_conectar()


# ---------------------------------------------------------------- passo 1

func _passo_1_encontrar_provider() -> bool:
	for filho in get_children():
		if filho is ChatProvider:
			_provider = filho
			break

	if _provider == null:
		printerr("[1/3] FALHOU: nenhum ChatProvider como filho desta cena.")
		printerr("      Adicione um nó YouTubeChatProvider como filho.")
		return false

	print("[1/3] OK — provider encontrado: %s (tag '%s')"
		% [_provider.get_class(), _provider.platform_tag()])

	if _provider is YouTubeChatProvider:
		var yt := _provider as YouTubeChatProvider
		var alvo := yt.video_id if not yt.video_id.is_empty() else yt.channel_id
		if alvo.is_empty():
			printerr("      FALHOU: preencha channel_id ou video_id no inspector.")
			return false
		print("      backend=%s alvo=%s"
			% ["PYTCHAT_SIDECAR" if yt.backend == YouTubeChatProvider.Backend.PYTCHAT_SIDECAR
				else "OFFICIAL_API", alvo])
	return true


# ---------------------------------------------------------------- passo 2

func _passo_2_credencial() -> bool:
	if not (_provider is YouTubeChatProvider):
		print("[2/3] pulado — credencial só se aplica ao YouTube.")
		return true

	var yt := _provider as YouTubeChatProvider
	if yt.backend == YouTubeChatProvider.Backend.PYTCHAT_SIDECAR:
		print("[2/3] pulado — backend pytchat não usa API key.")
		return true

	if not yt.api_key.is_empty():
		print("[2/3] OK — usando a key do inspector (só para teste; não commite).")
		return true

	if StreamChatCredentials.has_youtube_api_key():
		print("[2/3] OK — key encontrada fora do projeto.")
		return true

	printerr("[2/3] FALHOU: nenhuma API key encontrada.")
	printerr("      export YOUTUBE_API_KEY=\"AIza...\" no ~/.bashrc e REABRA o Godot,")
	printerr("      ou rode uma vez: StreamChatCredentials.save_youtube_api_key(\"AIza...\")")
	return false


# ---------------------------------------------------------------- passo 3

func _passo_3_conectar() -> void:
	_provider.provider_connected.connect(_ao_conectar)
	_provider.provider_disconnected.connect(_ao_desconectar)
	_provider.user_joined.connect(_ao_entrar)
	_provider.user_message.connect(_ao_mensagem)
	_provider.user_command.connect(_ao_comando)
	_provider.user_donated.connect(_ao_doar)

	print("[3/3] conectando... (digite \"!teste 45 80\" no chat da live)")
	_provider.connect_chat()

	await get_tree().create_timer(timeout_segundos).timeout
	_relatorio()


func _ao_conectar() -> void:
	_conectou = true
	print_rich("      [color=green]CONECTADO[/color]")


func _ao_desconectar(motivo: String) -> void:
	printerr("      DESCONECTADO: %s" % motivo)
	match motivo:
		"chatEnded":
			printerr("      A live não está ativa ou o chat está desativado.")
		"quota":
			printerr("      Cota diária esgotada. Reseta à meia-noite (horário do Pacífico).")


func _ao_entrar(user: ChatProvider.ChatUser) -> void:
	print("      ENTROU: %s  (id=%s)" % [user.display_name, user.id])
	var papeis: Array[String] = []
	if user.is_broadcaster: papeis.append("dono")
	if user.is_moderator: papeis.append("mod")
	if user.is_subscriber: papeis.append("membro")
	if not papeis.is_empty():
		print("              papéis: %s" % ", ".join(papeis))


func _ao_mensagem(user: ChatProvider.ChatUser, texto: String) -> void:
	_recebeu_mensagem = true
	print("      MSG [%s] %s" % [user.display_name, texto])


func _ao_comando(user: ChatProvider.ChatUser, cmd: String, args: PackedStringArray) -> void:
	_recebeu_comando = true
	print_rich("      [color=cyan]CMD[/color] !%s  args=%s  de=%s"
		% [cmd, str(args), user.display_name])


func _ao_doar(user: ChatProvider.ChatUser, tier: int, valor: String, texto: String) -> void:
	print("      DOAÇÃO tier=%d %s de %s: %s" % [tier, valor, user.display_name, texto])


func _relatorio() -> void:
	print_rich("\n[b]=== resultado após %ds ===[/b]" % int(timeout_segundos))
	print("  conectou ............ %s" % ("SIM" if _conectou else "NÃO"))
	print("  recebeu mensagem .... %s" % ("SIM" if _recebeu_mensagem else "NÃO"))
	print("  recebeu comando ..... %s" % ("SIM" if _recebeu_comando else "NÃO"))
	print("  usuários ativos ..... %d" % _provider.get_active_count())

	if _conectou and _recebeu_comando:
		print_rich("\n[color=green]Tudo funcionando.[/color] "
			+ "Troque os prints pelas funções do seu jogo.\n")
	elif _conectou and not _recebeu_mensagem:
		print_rich("\n[color=yellow]Conectou mas não veio nada.[/color]")
		print("  - alguém digitou algo no chat durante o teste?")
		print("  - skip_history descarta o backlog: só conta o que for digitado DEPOIS de conectar")
		print("  - chat em modo lento ou só-membros?\n")
	elif _conectou and _recebeu_mensagem and not _recebeu_comando:
		print_rich("\n[color=yellow]Mensagens chegam, comandos não.[/color]")
		print("  Confira command_prefix (padrão \"!\") e mande algo como \"!teste 1 2\".\n")
	else:
		print_rich("\n[color=red]Não conectou.[/color] Role para cima e leia o primeiro erro.\n")
