class_name YouTubeChatSidecar
extends Node

## Backend alternativo do YouTube: sem API key, sem cota.
##
## Roda o pytchat_bridge.py como processo filho e lê o stdout dele linha a
## linha. Emite EXATAMENTE os mesmos sinais que o YouTubeChatClient, então é
## substituível sem tocar no resto do addon.
##
## REQUISITOS
##   - Godot 4.3+ (usa OS.execute_with_pipe)
##   - Python 3 no PATH
##   - pip install --user pytchat
##
## LIMITAÇÃO ACEITA
##   O pytchat consome a InnerTube, a API interna do player do YouTube. Não é
##   documentada e muda sem aviso. Isso funciona bem hoje e pode quebrar
##   amanhã — é o preço de não ter cota. Para algo que precisa ser estável,
##   use o YouTubeChatClient (API oficial).
##
## Só faz sentido porque o jogo roda na SUA máquina (a de stream). Os
## espectadores só assistem, então a dependência de Python não é distribuída.

signal connected(video_id: String)
signal message_received(msg: YouTubeChatMessage)
signal chat_ended()
signal api_error(http_code: int, reason: String, description: String)

const BRIDGE_RES_PATH := "res://addons/stream_chat/youtube/pytchat_bridge.py"
const BRIDGE_USER_PATH := "user://pytchat_bridge.py"

## Descarta o lote inicial (histórico) para não spawnar o chat inteiro.
@export var skip_history: bool = true

## Executável do Python. No CachyOS/Arch, "python" já é o 3.
@export var python_executable: String = "python3"

var _pid: int = -1
var _stdio: FileAccess
var _stderr: FileAccess
var _thread: Thread
var _mutex: Mutex
var _queue: Array[String] = []
var _running: bool = false
var _in_history: bool = false


func _ready() -> void:
	_mutex = Mutex.new()
	set_process(false)


## --- API pública (espelha o YouTubeChatClient) ---------------------------

func start_from_video_id(video_id: String, _api_key: String = "") -> void:
	_launch(video_id)


func start_from_channel_id(channel_id: String) -> void:
	# A ponte resolve a live ativa lendo a página /live do canal.
	_launch("channel:" + channel_id)


func stop() -> void:
	_running = false
	set_process(false)

	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1

	# Matar o processo fecha o pipe, o que faz o get_line() da thread
	# retornar EOF e ela encerrar sozinha.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	_stdio = null
	_stderr = null


func is_running() -> bool:
	return _running


## --- Interno -------------------------------------------------------------

func _launch(target: String) -> void:
	var script_path := _ensure_script_on_disk()
	if script_path.is_empty():
		return

	var result: Dictionary = OS.execute_with_pipe(
		python_executable, [script_path, target]
	)

	if result.is_empty() or not result.has("pid"):
		api_error.emit(0, "spawnFailed",
			"Não consegui rodar '%s'. Está instalado e no PATH?" % python_executable)
		return

	_pid = int(result["pid"])
	_stdio = result.get("stdio")
	_stderr = result.get("stderr")

	if _stdio == null:
		api_error.emit(0, "noPipe",
			"OS.execute_with_pipe não devolveu stdio. Precisa de Godot 4.3+.")
		return

	_running = true
	_thread = Thread.new()
	_thread.start(_reader_loop)
	set_process(true)


## Em build exportada, os arquivos de res:// vivem dentro do .pck e não existem
## no disco — então o Python não conseguiria abrir o .py. Copiamos para user://
## na primeira execução.
func _ensure_script_on_disk() -> String:
	var src := FileAccess.open(BRIDGE_RES_PATH, FileAccess.READ)
	if src == null:
		api_error.emit(0, "bridgeMissing",
			"Não achei %s dentro do addon." % BRIDGE_RES_PATH)
		return ""

	var content := src.get_as_text()
	src.close()

	var dst := FileAccess.open(BRIDGE_USER_PATH, FileAccess.WRITE)
	if dst == null:
		api_error.emit(0, "bridgeWriteFailed",
			"Não consegui escrever em %s." % BRIDGE_USER_PATH)
		return ""
	dst.store_string(content)
	dst.close()

	return ProjectSettings.globalize_path(BRIDGE_USER_PATH)


## Roda em thread separada: get_line() bloqueia, e travar o loop do jogo a
## cada mensagem de chat seria inaceitável num jogo.
func _reader_loop() -> void:
	while _running and _stdio != null and _stdio.is_open():
		var line := _stdio.get_line()
		if _stdio.eof_reached():
			break
		if line.strip_edges().is_empty():
			continue
		_mutex.lock()
		_queue.append(line)
		_mutex.unlock()


func _process(_delta: float) -> void:
	if not _running:
		return

	_mutex.lock()
	var batch := _queue.duplicate()
	_queue.clear()
	_mutex.unlock()

	for line in batch:
		_handle_line(line)


func _handle_line(line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if not (parsed is Dictionary):
		return

	# Mensagens de controle da ponte
	if parsed.has("_bridge"):
		match str(parsed["_bridge"]):
			"ready":
				connected.emit(str(parsed.get("video_id", "")))
			"history_start":
				_in_history = true
			"history_end":
				_in_history = false
			"ended":
				_running = false
				chat_ended.emit()
			"error":
				api_error.emit(0, str(parsed.get("reason", "unknown")),
					str(parsed.get("message", "")))
		return

	if _in_history and skip_history:
		return

	# Formato idêntico ao da API oficial (CompatibleProcessor), então o parser
	# existente serve sem mudança nenhuma.
	var msg := YouTubeChatMessage.from_json(parsed)
	if msg.type == YouTubeChatMessage.Type.CHAT_ENDED:
		_running = false
		chat_ended.emit()
		return
	message_received.emit(msg)


func _exit_tree() -> void:
	# Sem isso, fechar o jogo deixa um Python órfão consumindo rede.
	stop()
