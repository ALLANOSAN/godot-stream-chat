extends Node2D

## Corrida de Chat — jogo de exemplo do addon StreamChat.
##
## Regra: qualquer mensagem no chat coloca o espectador na pista. Cada "!corre"
## avança um passo. Quem cruza a meta primeiro vence, o placar aparece e a
## partida seguinte começa sozinha.
##
## Por que corrida e não um jogo de reflexo: o chat do YouTube chega em lote a
## cada ~5s. Comando de reação chegaria sempre tarde demais. Corrida é
## acumulativa — só importa QUANTOS "!corre" chegaram, nunca quando.
##
## Este nó é só cola: traduz sinais do ChatProvider em chamadas do CorridaChat
## e desenha o resultado. A regra do jogo mora em corrida_chat.gd, que é o que
## os testes exercitam (jogo/teste_corrida.gd).

## Comando que faz o corredor avançar, sem o prefixo "!".
@export var comando: String = "corre"

@export var passo: float = 8.0
@export var meta: float = 900.0

## Segundos que o placar do vencedor fica na tela antes da próxima partida.
@export var pausa_entre_partidas: float = 8.0

## Quantas raias cabem na tela. O resto vira "+N correndo" no rodapé.
@export var raias_visiveis: int = 13

const MARGEM_ESQ := 180.0
const MARGEM_DIR := 60.0
const TOPO := 110.0
const ALTURA_RAIA := 34.0

const COR_FUNDO := Color("14161c")
const COR_PISTA := Color("222633")
const COR_META := Color("e8c34a")
const COR_TEXTO := Color("d9dde8")
const COR_APAGADO := Color("6b7285")

var _corrida := CorridaChat.new()
var _provider: ChatProvider
var _status: String = "conectando..."
var _partidas: int = 0
var _pausa_restante: float = 0.0
var _fonte: Font


func _ready() -> void:
	_fonte = ThemeDB.fallback_font
	_corrida.passo = passo
	_corrida.meta = meta

	for filho in get_children():
		if filho is ChatProvider:
			_provider = filho
			break

	if _provider == null:
		_status = "nenhum ChatProvider como filho desta cena"
		push_error("Corrida de Chat: adicione um YouTubeChatProvider como filho.")
		return

	_provider.command_prefix = "!"
	_provider.user_joined.connect(_ao_entrar)
	_provider.user_left.connect(_ao_sair)
	_provider.user_command.connect(_ao_comando)
	_provider.provider_connected.connect(_ao_conectar)
	_provider.provider_disconnected.connect(_ao_desconectar)

	_provider.connect_chat()


# ------------------------------------------------------------------- chat

func _ao_conectar() -> void:
	_status = "no ar"


func _ao_desconectar(motivo: String) -> void:
	_status = "desconectado (%s)" % motivo


func _ao_entrar(user: ChatProvider.ChatUser) -> void:
	_corrida.entrar(user.id, user.display_name)


func _ao_sair(user: ChatProvider.ChatUser) -> void:
	_corrida.sair(user.id)


func _ao_comando(user: ChatProvider.ChatUser, cmd: String, _args: PackedStringArray) -> void:
	if cmd != comando:
		return
	_corrida.correr(user.id)
	if not _corrida.vencedor().is_empty() and _pausa_restante <= 0.0:
		_pausa_restante = pausa_entre_partidas


# ------------------------------------------------------------------- loop

func _process(delta: float) -> void:
	if _pausa_restante > 0.0:
		_pausa_restante -= delta
		if _pausa_restante <= 0.0:
			_partidas += 1
			_corrida.reiniciar()
	queue_redraw()


## Teclas só para conferir o visual sem estar ao vivo.
##   T = entra um bot    ESPAÇO = todo bot dá um passo
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	match (event as InputEventKey).keycode:
		KEY_T:
			var n := _corrida.corredores().size() + 1
			_corrida.entrar("bot:%d" % n, "bot_%d" % n)
		KEY_SPACE:
			for c in _corrida.corredores():
				if c.id.begins_with("bot:"):
					_ao_comando_local(c.id)


func _ao_comando_local(id: String) -> void:
	_corrida.correr(id)
	if not _corrida.vencedor().is_empty() and _pausa_restante <= 0.0:
		_pausa_restante = pausa_entre_partidas


# ---------------------------------------------------------------- desenho

func _draw() -> void:
	var tela := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, tela), COR_FUNDO)

	var largura_pista := tela.x - MARGEM_ESQ - MARGEM_DIR
	var escala := largura_pista / meta

	_desenha_cabecalho(tela)
	_desenha_meta(largura_pista)

	var lista := _ranking()
	for i in mini(lista.size(), raias_visiveis):
		_desenha_raia(lista[i], i, escala)

	if lista.size() > raias_visiveis:
		draw_string(_fonte, Vector2(MARGEM_ESQ, TOPO + raias_visiveis * ALTURA_RAIA + 20),
			"+%d correndo" % (lista.size() - raias_visiveis),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, COR_APAGADO)

	if lista.is_empty():
		draw_string(_fonte, Vector2(MARGEM_ESQ, TOPO + 40),
			"pista vazia — a primeira mensagem no chat já entra na corrida",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 17, COR_APAGADO)

	if not _corrida.vencedor().is_empty():
		_desenha_vencedor(tela)


