extends Control

@export var server_url: String = "wss://saionline-server.onrender.com"

@onready var status_label: Label = $RootMargin/RootVBox/Header/StatusLabel
@onready var roll_button: Button = $RootMargin/RootVBox/MainRow/LeftCol/RollRow/RollButton
@onready var number_panel: PanelContainer = $RootMargin/RootVBox/MainRow/LeftCol/NumberPanel
@onready var number_label: Label = $RootMargin/RootVBox/MainRow/LeftCol/NumberPanel/NumberLabel
@onready var dice_grid: GridContainer = $RootMargin/RootVBox/MainRow/LeftCol/DiceGrid
@onready var shared_bar: ProgressBar = $RootMargin/RootVBox/MainRow/RightCol/SharedBar
@onready var shared_value: Label = $RootMargin/RootVBox/MainRow/RightCol/SharedValue
@onready var personal_value: Label = $RootMargin/RootVBox/MainRow/RightCol/PersonalValue
@onready var missing_value: Label = $RootMargin/RootVBox/MainRow/RightCol/MissingValue
@onready var log_label: RichTextLabel = $RootMargin/RootVBox/LogPanel/LogBox/LogScroll/LogLabel
@onready var title_label: Label = $RootMargin/RootVBox/Header/TitleLabel
@onready var dice_title: Label = $RootMargin/RootVBox/MainRow/LeftCol/DiceTitle
@onready var progress_title: Label = $RootMargin/RootVBox/MainRow/RightCol/ProgressTitle
@onready var log_title: Label = $RootMargin/RootVBox/LogPanel/LogBox/LogTitle
@onready var name_open_button: Button = $RootMargin/RootVBox/Header/NameButton
@onready var name_overlay: ColorRect = $NameLayer/NameOverlay
@onready var name_panel: PanelContainer = $NameLayer/NameOverlay/NamePanel
@onready var name_input: LineEdit = $NameLayer/NameOverlay/NamePanel/NameBox/NameInput
@onready var name_button: Button = $NameLayer/NameOverlay/NamePanel/NameBox/NameButton
@onready var collection_title: Label = $RootMargin/RootVBox/MainRow/RightCol/CollectionPanel/CollectionBox/CollectionTitle
@onready var collection_list: RichTextLabel = $RootMargin/RootVBox/MainRow/RightCol/CollectionPanel/CollectionBox/CollectionScroll/CollectionList
@onready var tab_collection: Button = $RootMargin/RootVBox/MainRow/RightCol/CollectionPanel/CollectionBox/CollectionTabRow/TabCollection
@onready var tab_leaderboard: Button = $RootMargin/RootVBox/MainRow/RightCol/CollectionPanel/CollectionBox/CollectionTabRow/TabLeaderboard

var ws := WebSocketPeer.new()
var connected := false
var random_min := 0
var random_max := 65535
var total := 65536
var shared_count := 0
var personal_count := 0
var season_id := 1
var ending := false
var reset_at := 0
var player_id := ""
var hello_sent := false
var player_name := ""
var has_name := false
var dice_labels: Array[Label] = []
var dice_panels: Array[PanelContainer] = []
var rolling := false
var roll_anim_left := 0.0
var roll_anim_done := false
var roll_tick_left := 0.0
var roll_wait_left := 0.0
var pending_roll := ""
var pending_new_shared := false
var pending_new_personal := false
var highlight_left := 0.0
var log_lines: Array[String] = []
var rng := RandomNumberGenerator.new()
var shared_latest: Array[Dictionary] = []
var leaderboard: Array[Dictionary] = []
var collection_view := "collection"
var collection_dirty := false
var collection_update_scheduled := false
var collection_render_token := 0
var leaderboard_dirty := false

const LOG_LIMIT := 40
const ROLL_ANIM_SEC := 1.0
const ROLL_TICK_SEC := 0.05
const ROLL_WAIT_SEC := 5.0
const COLLECTION_LATEST_LIMIT := 100

func _ready() -> void:
	roll_button.pressed.connect(_on_roll_pressed)
	roll_button.disabled = true
	name_open_button.pressed.connect(_on_open_name)
	tab_collection.pressed.connect(func(): _set_collection_view("collection"))
	tab_leaderboard.pressed.connect(func(): _set_collection_view("leaderboard"))
	player_id = _load_player_id()
	player_name = _load_player_name()
	rng.randomize()
	_apply_theme()
	_build_dice_slots()
	_setup_name_overlay()
	_set_collection_view("collection")
	_connect_ws()

