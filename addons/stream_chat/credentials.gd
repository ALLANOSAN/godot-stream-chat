class_name StreamChatCredentials
extends RefCounted

## Resolve credenciais SEM guardá-las no projeto.
##
## Motivo: se você puser a API key num @export, ela vai parar dentro do .tscn
## ou do project.godot — e daí pro Git é um passo. Chave do YouTube vazada vira
## cota queimada por terceiros (ou pior, se o projeto tiver outros escopos).
##
## Ordem de busca (primeira que existir ganha):
##   1. valor passado direto no código (útil pra teste rápido)
##   2. variável de ambiente
##   3. arquivo em user:// — fora da pasta do projeto, nunca commitado
##
## No Linux, o user:// fica em:
##   ~/.local/share/godot/app_userdata/<NomeDoProjeto>/

const ENV_YOUTUBE_API_KEY := "YOUTUBE_API_KEY"
const FILE_YOUTUBE_API_KEY := "user://youtube_api_key.txt"


static func youtube_api_key(inline: String = "") -> String:
	return _resolve(inline, ENV_YOUTUBE_API_KEY, FILE_YOUTUBE_API_KEY, "YouTube API key")


static func _resolve(inline: String, env_var: String, file_path: String, label: String) -> String:
	if not inline.is_empty():
		return inline

	var from_env := OS.get_environment(env_var)
	if not from_env.is_empty():
		return from_env.strip_edges()

	if FileAccess.file_exists(file_path):
		var f := FileAccess.open(file_path, FileAccess.READ)
		if f != null:
			var content := f.get_as_text().strip_edges()
			f.close()
			if not content.is_empty():
				return content

	push_error(
		"StreamChat: %s não encontrada. Faça UMA das opções:\n" % label
		+ "  a) exporte a variável de ambiente %s antes de abrir o Godot\n" % env_var
		+ "     (no seu ~/.bashrc:  export %s=\"AIza...\")\n" % env_var
		+ "  b) salve a chave em %s\n" % file_path
		+ "     (use StreamChatCredentials.save_youtube_api_key(\"AIza...\") uma vez)"
	)
	return ""


## Grava a chave no user://. Rode uma vez, de dentro do editor ou do jogo,
## e depois APAGUE a linha que chama isso — senão a chave fica no seu código.
static func save_youtube_api_key(key: String) -> bool:
	var f := FileAccess.open(FILE_YOUTUBE_API_KEY, FileAccess.WRITE)
	if f == null:
		push_error("StreamChat: não consegui escrever em %s" % FILE_YOUTUBE_API_KEY)
		return false
	f.store_string(key.strip_edges())
	f.close()
	print("StreamChat: chave salva em %s (fora do projeto, seguro pro Git)."
		% ProjectSettings.globalize_path(FILE_YOUTUBE_API_KEY))
	return true


static func has_youtube_api_key() -> bool:
	return not OS.get_environment(ENV_YOUTUBE_API_KEY).is_empty() \
		or FileAccess.file_exists(FILE_YOUTUBE_API_KEY)