## Cópia ordenada por posição: vira placar ao vivo em vez de ordem de chegada
## no chat. A lógica devolve ordem de entrada de propósito — ordenar é decisão
## de apresentação.
func _ranking() -> Array:
	var lista := _corrida.corredores().duplicate()
	lista.sort_custom(func(a, b): return a.posicao > b.posicao)
	return lista


func _desenha_cabecalho(tela: Vector2) -> void:
	draw_string(_fonte, Vector2(MARGEM_ESQ, 46), "CORRIDA DE CHAT",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 30, COR_TEXTO)

	var info := "%s   ·   %d na pista   ·   partida %d" % [
		_status, _corrida.corredores().size(), _partidas + 1]
	draw_string(_fonte, Vector2(MARGEM_ESQ, 70), info,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, COR_APAGADO)

	# O YouTube engole mensagem idêntica repetida. Sem número no fim, o segundo
	# "!corre" do mesmo espectador nunca sai — e o jogo nem fica sabendo, então
	# pareceria travamento. A instrução na tela é o contorno.
	draw_string(_fonte, Vector2(MARGEM_ESQ, 92),
		"digite  !%s 1  ·  !%s 2  ·  !%s 3 …   (o YouTube barra mensagem repetida igual)"
			% [comando, comando, comando],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, COR_META.darkened(0.15))

	draw_string(_fonte, Vector2(tela.x - MARGEM_DIR - 210, 46), "T: bot   ESPAÇO: bot corre",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, COR_PISTA.lightened(0.25))


func _desenha_meta(largura_pista: float) -> void:
	var x := MARGEM_ESQ + largura_pista
	var altura := mini(_corrida.corredores().size(), raias_visiveis) * ALTURA_RAIA
	draw_line(Vector2(x, TOPO - 14), Vector2(x, TOPO + maxf(altura, 40.0)), COR_META, 3.0)
	draw_string(_fonte, Vector2(x - 18, TOPO - 22), "META",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, COR_META)


func _desenha_raia(c: CorridaChat.Corredor, indice: int, escala: float) -> void:
	var y := TOPO + indice * ALTURA_RAIA
	var venceu := c.id == _corrida.vencedor()
	var cor := COR_META if venceu else _cor_do(c.id)

	draw_string(_fonte, Vector2(20, y + 15), c.nome.left(16),
		HORIZONTAL_ALIGNMENT_LEFT, MARGEM_ESQ - 40, 16,
		COR_TEXTO if venceu else COR_APAGADO)

	var trilho := Rect2(MARGEM_ESQ, y + 4, meta * escala, 16)
	draw_rect(trilho, COR_PISTA)

	var avanco := c.posicao * escala
	if avanco > 0.0:
		draw_rect(Rect2(MARGEM_ESQ, y + 4, avanco, 16), cor)

	draw_circle(Vector2(MARGEM_ESQ + avanco, y + 12), 7.0, cor)


func _desenha_vencedor(tela: Vector2) -> void:
	var c: CorridaChat.Corredor = null
	for r in _corrida.corredores():
		if r.id == _corrida.vencedor():
			c = r
			break
	if c == null:
		return

	# Abaixo das raias, não por cima: com a partida decidida o placar ainda é a
	# informação que a live quer ver.
	var raias := mini(_corrida.corredores().size(), raias_visiveis)
	var topo := minf(TOPO + raias * ALTURA_RAIA + 50.0, tela.y - 150.0)

	var caixa := Rect2(0, topo, tela.x, 120)
	draw_rect(caixa, COR_FUNDO.darkened(0.35))
	draw_line(caixa.position, Vector2(tela.x, topo), COR_META, 2.0)
	draw_line(Vector2(0, caixa.end.y), caixa.end, COR_META, 2.0)

	draw_string(_fonte, Vector2(0, topo + 58), "%s VENCEU" % c.nome.to_upper(),
		HORIZONTAL_ALIGNMENT_CENTER, tela.x, 40, COR_META)
	draw_string(_fonte, Vector2(0, topo + 92),
		"próxima partida em %d..." % int(ceil(_pausa_restante)),
		HORIZONTAL_ALIGNMENT_CENTER, tela.x, 17, COR_APAGADO)


## Cor estável por usuário: o mesmo espectador tem sempre a mesma cor, sem
## precisar guardar nada.
##
## O hash de String do Godot é sequencial — "yt:1" e "yt:2" saem com hashes
## vizinhos e virariam o mesmo tom. O embaralhador de bits (finalizador do
## murmur3) espalha os vizinhos pelo círculo de cores inteiro.
static func _cor_do(id: String) -> Color:
	var h := hash(id)
	h = (h ^ (h >> 16)) * 0x45d9f3b
	h = (h ^ (h >> 16)) & 0xffff
	return Color.from_hsv(float(h) / 65536.0, 0.55, 0.95)
