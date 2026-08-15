@tool
extends EditorPlugin

## StreamChat — plugin entry point.
##
## Os nós usam `class_name`, então o Godot 4 já os mostra sozinho no diálogo
## "Adicionar Nó". Este script existe para:
##   1. permitir habilitar/desabilitar o addon nas configurações do projeto
##   2. avisar na hora certa se o addon foi instalado no caminho errado
##   3. NÃO guardar credencial nenhuma no project.godot (ver credentials.gd)

const EXPECTED_PATH := "res://addons/stream_chat"


func _enter_tree() -> void:
	if not get_script().resource_path.begins_with(EXPECTED_PATH):
		push_error(
			"StreamChat: o addon precisa estar exatamente em '%s'. "
			% EXPECTED_PATH
			+ "Encontrado em '%s'. Mova a pasta e reative o plugin."
			% get_script().resource_path.get_base_dir()
		)
		return

	print_rich("[color=green]StreamChat[/color] ativo. "
		+ "Credenciais: veja addons/stream_chat/README.md — "
		+ "nunca coloque a API key direto na cena.")


func _exit_tree() -> void:
	pass
