class_name CorridaChat
extends RefCounted

## Lógica da corrida. Sem Godot, sem desenho, sem rede — só regra.
## É isto que os testes exercitam; o nó da cena só liga sinais nestes métodos.

## Pixels que um !corre avança.
var passo: float = 8.0

## Distância da largada até a linha de chegada, em pixels.
var meta: float = 900.0

var _corredores: Dictionary = {}   ## user_id -> Corredor
var _vencedor: String = ""


class Corredor extends RefCounted:
	var id: String = ""
	var nome: String = ""
	var posicao: float = 0.0


## Primeira mensagem de um espectador. Chamar de novo com o mesmo id só
## atualiza o nome — reconexão do provider não pode apagar o progresso.
func entrar(id: String, nome: String) -> void:
	if _corredores.has(id):
		_corredores[id].nome = nome
		return

	var c := Corredor.new()
	c.id = id
	c.nome = nome
	_corredores[id] = c


func correr(id: String) -> void:
	if not _vencedor.is_empty():
		return
	if not _corredores.has(id):
		return

	var c: Corredor = _corredores[id]
	c.posicao += passo
	if c.posicao >= meta:
		_vencedor = id


func sair(id: String) -> void:
	_corredores.erase(id)


## Nova partida com a mesma galera: todo mundo volta pra largada.
func reiniciar() -> void:
	_vencedor = ""
	for c in _corredores.values():
		c.posicao = 0.0


## "" enquanto ninguém cruzou a meta.
func vencedor() -> String:
	return _vencedor


func posicao(id: String) -> float:
	if not _corredores.has(id):
		return 0.0
	return _corredores[id].posicao


## Ordem de entrada — a raia de cada um não muda no meio da corrida.
func corredores() -> Array:
	return _corredores.values()