func _connect_ws() -> void:
	var err = ws.connect_to_url(server_url)
	if err != OK:
		status_label.text = "WS error: " + str(err)

func _process(_delta: float) -> void:
	ws.poll()
	var state = ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not connected:
		connected = true
		status_label.text = "Connected"
		roll_button.disabled = false
		_try_send_hello()
	elif state == WebSocketPeer.STATE_CLOSED and connected:
		connected = false
		status_label.text = "Disconnected"
		roll_button.disabled = true

	_update_roll_anim(_delta)
	_update_highlight(_delta)

	while ws.get_available_packet_count() > 0:
		var pkt = ws.get_packet().get_string_from_utf8()
		_handle_message(pkt)

func _handle_message(raw: String) -> void:
	var data = JSON.parse_string(raw)
	if data == null or typeof(data) != TYPE_DICTIONARY or not data.has("type"):
		return
	var msg_type: String = data["type"]
	var payload = data.get("data", {})
	match msg_type:
		"snapshot":
			_apply_snapshot(payload)
		"roll_result":
			_apply_roll_result(payload)
		"shared_update":
			_apply_shared_update(payload)
		"ending":
			_apply_ending(payload)
		"reset":
			_apply_reset(payload)
		"error":
			_log("Server error: " + str(payload.get("message", "")))

func _apply_snapshot(p: Dictionary) -> void:
	random_min = int(p.get("random_min", 0))
	random_max = int(p.get("random_max", 65535))
	total = int(p.get("total", 65536))
	season_id = int(p.get("season_id", 1))
	shared_count = int(p.get("shared_count", 0))
	personal_count = int(p.get("personal_count", 0))
	ending = bool(p.get("ending", false))
	reset_at = int(p.get("reset_at", 0))
	player_id = str(p.get("player_id", player_id))
	player_name = str(p.get("player_name", player_name))
	if player_id != "":
		_save_player_id(player_id)
	if player_name != "":
		_save_player_name(player_name)
		has_name = true
		name_overlay.visible = false
	_try_send_hello()
	_update_collection_from_snapshot(p)
	_build_dice_slots()
	_update_labels()
	_log("Season " + str(season_id) + " start")

func _apply_roll_result(p: Dictionary) -> void:
	var roll = str(p.get("roll", ""))
	var new_shared = bool(p.get("is_new_shared", false))
	var new_personal = bool(p.get("is_new_personal", false))
	shared_count = int(p.get("shared_count", shared_count))
	personal_count = int(p.get("personal_count", personal_count))
	_update_labels()
	pending_roll = roll
	pending_new_shared = new_shared
	pending_new_personal = new_personal
	if roll_anim_done:
		_finalize_roll()
	if pending_new_shared:
		leaderboard_dirty = true
		leaderboard_dirty = true

func _apply_shared_update(p: Dictionary) -> void:
	shared_count = int(p.get("shared_count", shared_count))
	total = int(p.get("total", total))
	var roll = str(p.get("roll", ""))
	if roll != "":
		_add_shared_roll(
			roll,
			str(p.get("finder_name", "")),
			int(p.get("count", 1))
		)
	if p.has("leaderboard"):
		leaderboard.clear()
		for r in p["leaderboard"]:
			if typeof(r) == TYPE_DICTIONARY:
				leaderboard.append(
					{
						"name": str(r.get("name", "")),
						"count": int(r.get("count", 0)),
					}
				)
		leaderboard_dirty = true
	_update_labels()

func _apply_ending(p: Dictionary) -> void:
	ending = true
	reset_at = int(p.get("reset_at", 0))
	_update_labels()
	_log("Ending reached. Reset scheduled.")

func _apply_reset(p: Dictionary) -> void:
	if p.has("random_min"):
		random_min = int(p.get("random_min", random_min))
	if p.has("random_max"):
		random_max = int(p.get("random_max", random_max))
	if p.has("total"):
		total = int(p.get("total", total))
	season_id = int(p.get("season_id", season_id + 1))
	shared_count = int(p.get("shared_count", 0))
	personal_count = 0
	ending = false
	reset_at = 0
	pending_roll = ""
	rolling = false
	roll_anim_left = 0.0
	roll_anim_done = false
	roll_wait_left = 0.0
	shared_latest.clear()
	leaderboard.clear()
	leaderboard_dirty = true
	_mark_collection_dirty()
	_update_labels()
	_log("Reset complete. Season " + str(season_id) + " start")

