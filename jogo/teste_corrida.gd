extends SceneTree

## Testes da lógica da corrida. Roda sem abrir o editor:
##
##     godot --headless --script res://jogo/teste_corrida.gd
##
## Sai com código 1 se algo falhar, então serve em CI também.

var _falhas: int = 0


func _initialize() -> void:
	_corredor_novo_comeca_na_largada()
	_correr_avanca_um_passo()
	_quem_cruza_a_meta_vence_e_congela_a_pista()
	_sair_tira_da_pista()
	_entrar_de_novo_nao_zera_o_progresso()
	_reiniciar_zera_a_pista_mas_mantem_a_galera()

	if _falhas > 0:
		print("\n%d teste(s) FALHOU" % _falhas)
		quit(1)
	else:
		print("\ntudo passou")
		quit(0)


func _corredor_novo_comeca_na_largada() -> void:
	var corrida := CorridaChat.new()
	corrida.entrar("yt:abc", "joao")
	_igual(corrida.posicao("yt:abc"), 0.0, "corredor novo começa na largada")


func _correr_avanca_um_passo() -> void:
	var corrida := CorridaChat.new()
	corrida.passo = 8.0
	corrida.entrar("yt:abc", "joao")

	corrida.correr("yt:abc")
	_igual(corrida.posicao("yt:abc"), 8.0, "um !corre avança um passo")

	corrida.correr("yt:abc")
	corrida.correr("yt:abc")
	_igual(corrida.posicao("yt:abc"), 24.0, "três !corre avançam três passos")


func _quem_cruza_a_meta_vence_e_congela_a_pista() -> void:
	var corrida := CorridaChat.new()
	corrida.passo = 10.0
	corrida.meta = 30.0
	corrida.entrar("yt:joao", "joao")
	corrida.entrar("yt:maria", "maria")

	corrida.correr("yt:joao")
	corrida.correr("yt:joao")
	_igual(corrida.vencedor(), "", "sem vencedor antes da meta")

	corrida.correr("yt:joao")
	_igual(corrida.vencedor(), "yt:joao", "cruzou a meta, venceu")

	# Chat do YouTube chega em lote: os !corre dos outros continuam pingando
	# depois que alguém já ganhou. Ninguém pode andar mais.
	corrida.correr("yt:maria")
	_igual(corrida.posicao("yt:maria"), 0.0, "corrida acabada não aceita mais !corre")


func _sair_tira_da_pista() -> void:
	var corrida := CorridaChat.new()
	corrida.entrar("yt:joao", "joao")
	corrida.entrar("yt:maria", "maria")
	_igual(corrida.corredores().size(), 2, "dois corredores na pista")

	corrida.sair("yt:joao")
	_igual(corrida.corredores().size(), 1, "quem sai some da pista")
	_igual(corrida.corredores()[0].id, "yt:maria", "quem ficou é o certo")
	_igual(corrida.corredores()[0].nome, "maria", "nome preservado para o desenho")


func _entrar_de_novo_nao_zera_o_progresso() -> void:
	# Reconexão do provider reemite user_joined de quem já estava jogando.
	# Zerar aí apagaria o progresso de todo mundo no meio da live.
	var corrida := CorridaChat.new()
	corrida.passo = 10.0
	corrida.entrar("yt:joao", "joao")
	corrida.correr("yt:joao")
	corrida.correr("yt:joao")

	corrida.entrar("yt:joao", "joao_mudou_o_nick")
	_igual(corrida.posicao("yt:joao"), 20.0, "reentrada mantém a posição")
	_igual(corrida.corredores()[0].nome, "joao_mudou_o_nick", "reentrada atualiza o nome")


func _reiniciar_zera_a_pista_mas_mantem_a_galera() -> void:
	# Quem já está na live não precisa mandar mensagem de novo para a partida
	# seguinte — só perderia os primeiros 5s esperando o próximo poll.
	var corrida := CorridaChat.new()
	corrida.passo = 10.0
	corrida.meta = 20.0
	corrida.entrar("yt:joao", "joao")
	corrida.entrar("yt:maria", "maria")
	corrida.correr("yt:maria")
	corrida.correr("yt:joao")
	corrida.correr("yt:joao")

	corrida.reiniciar()
	_igual(corrida.vencedor(), "", "reiniciar limpa o vencedor")
	_igual(corrida.posicao("yt:joao"), 0.0, "reiniciar volta o vencedor pra largada")
	_igual(corrida.posicao("yt:maria"), 0.0, "reiniciar volta os outros pra largada")
	_igual(corrida.corredores().size(), 2, "reiniciar não expulsa ninguém")

	corrida.correr("yt:maria")
	_igual(corrida.posicao("yt:maria"), 10.0, "dá pra correr de novo depois do reinício")


# ------------------------------------------------------------------ asserts

func _igual(obtido: Variant, esperado: Variant, oque: String) -> void:
	if obtido == esperado:
		print("  ok   %s" % oque)
	else:
		_falhas += 1
		printerr("  FALHA %s\n        esperado %s, obtido %s" % [oque, esperado, obtido])
