# StreamChat

Addon Godot 4 que transforma chat de live em entrada de jogo. YouTube e Twitch
pela **mesma interface**: o jogo escuta um conjunto de sinais e não precisa
saber de onde o jogador veio.

Feito para jogos por turnos tipo Worms, onde só o streamer roda o jogo e o
público joga digitando comandos no chat.

> **Quem instala o quê:** só você. Espectadores não instalam nada, não linkam
> conta, não abrem nada — só digitam no chat da live, igual já fazem na Twitch.

**O que é o quê neste repositório:**

| Pasta | O que é |
|---|---|
| `addons/stream_chat/` | **o addon** — é isto que você usa no seu jogo |
| `jogo/` | um exemplo pronto ("Corrida de Chat"), só para ver funcionando |

O `jogo/` não é dependência de nada e pode ser apagado. Ele existe para você
confirmar que a ligação com a live está de pé antes de mexer no seu próprio
jogo — se a corrida anda quando o chat digita, o addon está funcionando e o
problema seguinte é seu, não dele.

Para usar no seu jogo, o caminho é: [Instalação](#instalação) →
[Apontar para a sua live](#apontar-para-a-sua-live) →
[Referência da API](#referência-da-api). O
[exemplo tipo Worms](#exemplo-completo-jogo-tipo-worms) mostra o formato de um
jogo real.

---

## Índice

1. [Instalação](#instalação)
2. [Credenciais](#credenciais)
   · [Apontar para a sua live](#apontar-para-a-sua-live) — pública vs. não listada
3. [Referência da API](#referência-da-api)
4. [Jogo de exemplo: Corrida de Chat](#jogo-de-exemplo-corrida-de-chat)
5. [Exemplo completo: jogo tipo Worms](#exemplo-completo-jogo-tipo-worms)
6. [Backend alternativo: pytchat](#backend-alternativo-pytchat-sem-cota-sem-api-key)
7. [Instalar o pytchat](#instalar-o-pytchat) — Linux e Windows
8. [Roteiro de teste](#roteiro-de-teste)
9. [Pegadinhas](#pegadinhas)
10. [Estado do código](#estado-do-código)

---

## Instalação

1. Copie a pasta `stream_chat` para `res://addons/`.
   Caminho final obrigatório: `res://addons/stream_chat`.
2. `Projeto → Configurações do Projeto → Plugins` → **Enable**.

Requer **Godot 4.3+** se for usar o backend pytchat (`OS.execute_with_pipe`).
O backend oficial funciona em 4.x.

Para a parte da Twitch você também precisa do
[Twitcher](https://github.com/kanimaru/twitcher) instalado separadamente. Se
só usa YouTube, pode apagar a pasta `twitch/` — o `core/` não depende dela.

---

## Credenciais

Só o backend `OFFICIAL_API` precisa de chave. Pegue em
`console.cloud.google.com` → novo projeto → ative **YouTube Data API v3** →
Credenciais → Chave de API. Para *ler* chat de live pública não precisa OAuth.

**Nunca ponha a chave no inspector** — ela iria parar dentro do `.tscn` e daí
pro Git. Escolha uma:

```bash
# A — variável de ambiente (no ~/.bashrc, depois reabra o Godot)
export YOUTUBE_API_KEY="AIza..."
```

```gdscript
# B — rode UMA vez e apague a linha depois
StreamChatCredentials.save_youtube_api_key("AIza...")
```

A opção B grava em `user://youtube_api_key.txt`
(`~/.local/share/godot/app_userdata/<projeto>/` no Linux), fora do projeto.

### Apontar para a sua live

O `YouTubeChatProvider` tem dois campos, `channel_id` e `video_id`. **Preencha
só um.** Qual deles depende da visibilidade da sua transmissão — e errar aqui é
a causa mais comum de "conectou mas não chega nada".

Se os dois estiverem preenchidos, **`video_id` ganha**.

#### Live pública → use `channel_id`

É a opção boa: o ID do canal não muda nunca, então você configura uma vez e
esquece. A cada live o addon descobre sozinho qual é o vídeo do momento.

O `channel_id` não é login e não é o seu `@handle` — é o identificador público
do canal, no formato `UC` + 22 caracteres (`UCX6OQ3DkcsbYNE6H8uQQuVA`).

- YouTube Studio → **Configurações** → **Canal** → **Configurações avançadas**
- ou direto em [youtube.com/account_advanced](https://www.youtube.com/account_advanced)

#### Live não listada ou privada → use `video_id`

A descoberta automática lê a página pública `youtube.com/channel/<ID>/live`, e
**essa página só enxerga live pública**. Com transmissão não listada ou privada
ela não acha nada, e a ponte responde:

```json
{"_bridge": "error", "reason": "noActiveLive", "message": "Nenhuma live pública no ar em UC... Se a transmissão for não listada ou privada, o /live não a enxerga: passe o video_id direto."}
```

Aí o caminho é pegar o ID no **link da própria live** e pôr em `video_id`:

```
https://youtube.com/live/AbCdEfGhIjK?feature=share
                        └─────────┘
                         video_id = AbCdEfGhIjK
```

Serve qualquer formato de link do YouTube — `youtu.be/ID`, `watch?v=ID`,
`/live/ID`. São sempre 11 caracteres.

> **O `video_id` muda a cada transmissão.** Live nova, ID novo, e você precisa
> atualizar antes de começar. É o preço de usar live não listada; se puder
> deixar a live pública, o `channel_id` evita esse passo pra sempre.

#### Em nenhum caso há login

O backend oficial lê com API key, o pytchat lê a página pública da live. Você
não vincula conta nenhuma, nem a sua — e por isso você mesmo entra no jogo do
mesmo jeito que o público: digitando no chat.

---

## Referência da API

### `ChatProvider` (classe base — não instancie diretamente)

**Sinais** — é só isso que o jogo precisa escutar:

| Sinal | Assinatura | Quando dispara |
|---|---|---|
| `user_joined` | `(user: ChatUser)` | primeira mensagem de um usuário |
| `user_left` | `(user: ChatUser)` | timeout de inatividade |
| `user_message` | `(user, text: String)` | qualquer mensagem de texto |
| `user_command` | `(user, command: String, args: PackedStringArray)` | mensagem começando com o prefixo |
| `user_donated` | `(user, tier: int, amount_display: String, text: String)` | bits / Super Chat / Sticker / Jewels |
| `user_subscribed` | `(user, months: int)` | sub (Twitch) / membership (YouTube) |
| `provider_connected` | `()` | conectado ao chat |
| `provider_disconnected` | `(reason: String)` | `"manual"`, `"chatEnded"`, `"quota"` |

`user_message` **sempre** dispara, inclusive para comandos. Se você escuta os
dois, um `!atacar` chega nos dois sinais.

**Propriedades:**

| Nome | Tipo | Padrão | Papel |
|---|---|---|---|
| `command_prefix` | `String` | `"!"` | vazio desativa parsing de comandos |
| `inactivity_timeout` | `float` | `300.0` | segundos até `user_left`. **`0` desativa** |
| `presence_sweep_interval` | `float` | `15.0` | intervalo da varredura de inativos |

**Métodos:**

```gdscript
func connect_chat() -> void          # sobrescrito pelas subclasses
func disconnect_chat() -> void
func platform_tag() -> String        # "yt" / "tw"
func get_user(user_id: String) -> ChatUser
func get_active_users() -> Array     # Array[ChatUser]
func get_active_count() -> int
func clear_users(emit_left: bool = true) -> void
```

### `ChatProvider.ChatUser`

```gdscript
var id: String              # identidade ESTÁVEL. use isto como chave, sempre
var display_name: String    # muda e pode repetir. nunca use como chave
var avatar_url: String      # YouTube preenche; Twitch não
var platform: int           # ChatProvider.Platform.TWITCH | .YOUTUBE
var is_broadcaster: bool
var is_moderator: bool
var is_subscriber: bool     # sub (Twitch) / membro (YouTube)
var is_verified: bool
var first_seen_unix: int
var last_seen_unix: int
var metadata: Dictionary    # LIVRE. guarde aqui o nó do worm, vida, score…
```

O `metadata` é o gancho pro seu jogo. Guardar `user.metadata["worm"] = node`
evita você manter um dicionário paralelo.

### `YouTubeChatProvider`

```gdscript
enum Backend { OFFICIAL_API, PYTCHAT_SIDECAR }

@export var backend: Backend = Backend.OFFICIAL_API
@export var api_key: String = ""      # deixe vazio; usa StreamChatCredentials
@export var channel_id: String = ""   # resolve a live ativa sozinho
@export var video_id: String = ""     # alternativa: ID direto (ganha do channel_id)
@export var min_poll_interval: float = 5.0
@export var python_executable: String = "python3"   # só no PYTCHAT_SIDECAR

func attentive() -> void   # esperando input agora
func idle() -> void        # animação, ninguém precisa ser ouvido
func dormant() -> void     # downtime entre partidas
```

Preencha `channel_id` **ou** `video_id`. O `channel_id` é melhor: o video ID
muda a cada live.

O `python_executable` só importa no backend pytchat, e quase sempre precisa ser
trocado — veja [Instalar o pytchat](#instalar-o-pytchat).

### `TwitchChatProvider`

```gdscript
@export var twitch_chat: Node   # arraste seu nó TwitchChat do Twitcher
```

### `ChatHub`

Mesmos sinais do `ChatProvider`, agregando todos os providers filhos.

```gdscript
func register(p: ChatProvider) -> void
func connect_all() -> void
func disconnect_all() -> void
func set_attention(mode: String) -> void   # "attentive" | "idle" | "dormant"
func get_active_users() -> Array
```

Prefixa os ids com `tw:` / `yt:` para não haver colisão entre plataformas.

---

## Jogo de exemplo: Corrida de Chat

Jogo mínimo que roda de verdade, na pasta `jogo/`. Serve para confirmar que o
addon inteiro está funcionando com uma live real — se a corrida anda, o chat
chegou.

**Regra:** qualquer mensagem coloca o espectador numa raia. Cada `!corre`
avança um passo. Quem cruza a meta vence, o placar aparece e a próxima partida
começa sozinha em 8s.

```
                                                    META
corvo99      |=========================>              |
nina         |==============>                         |
ze_do_chat   |=======>                                |
```

> **Isto é demonstração, não é o addon.** Vive em `jogo/`, fora de
> `addons/stream_chat/`, e nada depende dele. Serve para você ver o addon
> funcionando com a sua live antes de escrever a primeira linha do seu jogo. Se
> a corrida anda, a ligação está de pé.

**Rodar:** abra `jogo/corrida.tscn`, selecione o nó `YouTubeChatProvider` e
preencha **um** campo — `channel_id` se a live for pública, `video_id` se for
não listada. Depois `F6`. Detalhes de qual usar e onde achar cada ID em
[Apontar para a sua live](#apontar-para-a-sua-live).

> **Avise o chat para numerar o comando: `!corre 1`, `!corre 2`, `!corre 3`…**
> O YouTube barra mensagem idêntica repetida, então o segundo `!corre` seco do
> mesmo espectador nunca sai. O argumento é ignorado pelo jogo, só serve para a
> mensagem ser diferente. O jogo já mostra isso na tela, mas é a coisa que mais
> vai confundir quem estiver assistindo.

**Sem live:** tecla `T` põe um bot na pista, `ESPAÇO` faz todos os bots darem um
passo. Dá pra conferir o visual antes de subir.

### Por que corrida e não um jogo de reflexo

O chat do YouTube chega em lote: a cada ~1s no backend pytchat quando tem
mensagem (padrão do exemplo, ~2s parado) e a cada ~5s no backend oficial.
Um jogo de reação (pular, desviar)
receberia o comando depois que a situação já passou — injogável, e você
culparia o addon. Corrida é acumulativa: importa **quantos** `!corre`
chegaram, nunca quando. A latência deixa de existir como problema.

### Arquitetura: onde a regra mora

```
jogo/corrida_chat.gd    regra pura (RefCounted, zero Godot) — testável
jogo/teste_corrida.gd   17 asserts, roda headless
jogo/pista.gd           cola: sinais do ChatProvider + _draw()
jogo/corrida.tscn       cena
```

A separação é o ponto: `corrida_chat.gd` não conhece Godot, nem rede, nem
desenho. Isso deixa a regra do jogo testável sem abrir uma live:

```bash
godot --headless --script res://jogo/teste_corrida.gd   # sai 1 se falhar
```

O `pista.gd` é só tradução — cada sinal vira uma chamada da regra:

```gdscript
_provider.user_joined.connect(func(u): _corrida.entrar(u.id, u.display_name))
_provider.user_left.connect(func(u): _corrida.sair(u.id))
_provider.user_command.connect(func(u, cmd, _a):
	if cmd == "corre":
		_corrida.correr(u.id))
```

### Detalhes que só aparecem com chat de verdade

**Reentrada não pode zerar o progresso.** Se o provider reconectar no meio da
live, `user_joined` dispara de novo para quem já estava jogando. Se `entrar()`
resetasse a posição, a partida inteira voltaria pra largada. Por isso
`entrar()` com id conhecido só atualiza o nome.

**Comando depois do vencedor.** As mensagens chegam em lote: quando alguém
cruza a meta, ainda tem `!corre` de outros na fila do mesmo lote. `correr()`
vira no-op enquanto houver vencedor, senão o segundo lugar "ganharia" depois.

**Mensagem repetida some, e o jogo não fica sabendo.** É a pegadinha mais séria
aqui: a corrida é feita de mandar o mesmo comando várias vezes, que é
exatamente o que o YouTube bloqueia. Não dá para detectar do lado do jogo — a
mensagem simplesmente nunca chega. O `pista.gd` desenha a instrução
`!corre 1 · !corre 2 · !corre 3 …` fixa no topo da tela por isso; o argumento é
descartado, serve só para a mensagem não ser idêntica à anterior.

**Cor por usuário precisa de embaralhador de bits.** O `hash()` de String do
Godot é sequencial — `"yt:1"` e `"yt:2"` saem com hashes vizinhos, e
`hash(id) % 360` dava a mesma cor pra todo mundo. `pista.gd:_cor_do` passa o
hash por um finalizador murmur3 antes de virar matiz.

---

## Exemplo completo: jogo tipo Worms

Cena:

```
Main
 ├── ChatHub
 │    ├── YouTubeChatProvider   (channel_id = "UCxxxx...")
 │    └── TwitchChatProvider    (twitch_chat = seu nó do Twitcher)
 └── Arena
```

```gdscript
extends Node

@onready var chat: ChatHub = $ChatHub
@onready var arena: Node2D = $Arena

const WORM_SCENE := preload("res://worm.tscn")
const MAX_PLAYERS := 12

var _turn_order: Array[String] = []   # ids na ordem de jogada
var _turn_index: int = 0
var _lobby_open: bool = true


func _ready() -> void:
	chat.user_command.connect(_on_command)
	chat.user_donated.connect(_on_donated)
	chat.user_left.connect(_on_user_left)
	chat.connect_all()
	_open_lobby()


# ---------------------------------------------------------------- comandos

func _on_command(user: ChatProvider.ChatUser, cmd: String, args: PackedStringArray) -> void:
	match cmd:
		"entrar", "join":
			_join(user)
		"sair", "leave":
			_leave(user)
		"atacar", "fire":
			_attack(user, args)
		"repetir":
			_repeat_last(user)


func _join(user: ChatProvider.ChatUser) -> void:
	if not _lobby_open:
		return
	if user.metadata.has("worm"):
		return                                  # já está jogando
	if _turn_order.size() >= MAX_PLAYERS:
		return

	var worm := WORM_SCENE.instantiate()
	worm.player_name = user.display_name
	worm.position = _random_spawn()
	arena.add_child(worm)

	user.metadata["worm"] = worm
	user.metadata["last_shot"] = null
	_turn_order.append(user.id)


func _leave(user: ChatProvider.ChatUser) -> void:
	_remove_worm(user)


func _attack(user: ChatProvider.ChatUser, args: PackedStringArray) -> void:
	# só o dono do turno atira
	if _current_player_id() != user.id:
		return
	if args.size() < 2:
		return
	if not user.metadata.has("worm"):
		return

	var angle := clampf(args[0].to_float(), 0.0, 180.0)
	var power := clampf(args[1].to_float(), 0.0, 100.0)

	user.metadata["last_shot"] = [angle, power]
	_fire(user.metadata["worm"], angle, power)


func _repeat_last(user: ChatProvider.ChatUser) -> void:
	# O YouTube bloqueia mensagem idêntica repetida — sem isso, o jogador não
	# consegue usar o mesmo ângulo duas vezes seguidas. Ver "Pegadinhas".
	var last = user.metadata.get("last_shot")
	if last != null:
		_attack(user, PackedStringArray([str(last[0]), str(last[1])]))


func _on_donated(user: ChatProvider.ChatUser, tier: int, _display: String, _text: String) -> void:
	if user.metadata.has("worm"):
		user.metadata["worm"].give_powerup(tier)   # tier 1..7


func _on_user_left(user: ChatProvider.ChatUser) -> void:
	_remove_worm(user)


func _remove_worm(user: ChatProvider.ChatUser) -> void:
	if user.metadata.has("worm"):
		user.metadata["worm"].queue_free()
		user.metadata.erase("worm")
	_turn_order.erase(user.id)


# ------------------------------------------------- turnos + economia de cota

func _open_lobby() -> void:
	_lobby_open = true
	chat.set_attention("attentive")     # gente entrando, precisa responder rápido


func _start_turn() -> void:
	_lobby_open = false
	chat.set_attention("attentive")     # esperando o !atacar
	# ... seu timer de turno aqui


func _fire(worm: Node, angle: float, power: float) -> void:
	chat.set_attention("idle")          # animação: ninguém digita nada útil
	# ... física do tiro ...
	await get_tree().create_timer(3.0).timeout
	_next_turn()


func _next_turn() -> void:
	if _turn_order.is_empty():
		_end_match()
		return
	_turn_index = (_turn_index + 1) % _turn_order.size()
	_start_turn()


func _end_match() -> void:
	chat.set_attention("dormant")       # placar, downtime entre partidas


func _current_player_id() -> String:
	if _turn_order.is_empty():
		return ""
	return _turn_order[_turn_index % _turn_order.size()]


func _random_spawn() -> Vector2:
	return Vector2(randf_range(50, 950), 0)
```

### Pontos de projeto que valem entender

**`inactivity_timeout = 0`.** Você usa `!entrar` / `!sair` explícitos, então
não precisa da varredura de presença. Mas mantenha um controle de AFK: em
Worms, jogador que entrou e sumiu **trava o turno**. Trate como "pula a vez"
usando `user.last_seen_unix`, e só remova depois de 2–3 turnos perdidos.

**Sempre chave por `user.id`, nunca por `display_name`.** No YouTube o nome
pode ser trocado e pode repetir entre pessoas diferentes.

**`set_attention` é o que segura sua cota.** Numa live de 2h derruba de ~1.440
para ~870 chamadas. No backend pytchat vira no-op (não há cota).

---

## Backend alternativo: pytchat (sem cota, sem API key)

| | `OFFICIAL_API` (padrão) | `PYTCHAT_SIDECAR` |
|---|---|---|
| API key | precisa | não |
| Cota | ~2 lives/dia | nenhuma |
| Latência | ~5s | ~1,5s |
| Estabilidade | contrato documentado | quebra sem aviso |
| Manutenção da dep. | Google | upstream parado |
| Termos de uso | limpo | zona cinza |

Roda `pytchat_bridge.py` como processo filho e lê o stdout em NDJSON. Usa o
`CompatibleProcessor` do pytchat, que devolve o **mesmo formato** da API
oficial — o `youtube_chat_message.gd` funciona sem alteração.

**Requisitos:** Godot 4.3+, Python 3 e o pytchat instalado — veja
[Instalar o pytchat](#instalar-o-pytchat), que tem armadilha de sistema
operacional nos dois lados.

**Ativar:** no inspector do `YouTubeChatProvider`, mude `backend` para
`PYTCHAT_SIDECAR` e ajuste `python_executable`.

**Testar sozinho, antes de culpar o Godot:**

```bash
# por video ID (o da live de agora)
python3 addons/stream_chat/youtube/pytchat_bridge.py SEU_VIDEO_ID

# por canal — repare no prefixo "channel:", que a ponte exige
python3 addons/stream_chat/youtube/pytchat_bridge.py channel:UCxxxxxxxx
```

Deve sair uma linha JSON por mensagem. Se sair `{"_bridge": "error", ...}`, a
mensagem diz o que fazer. Se ficar parado sem imprimir nada, resolveu o alvo e
está esperando mensagem — o canal não tem live ativa, ou ninguém falou ainda.

No Godot você passa só o `UCxxxxxxxx` no inspector: o `start_from_channel_id`
põe o prefixo sozinho.

O pytchat consome a InnerTube, API interna do player do YouTube: não
documentada, muda sem aviso, e o upstream não recebe manutenção ativa. Funciona
bem hoje; não é base para algo que precise durar. Só é viável porque o jogo
roda na **sua** máquina.

---

## Instalar o pytchat

Só para o backend `PYTCHAT_SIDECAR`. Quem usa `OFFICIAL_API` pode pular.

O que o addon faz é rodar `<python_executable> pytchat_bridge.py <alvo>`. Então
a única coisa que importa é: **o Python que você apontar precisa conseguir
`import pytchat`**. A pasta de onde você roda o `pip` é irrelevante.

### Linux

Distro moderna (Arch, Fedora, Debian/Ubuntu recentes) bloqueia `pip install`
no Python do sistema — é o [PEP 668](https://peps.python.org/pep-0668/), e o
erro é `externally-managed-environment`. Use um venv:

```bash
python3 -m venv ~/.venvs/streamchat
~/.venvs/streamchat/bin/pip install pytchat
~/.venvs/streamchat/bin/python -c "import pytchat; print('ok')"
```

No inspector do `YouTubeChatProvider`:

```
python_executable = /home/SEU_USUARIO/.venvs/streamchat/bin/python
```

Caminho absoluto, sem `~` — o `OS.execute_with_pipe` não passa por shell, então
o til não é expandido por ninguém.

### Windows

Não tem PEP 668, mas tem uma armadilha pior: o Windows já vem com um atalho
falso chamado `python3.exe` que **abre a Microsoft Store** em vez de rodar
Python. Como o padrão do addon é `python3`, deixar assim faz a loja abrir no
meio da sua live.

1. Instale o Python em [python.org/downloads](https://www.python.org/downloads/),
   marcando **"Add python.exe to PATH"** no instalador.
2. Crie o venv e instale (PowerShell ou CMD):

```bat
python -m venv %USERPROFILE%\.venvs\streamchat
%USERPROFILE%\.venvs\streamchat\Scripts\pip install pytchat
%USERPROFILE%\.venvs\streamchat\Scripts\python -c "import pytchat; print('ok')"
```

3. No inspector, caminho absoluto e completo (repare em `Scripts`, não `bin`):

```
python_executable = C:/Users/SEU_USUARIO/.venvs/streamchat/Scripts/python.exe
```

Use **barra normal** `/`. Godot aceita nos dois formatos, e a barra invertida
vira dor de cabeça na hora que esse caminho for parar dentro de um `.gd`.

> Sem venv também funciona no Windows (`pip install pytchat` e
> `python_executable = python`), mas aí depende do PATH estar certo e de nenhum
> outro Python entrar na frente. O caminho absoluto do venv não tem essa
> ambiguidade.

### Conferindo que pegou

Rode a ponte com o Python que você configurou, não com o do sistema:

```bash
# Linux
~/.venvs/streamchat/bin/python addons/stream_chat/youtube/pytchat_bridge.py channel:UCxxxxxxxx
```

```bat
REM Windows
%USERPROFILE%\.venvs\streamchat\Scripts\python addons\stream_chat\youtube\pytchat_bridge.py channel:UCxxxxxxxx
```

Se o Godot reclamar `spawnFailed`, o `python_executable` está errado ou o
caminho não existe. Se reclamar de `ModuleNotFoundError: pytchat`, você apontou
para um Python que não é o do venv.

---

## Roteiro de teste

Faça nesta ordem. Cada passo isola uma camada — pular etapa é como você acaba
depurando três coisas ao mesmo tempo.

### 1. Addon carrega

Ative o plugin. O console deve imprimir `StreamChat ativo`. Se reclamar de
caminho, a pasta não está em `res://addons/stream_chat`.

### 2. Credencial resolve

```gdscript
func _ready() -> void:
	print(StreamChatCredentials.has_youtube_api_key())   # esperado: true
```

Se `false`, a variável de ambiente não chegou no Godot (reabra o editor depois
de editar o `~/.bashrc`) ou o arquivo não existe.

### 3. Conexão crua

**Atalho:** já existe um script pronto que faz os passos 1 a 3 e te diz
exatamente onde parou.

1. Cena nova, nó raiz `Node`, anexe `addons/stream_chat/exemplo/teste_conexao.gd`
2. Adicione um `YouTubeChatProvider` como **filho**
3. Preencha `channel_id` no inspector
4. Abra uma live no seu canal
5. `F6` e digite `!teste 45 80` no chat

Ele imprime `[1/3]`, `[2/3]`, `[3/3]` e, ao final, um relatório dizendo se
conectou, se recebeu mensagem e se recebeu comando — com o diagnóstico do caso
específico que falhou.

Se preferir fazer na mão, é isto:

```gdscript
extends Node

@onready var yt: YouTubeChatProvider = $YouTubeChatProvider

func _ready() -> void:
	yt.provider_connected.connect(func(): print("CONECTADO"))
	yt.provider_disconnected.connect(func(r): print("DESCONECTADO: ", r))
	yt.user_joined.connect(func(u): print("ENTROU: ", u.display_name, " id=", u.id))
	yt.user_message.connect(func(u, t): print("MSG [", u.display_name, "] ", t))
	yt.user_command.connect(func(u, c, a): print("CMD !", c, " args=", a))
	yt.connect_chat()
```

Abra uma live no seu canal, digite `!teste 1 2` no chat.

Esperado no console, nesta ordem:
```
CONECTADO
ENTROU: SeuNome id=UCxxxx...
MSG [SeuNome] !teste 1 2
CMD !teste args=["1", "2"]
```

Se `CONECTADO` não aparecer, o erro estará no console via `push_warning` com o
`reason` da API (`liveChatNotActive`, `quotaExceeded`, `noActiveLive`...).

### 4. Consumo de cota

Depois de uma live de teste, veja
`console.cloud.google.com/iam-admin/quotas`. Esse número decide se você fica no
backend oficial ou migra pro pytchat.

### 5. Twitch

Rode com o `TwitchChatProvider` na cena e leia o console: ele imprime a qual
sinal conseguiu se conectar, ou lista todos os sinais disponíveis do seu nó se
não reconhecer nenhum.

### 6. Hub

Com os dois na mesma cena, confirme que os ids saem prefixados (`yt:UC...`,
`tw:123456`).

---

## Pegadinhas

**Não existe JOIN/PART no YouTube.** Só dá pra saber que alguém está lá quando
fala. Por isso `user_joined` dispara na primeira mensagem. O Twitcher usa
EventSub (não IRC), então a Twitch se comporta igual — os dois lados são
consistentes.

**O YouTube bloqueia mensagem idêntica repetida.** `!atacar 45 80` duas vezes
seguidas do mesmo usuário: a segunda nunca sai, e seu código nunca fica
sabendo. Vai parecer bug do jogo. Os dois exemplos contornam de jeitos
diferentes: o Worms tem `!repetir`, e a Corrida pede número no comando
(`!corre 1`, `!corre 2`). Se o seu jogo tem comando que se repete, resolva isso
**antes** de streamar — ao vivo parece travamento, e você vai depurar o lugar
errado.

**O video ID muda toda live.** Prefira `channel_id`, que é fixo. No backend
oficial a resolução gasta uma chamada de `search.list` (bucket próprio de
100/dia) — uma por live é tranquilo, nunca chame em loop. A exceção é live
**não listada ou privada**: aí a descoberta automática não funciona e você
precisa atualizar o `video_id` a cada transmissão. Ver
[Apontar para a sua live](#apontar-para-a-sua-live).

**Chat lento ou só-membros** faz comandos chegarem picotados. Confira antes de
streamar.

**Latência de ~5s** no backend oficial. Irrelevante em jogo por turnos,
inviável em jogo de reflexo.

---

## Estado do código

**Verificado** (Godot 4.7.1, Linux, Python 3.14):

- `jogo/` roda. 17 asserts passando em `teste_corrida.gd`, render conferido.
- `pytchat_bridge.py` roda num venv, resolve `channel:UC...` para o video ID da
  live e devolve mensagens reais em NDJSON.
- Ponta a ponta pelo Godot, backend `PYTCHAT_SIDECAR`, contra live real: a cena
  carrega, o sidecar sobe, `provider_connected` dispara e o chat chega no jogo.
  Confirmado numa transmissão não listada, via `video_id`.
- `provider_disconnected("chatEnded")` chega certinho quando a transmissão
  resolvida já acabou.
- Detecção de "não há live": o resolvedor recusa devolver VOD antigo e explica
  o caso não listada/privada.

**Não verificado**, porque precisa de coisa que eu não tinha aqui:

- Descoberta automática por `channel_id` **no seu canal** — testada contra um
  canal público com live 24/7, não contra o fluxo "abri minha live pública
  agora".
- Backend `OFFICIAL_API` (sem API key).
- Qualquer coisa da Twitch (sem o Twitcher instalado).
- Windows — as instruções acima são de leitura da documentação, não de execução.

Pontos onde o atrito é mais provável, em ordem:

1. **Sinal do Twitcher** (`twitch/twitch_chat_provider.gd`) — o auto-descobridor
   imprime a lista real de sinais se não reconhecer nenhum. Caso conhecido.
2. **Tipos de sinal com classe interna** (`ChatProvider.ChatUser` em
   `core/chat_hub.gd`) — se o parser reclamar, remova a anotação de tipo do
   parâmetro; é só documentação.
3. **`await` em `connect_chat()`** — `resolve_live_video_id` é assíncrono. Use
   o sinal `provider_connected` em vez de assumir conexão síncrona.
4. **`resolve_channel_live` no `pytchat_bridge.py`** — raspa a página `/live`
   com regex procurando `"videoId"`. Frágil por natureza. Se falhar, passe o
   video ID direto.
5. **Assinatura do `pytchat.create()`** — os forks divergem. A ponte tenta
   `create(video_id=, processor=)` e cai pro `LiveChat()` antigo.

### Arquivos

| Arquivo | Papel |
|---|---|
| `core/chat_provider.gd` | interface, `ChatUser`, parsing de comando, presença |
| `core/chat_hub.gd` | agrega providers, namespaceia ids |
| `credentials.gd` | resolve a API key sem gravá-la no projeto |
| `youtube/youtube_chat_message.gd` | parsing do JSON (API oficial e pytchat) |
| `youtube/youtube_chat_client.gd` | backend oficial: HTTP, polling adaptativo |
| `youtube/youtube_chat_sidecar.gd` | backend pytchat: processo filho + thread |
| `youtube/pytchat_bridge.py` | ponte Python, NDJSON no stdout |
| `youtube/youtube_chat_provider.gd` | tradução YouTube → interface |
| `twitch/twitch_chat_provider.gd` | ponte para o Twitcher |

Fora do addon, o jogo de exemplo:

| Arquivo | Papel |
|---|---|
| `jogo/corrida_chat.gd` | regra da corrida, sem Godot — é o que os testes cobrem |
| `jogo/teste_corrida.gd` | 17 asserts, roda headless, sai 1 se falhar |
| `jogo/pista.gd` | cola: sinais → regra, e o desenho |
| `jogo/corrida.tscn` | cena pronta pra `F6` |