func _update_labels() -> void:
	var ratio = 0.0
	if total > 0:
		ratio = float(shared_count) / float(total)
	shared_bar.value = ratio
	shared_value.text = "Shared: " + str(shared_count) + " / " + str(total)
	personal_value.text = "Personal: " + str(personal_count)
	missing_value.text = "Missing: " + str(max(0, total - shared_count))
	if ending:
		status_label.text = "Ending... reset soon"
	elif connected:
		status_label.text = "Connected"
	else:
		status_label.text = "Disconnected"

func _on_roll_pressed() -> void:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if rolling:
		return
	if not has_name:
		_log("Set your name first.")
		return
	_start_roll_anim()
	_send("roll_request", {})

func _send(msg_type: String, payload: Dictionary) -> void:
	var packet = {"type": msg_type, "data": payload}
	ws.send_text(JSON.stringify(packet))

func _log(text: String) -> void:
	log_lines.append(text)
	while log_lines.size() > LOG_LIMIT:
		log_lines.pop_front()
	log_label.text = "\n".join(log_lines)

func _load_player_id() -> String:
	if not FileAccess.file_exists("user://player_id.txt"):
		return ""
	var f = FileAccess.open("user://player_id.txt", FileAccess.READ)
	if f == null:
		return ""
	var id = f.get_line()
	f.close()
	return id.strip_edges()

func _save_player_id(id: String) -> void:
	var f = FileAccess.open("user://player_id.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_line(id)
	f.close()

func _apply_theme() -> void:
	var base = Color(0.92, 0.94, 0.98)
	var muted = Color(0.65, 0.7, 0.78)
	var accent = Color(0.26, 0.82, 0.72)
	var accent2 = Color(0.36, 0.6, 0.95)
	title_label.add_theme_color_override("font_color", base)
	title_label.add_theme_font_size_override("font_size", 24)
	status_label.add_theme_color_override("font_color", muted)
	status_label.add_theme_font_size_override("font_size", 14)
	dice_title.add_theme_color_override("font_color", base)
	dice_title.add_theme_font_size_override("font_size", 16)
	progress_title.add_theme_color_override("font_color", base)
	progress_title.add_theme_font_size_override("font_size", 16)
	log_title.add_theme_color_override("font_color", base)
	log_title.add_theme_font_size_override("font_size", 14)
	shared_value.add_theme_color_override("font_color", base)
	personal_value.add_theme_color_override("font_color", base)
	log_label.add_theme_color_override("default_color", base)
	roll_button.add_theme_color_override("font_color", Color(0.05, 0.08, 0.1))
	var button_style = StyleBoxFlat.new()
	button_style.bg_color = accent
	button_style.corner_radius_top_left = 8
	button_style.corner_radius_top_right = 8
	button_style.corner_radius_bottom_left = 8
	button_style.corner_radius_bottom_right = 8
	button_style.content_margin_left = 16
	button_style.content_margin_right = 16
	button_style.content_margin_top = 8
	button_style.content_margin_bottom = 8
	roll_button.add_theme_stylebox_override("normal", button_style)
	var hover_style = button_style.duplicate()
	hover_style.bg_color = accent2
	roll_button.add_theme_stylebox_override("hover", hover_style)
	var pressed_style = button_style.duplicate()
	pressed_style.bg_color = Color(0.2, 0.7, 0.65)
	roll_button.add_theme_stylebox_override("pressed", pressed_style)
	var bar_bg = StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.12, 0.14, 0.18)
	bar_bg.corner_radius_top_left = 6
	bar_bg.corner_radius_top_right = 6
	bar_bg.corner_radius_bottom_left = 6
	bar_bg.corner_radius_bottom_right = 6
	shared_bar.add_theme_stylebox_override("background", bar_bg)
	var bar_fill = StyleBoxFlat.new()
	bar_fill.bg_color = accent2
	bar_fill.corner_radius_top_left = 6
	bar_fill.corner_radius_top_right = 6
	bar_fill.corner_radius_bottom_left = 6
	bar_fill.corner_radius_bottom_right = 6
	shared_bar.add_theme_stylebox_override("fill", bar_fill)
	collection_title.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	collection_list.add_theme_color_override("default_color", Color(0.92, 0.94, 0.98))
	missing_value.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	number_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	number_label.add_theme_font_size_override("font_size", 48)
	number_panel.add_theme_stylebox_override(
		"panel",
		_make_die_style(Color(0.1, 0.12, 0.16), Color(0.2, 0.23, 0.3))
	)
	name_overlay.add_theme_color_override("color", Color(0, 0, 0, 0.6))
	name_input.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	name_input.add_theme_color_override("font_color_placeholder", Color(0.6, 0.65, 0.72))
	name_input.add_theme_color_override("caret_color", Color(0.92, 0.94, 0.98))
	name_button.add_theme_color_override("font_color", Color(0.05, 0.08, 0.1))
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.12, 0.14, 0.18)
	panel_style.corner_radius_top_left = 10
	panel_style.corner_radius_top_right = 10
	panel_style.corner_radius_bottom_left = 10
	panel_style.corner_radius_bottom_right = 10
	name_panel.add_theme_stylebox_override("panel", panel_style)

	var input_style = StyleBoxFlat.new()
	input_style.bg_color = Color(0.08, 0.1, 0.14)
	input_style.border_color = Color(0.26, 0.82, 0.72)
	input_style.border_width_bottom = 1
	input_style.border_width_left = 1
	input_style.border_width_right = 1
	input_style.border_width_top = 1
	input_style.corner_radius_top_left = 6
	input_style.corner_radius_top_right = 6
	input_style.corner_radius_bottom_left = 6
	input_style.corner_radius_bottom_right = 6
	input_style.content_margin_left = 8
	input_style.content_margin_right = 8
	input_style.content_margin_top = 6
	input_style.content_margin_bottom = 6
	name_input.add_theme_stylebox_override("normal", input_style)
	name_input.add_theme_stylebox_override("focus", input_style)

func _build_dice_slots() -> void:
	for c in dice_grid.get_children():
		c.queue_free()
	dice_labels.clear()
	dice_panels.clear()
	number_label.text = "-----"

func _make_die_style(bg: Color, border: Color) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.border_width_bottom = 2
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style

func _start_roll_anim() -> void:
	rolling = true
	roll_anim_left = ROLL_ANIM_SEC
	roll_anim_done = false
	roll_tick_left = 0.0
	roll_wait_left = ROLL_WAIT_SEC
	pending_roll = ""
	pending_new_shared = false
	pending_new_personal = false
	roll_button.disabled = true
	_log("Rolling...")

func _update_roll_anim(delta: float) -> void:
	if not rolling:
		return
	if roll_anim_left > 0.0:
		roll_anim_left -= delta
		if roll_anim_left <= 0.0:
			roll_anim_left = 0.0
			roll_anim_done = true
	roll_tick_left -= delta
	if roll_tick_left <= 0.0:
		roll_tick_left = ROLL_TICK_SEC
		number_label.text = str(rng.randi_range(random_min, random_max))
	if roll_anim_done and pending_roll != "":
		_finalize_roll()
	elif roll_anim_done and pending_roll == "":
		roll_wait_left -= delta
		if roll_wait_left <= 0.0:
			rolling = false
			roll_button.disabled = false
			_log("Roll timed out. Try again.")

func _finalize_roll() -> void:
	rolling = false
	roll_button.disabled = false
	number_label.text = pending_roll
	_apply_dice_highlight(pending_new_shared, pending_new_personal)
	var flags = ""
	if pending_new_shared:
		flags += " NEW-SHARED"
	if pending_new_personal:
		flags += " NEW-PERSONAL"
	_log("Roll: " + pending_roll + flags)
	pending_roll = ""

func _apply_dice_highlight(is_shared: bool, is_personal: bool) -> void:
	var bg = Color(0.13, 0.15, 0.2)
	var border = Color(0.2, 0.23, 0.3)
	if is_shared:
		bg = Color(0.1, 0.35, 0.28)
		border = Color(0.26, 0.82, 0.72)
	elif is_personal:
		bg = Color(0.12, 0.22, 0.36)
		border = Color(0.36, 0.6, 0.95)
	number_panel.add_theme_stylebox_override("panel", _make_die_style(bg, border))
	highlight_left = 0.8 if (is_shared or is_personal) else 0.0

func _update_highlight(delta: float) -> void:
	if highlight_left <= 0.0:
		return
	highlight_left -= delta
	if highlight_left <= 0.0:
		number_panel.add_theme_stylebox_override(
			"panel",
			_make_die_style(Color(0.1, 0.12, 0.16), Color(0.2, 0.23, 0.3))
		)

func _update_collection_from_snapshot(p: Dictionary) -> void:
	shared_latest.clear()
	leaderboard.clear()
	if p.has("latest_rolls"):
		for r in p["latest_rolls"]:
			if typeof(r) == TYPE_DICTIONARY:
				shared_latest.append(
					{
						"roll": str(r.get("roll", "")),
						"name": str(r.get("first_finder_name", "")),
						"count": int(r.get("count", 1)),
					}
				)
	if p.has("leaderboard"):
		for r in p["leaderboard"]:
			if typeof(r) == TYPE_DICTIONARY:
				leaderboard.append(
					{
						"name": str(r.get("name", "")),
						"count": int(r.get("count", 0)),
					}
				)
	leaderboard_dirty = true
	_mark_collection_dirty()

func _add_shared_roll(roll: String, finder_name: String, count: int) -> void:
	if roll == "":
		return
	shared_latest.push_front({"roll": roll, "name": finder_name, "count": count})
	while shared_latest.size() > COLLECTION_LATEST_LIMIT:
		shared_latest.pop_back()
	_mark_collection_dirty()

func _update_collection_view() -> void:
	collection_render_token += 1
	var token = collection_render_token
	call_deferred("_render_collection_async", token)
	return

func _render_collection_async(token: int) -> void:
	if token != collection_render_token:
		return
	if collection_view == "leaderboard":
		var lines_lb: Array[String] = []
		var idx = 1
		for entry in leaderboard:
			var n = str(entry.get("name", ""))
			var c = int(entry.get("count", 0))
			lines_lb.append(str(idx) + ". " + n + " - " + str(c))
			idx += 1
		if lines_lb.is_empty():
			collection_list.text = "No ranking yet."
		else:
			collection_list.text = "\n".join(lines_lb)
		return
	var lines: Array[String] = []
	var seen := {}
	for entry in shared_latest:
		var roll = str(entry.get("roll", ""))
		if roll == "":
			continue
		if seen.has(roll):
			continue
		seen[roll] = true
		var finder = str(entry.get("name", ""))
		var cnt = int(entry.get("count", 1))
		var suffix = " x" + str(cnt)
		if finder == "":
			lines.append("✔ " + roll + suffix)
		else:
			lines.append("✔ " + roll + suffix + "  - " + finder)
	if lines.is_empty():
		collection_list.text = "No shared rolls yet."
	else:
		collection_list.text = "\n".join(lines)

func _mark_collection_dirty() -> void:
	collection_dirty = true
	if collection_update_scheduled:
		return
	collection_update_scheduled = true
	var timer = get_tree().create_timer(0.3)
	timer.timeout.connect(func():
		collection_update_scheduled = false
		if collection_dirty:
			collection_dirty = false
			_update_collection_view()
	)

func _set_collection_view(value: String) -> void:
	collection_view = value
	if collection_view == "leaderboard":
		collection_title.text = "LEADERBOARD"
	else:
		collection_title.text = "LATEST"
	_mark_collection_dirty()

func _setup_name_overlay() -> void:
	name_button.pressed.connect(_on_name_submit)
	name_input.text_submitted.connect(func(_t): _on_name_submit())
	has_name = player_name.strip_edges() != ""
	name_overlay.visible = not has_name
	name_overlay.mouse_filter = Control.MOUSE_FILTER_PASS
	name_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	name_input.focus_mode = Control.FOCUS_ALL
	name_button.focus_mode = Control.FOCUS_ALL
	name_input.focus_entered.connect(func(): DisplayServer.virtual_keyboard_show(name_input.text))
	name_input.focus_exited.connect(func(): DisplayServer.virtual_keyboard_hide())
	name_button.disabled = false
	if has_name:
		name_input.text = player_name
	else:
		name_input.grab_focus()

func _on_open_name() -> void:
	name_overlay.visible = true
	name_input.text = player_name
	name_input.grab_focus()

func _on_name_submit() -> void:
	var player_name_value = name_input.text.strip_edges()
	if player_name_value == "":
		return
	player_name = player_name_value
	_save_player_name(player_name)
	has_name = true
	name_overlay.visible = false
	hello_sent = false
	_try_send_hello()

func _try_send_hello() -> void:
	if not connected:
		return
	if hello_sent:
		return
	if player_id == "":
		return
	if not has_name:
		return
	_send("hello", {"player_id": player_id, "player_name": player_name})
	hello_sent = true

func _load_player_name() -> String:
	if not FileAccess.file_exists("user://player_name.txt"):
		return ""
	var f = FileAccess.open("user://player_name.txt", FileAccess.READ)
	if f == null:
		return ""
	var player_name_value = f.get_line()
	f.close()
	return player_name_value.strip_edges()

func _save_player_name(player_name_value: String) -> void:
	var f = FileAccess.open("user://player_name.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_line(player_name_value)
	f.close()
