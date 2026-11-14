extends Control

## Stage 4 UI. Builds its whole subtree in code — no .tscn, no assets — and
## lays out as:
##
##   ┌──────────────── HSplitContainer ───────────────────────────────────┐
##   │  AsciiMap (left)        │  right VBox:                              │
##   │   ~~~~ T ·········      │   [Pause][1×][2×][3×]  Day 42 · Wk 6  $1234│
##   │        ·  ·   b         │   ── Tortuga ──                            │
##   │   ·   P      G          │     [read-only price table]  OR            │
##   │        ·    ·           │     [⚓ Depart -> Port Royal]               │
##   │     C    S              │     sugar  stk 47  $18.20  hold 0           │
##   │  (click a town)         │        [Buy1][Buy10] [Sell1][Sell10][All]   │
##   │                         │   ── Ship ──                               │
##   │                         │     state / cargo / wallet                 │
##   │                         │   ── Route ──                              │
##   │                         │     [Up][Dn] > Tortuga [Del]               │
##   │                         │     [+ Add Cayman]                         │
##   │                         │   ── Log ──                                │
##   │                         │     [d42] bought 12 sugar @ 18.2 ...        │
##   └─────────────────────────┴───────────────────────────────────────────┘
##
## The trade panel appears only for the town the player's ship is docked at.
## The ship never auto-trades in windowed mode (see main.gd): docking pauses
## the clock, the player buys/sells at fixed quantities, then clicks Depart.
## Route stops are reordered/removed inline and appended via "+ Add <town>".
##
## Reads state only from WorldState / SimulationClock and listens to EventBus;
## every mutation is delegated to the Main controller (player_buy / depart_ship
## / route_*). In-game labels stay English for consistency with Stage 3 and to
## keep button text short and font-safe (the bundled DejaVu Sans Mono carries
## Cyrillic for the log messages regardless).

const FONT_PATH: String = "res://ui/fonts/DejaVuSansMono.ttf"
const LOG_LINES: int = 14

var _controller: Node = null          # the Main root node (owns the engine)
var _font: Font
var _selected_town: String = "tortuga"

var _day_label: Label
var _money_label: Label
var _speed_buttons: Array[Button] = []
var _town_title: Label
var _town_body: Label            # read-only price table (shown when not docked here)
var _trade_panel: VBoxContainer  # per-good buy/sell buttons (shown when docked here)
var _ship_body: Label
var _route_panel: VBoxContainer
var _diplo_panel: VBoxContainer   # Stage A3.1: diplomacy (bribe + citizenship per state)
var _log_label: Label
var _log_lines: Array[String] = []

func _load_font() -> Font:
	# Prefer the bundled .ttf (consistent once the editor imports it); fall back
	# to the OS monospace font so a direct `godot --path .` run with no prior
	# editor import still works.
	var f = load(FONT_PATH)
	if f != null and f is Font:
		return f
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"])
	return sf

func _ready() -> void:
	_controller = get_parent()
	_font = _load_font()
	_build_layout()
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.message.connect(_on_message)
	EventBus.trade_completed.connect(_on_trade_completed)
	EventBus.town_updated.connect(_on_town_updated)
	EventBus.ship_docked.connect(_on_ship_docked)
	_refresh_all()

# ----------------------------------------------------------------- public api --

# Called by main.gd when the ship docks (auto-selects the port town so the
# trade panel opens immediately). Also used to sync selection.
func select_town(town_id: String) -> void:
	_selected_town = town_id
	_render_town()
	_rebuild_trade_panel()
	_rebuild_route_panel()
	_rebuild_diplo_panel()   # Stage A3.1

# -------------------------------------------------------------------- layout --

func _build_layout() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.offset_left = 6.0
	split.offset_top = 6.0
	split.offset_right = -6.0
	split.offset_bottom = -6.0
	add_child(split)

	# Left: the ASCII map.
	var map: AsciiMap = load("res://ui/ascii_map.gd").new()
	map.town_selected.connect(_on_town_selected)
	split.add_child(map)

	# Right: a vertical stack of panels.
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(640.0, 0.0)   # Stage A3.1: widened 560->640 to fit Diplomacy panel
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)
	split.add_child(right)

	# --- top bar: speed buttons + day + money ---
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	right.add_child(top)
	var specs: Array = [["Pause", 0], ["1x", 1], ["2x", 2], ["3x", 3]]
	for spec in specs:
		var b := Button.new()
		b.text = String(spec[0])
		b.add_theme_font_override("font", _font)
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(56.0, 28.0)
		b.pressed.connect(_set_speed.bind(int(spec[1])))
		top.add_child(b)
		_speed_buttons.append(b)
	_day_label = _mklabel(top, "Day 0 · Wk 0", 15, Color(0.9, 0.9, 0.9))
	_day_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_money_label = _mklabel(top, "$ 0", 15, Color(0.45, 0.9, 0.5))

	right.add_child(_sep())

	# --- town panel: title + (read-only table | trade panel) ---
	_town_title = _mklabel(right, "— Town —", 15, Color(1.0, 0.8, 0.2))
	_town_body = _mklabel(right, "", 13, Color(0.85, 0.85, 0.85))
	_town_body.custom_minimum_size = Vector2(0.0, 150.0)
	_trade_panel = VBoxContainer.new()
	_trade_panel.add_theme_constant_override("separation", 2)
	_trade_panel.visible = false
	right.add_child(_trade_panel)

	right.add_child(_sep())

	# --- ship panel ---
	_mklabel(right, "— Ship —", 15, Color(1.0, 0.8, 0.2))
	_ship_body = _mklabel(right, "", 13, Color(0.85, 0.85, 0.85))
	_ship_body.custom_minimum_size = Vector2(0.0, 70.0)

	# --- route panel (inline editor) ---
	_mklabel(right, "— Route —", 15, Color(1.0, 0.8, 0.2))
	_route_panel = VBoxContainer.new()
	_route_panel.add_theme_constant_override("separation", 2)
	right.add_child(_route_panel)

	right.add_child(_sep())

	# --- Stage A3.1: diplomacy panel (bribe + citizenship per state) ---
	_mklabel(right, "— Diplomacy —", 15, Color(1.0, 0.8, 0.2))
	_diplo_panel = VBoxContainer.new()
	_diplo_panel.add_theme_constant_override("separation", 2)
	right.add_child(_diplo_panel)

	right.add_child(_sep())

	# --- event log ---
	_mklabel(right, "— Log —", 15, Color(1.0, 0.8, 0.2))
	_log_label = _mklabel(right, "", 12, Color(0.65, 0.8, 0.65))
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _mklabel(parent: Control, text: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	parent.add_child(l)
	return l

func _mkbutton(parent: Control, text: String, callable: Callable, w: float, h: float, fs: int, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", fs)
	b.add_theme_color_override("font_color", color)
	b.custom_minimum_size = Vector2(w, h)
	b.pressed.connect(callable)
	parent.add_child(b)
	return b

func _sep() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 2)
	return s

func _clear(c: Node) -> void:
	for child in c.get_children():
		child.free()

# -------------------------------------------------------------- signal ops --

func _on_day_advanced(_day: int) -> void:
	_render_clock()
	_render_money()
	_render_ship()
	_render_town()
	_rebuild_trade_panel()
	# Refresh the diplomacy panel (state-pair relations + active
	# wars + per-state rep) on the weekly boundary — wars/relations only change
	# in WarSystem.roll_weekly, which fires when the week advances, so a weekly
	# rebuild stays in sync without daily reflow of the button rows.
	if _day % 7 == 0:
		_rebuild_diplo_panel()

func _on_town_updated(town_id: String) -> void:
	if town_id == _selected_town:
		_render_town()
		_rebuild_trade_panel()

func _on_town_selected(town_id: String) -> void:
	select_town(town_id)
	var t: Town = WorldState.get_town(town_id)
	EventBus.message.emit("selected %s" % (t.name if t != null else town_id))

func _on_ship_docked(ship_id: String, _town_id: String) -> void:
	# Only the player's docking needs a panel refresh — it paused the clock and
	# may have opened the trade panel. AI docks are picked up by the daily
	# day_advanced refresh; rebuilding here on every rival port call would be
	# janky and fight the player's own edits.
	var p: Ship = WorldState.get_player_ship()
	if p == null or ship_id != p.id:
		return
	_render_ship()
	_render_town()
	_rebuild_trade_panel()
	_rebuild_route_panel()
	_rebuild_diplo_panel()   # Stage A3.1
	_highlight_speed()

func _on_trade_completed(_town_id: String, _good_id: String, _qty: float, _price: float) -> void:
	# trade_system already emitted a human-readable message; refresh the
	# wallet/cargo/stock displays without waiting for the next day.
	_render_money()
	_render_ship()
	_render_town()
	_rebuild_trade_panel()

func _on_message(text: String) -> void:
	_log_lines.append("[d%d] %s" % [SimulationClock.day, text])
	while _log_lines.size() > LOG_LINES:
		_log_lines.pop_front()
	_log_label.text = "\n".join(PackedStringArray(_log_lines))

func _set_speed(tier: int) -> void:
	_controller.call("set_speed", tier)
	_highlight_speed()

func _highlight_speed() -> void:
	var cur: int = int(_controller.call("get_speed"))
	for i in range(_speed_buttons.size()):
		var on: bool = (i == cur)
		_speed_buttons[i].add_theme_color_override("font_color",
				Color(1.0, 0.9, 0.2) if on else Color(0.75, 0.78, 0.82))

func _refresh_all() -> void:
	_render_clock()
	_render_money()
	_render_town()
	_render_ship()
	_rebuild_trade_panel()
	_rebuild_route_panel()
	_rebuild_diplo_panel()   # Stage A3.1
	_on_message("UI ready — docked at Tortuga. Trade, edit the route, then Depart.")
	_on_message("Space pause · 1/2/3 speed · click a town to inspect it.")
	_highlight_speed()

# ------------------------------------------------------- trade & route buttons --

func _on_buy(good_id: String, qty: float) -> void:
	_controller.call("player_buy", good_id, qty)
	call_deferred("_after_trade")

func _on_sell(good_id: String, qty: float) -> void:
	_controller.call("player_sell", good_id, qty)
	call_deferred("_after_trade")

func _on_depart() -> void:
	_controller.call("depart_ship")
	call_deferred("_after_route_edit")

func _on_route_add() -> void:
	_controller.call("route_add", _selected_town)
	call_deferred("_after_route_edit")

func _on_route_remove(town_id: String) -> void:
	_controller.call("route_remove", town_id)
	call_deferred("_after_route_edit")

func _on_route_move(town_id: String, dir: int) -> void:
	_controller.call("route_move", town_id, dir)
	call_deferred("_after_route_edit")

func _after_trade() -> void:
	# A buy/sell changed wallet, hold and town stock — refresh everything that
	# shows those, including the per-good rows (hold number, stock number).
	_render_money()
	_render_ship()
	_render_town()
	_rebuild_trade_panel()

func _after_route_edit() -> void:
	_render_ship()
	_render_money()
	_rebuild_trade_panel()
	_rebuild_route_panel()
	_rebuild_diplo_panel()   # Stage A3.1
	_highlight_speed()

# -------------------------------------------------------------- panel builders --

func _dock_town_id() -> String:
	return String(_controller.call("player_dock_town_id"))

func _rebuild_trade_panel() -> void:
	_clear(_trade_panel)
	var dock: String = _dock_town_id()
	var docked_here: bool = dock != "" and dock == _selected_town
	_town_body.visible = not docked_here
	_trade_panel.visible = docked_here
	if not docked_here:
		return
	var t: Town = WorldState.get_town(_selected_town)
	if t == null:
		return
	var ship: Ship = WorldState.get_player_ship()

	# Header: dock banner (town + state) + Depart button (shows the next destination).
	var next_id: String = String(_controller.call("player_next_destination"))
	var next_name: String = "—"
	var nt: Town = WorldState.get_town(next_id)
	if nt != null:
		next_name = nt.name
	# state affiliation shown in the banner, tax rate on the readout line
	# below — so the player sees whose port they're in and what customs they'll
	# pay before they click Buy. Previously the docked view showed neither.
	var st: State = WorldState.get_state(t.state_id)
	var st_name: String = st.name if st != null else "—"
	var tax_pct: int = int(round(st.tax_rate * 100.0)) if st != null else 0
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 6)
	_trade_panel.add_child(hdr)
	_mklabel(hdr, "Docked at %s [%s]" % [t.name, st_name], 14, Color(0.5, 0.85, 1.0))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(spacer)
	var dep := _mkbutton(hdr, "Depart -> %s" % next_name, Callable(self, "_on_depart"),
			150.0, 26.0, 13, Color(1.0, 0.9, 0.2))
	if next_id == "" or next_id == dock:
		dep.disabled = true
	# port economic readout — population, market fund, satisfaction, and
	# the customs tax rate. The docked view used to clear this entirely; now it
	# shows the same context the read-only inspection view does.
	_mklabel(_trade_panel, "pop %d · fund $%.0f · sat %d%% · tax %d%%" %
			[int(t.total_population()), t.market.fund, int(t.satisfaction * 100.0), tax_pct],
			12, Color(0.6, 0.65, 0.7))

	# Column header. U1: dem/sup columns added so the docked player sees market
	# pressure at the port they're trading in (the read-only inspection view
	# already had them; the docked trade panel dropped them).
	_mklabel(_trade_panel, "%-12s %6s %7s %4s %4s %4s" %
			["good", "stock", "price", "dem", "sup", "hold"],
			12, Color(0.55, 0.6, 0.65))

	# One row per good that is active in this port OR carried by the ship (so
	# the player can always sell what they brought in, even into a dead market).
	var ids: Array = t.market.entries.keys()
	ids.sort()
	for gid in ids:
		var e: Market.Entry = t.market.entries[gid]
		var hold: float = ship.cargo_qty(String(gid)) if ship != null else 0.0
		var active: bool = e.stock > 0.01 or e.daily_demand > 0.01 or e.daily_supply > 0.01
		if not active and hold <= 0.0:
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 3)
		_trade_panel.add_child(row)
		var lab := _mklabel(row, "%-12s %6.1f %7.2f %4.0f %4.0f %4.0f" %
				[String(gid), e.stock, e.current_price, e.daily_demand, e.daily_supply, hold],
				12, Color(0.85, 0.85, 0.85))
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mkbutton(row, "Buy 1", Callable(self, "_on_buy").bind(String(gid), 1.0), 50.0, 22.0, 12, Color(0.5, 0.9, 0.55))
		_mkbutton(row, "Buy 10", Callable(self, "_on_buy").bind(String(gid), 10.0), 58.0, 22.0, 12, Color(0.5, 0.9, 0.55))
		_mkbutton(row, "Sell 1", Callable(self, "_on_sell").bind(String(gid), 1.0), 52.0, 22.0, 12, Color(0.95, 0.6, 0.55))
		_mkbutton(row, "Sell 10", Callable(self, "_on_sell").bind(String(gid), 10.0), 60.0, 22.0, 12, Color(0.95, 0.6, 0.55))
		_mkbutton(row, "All", Callable(self, "_on_sell").bind(String(gid), 99999.0), 40.0, 22.0, 12, Color(0.95, 0.6, 0.55))

func _rebuild_route_panel() -> void:
	_clear(_route_panel)
	var ship: Ship = WorldState.get_player_ship()
	if ship == null:
		_mklabel(_route_panel, "(no ship)", 12, Color(0.6, 0.6, 0.6))
		return
	var route: TradeRoute = WorldState.get_route(ship.route_id)
	if route == null:
		_mklabel(_route_panel, "(no route)", 12, Color(0.6, 0.6, 0.6))
		return
	# Bugfix: do NOT early-return on empty stops — the "+ Add" button below
	# is the ONLY way to put the first town back into an emptied route.
	# Render the hint label and fall through.
	if route.stops.is_empty():
		_mklabel(_route_panel, "(empty — click a town then + Add)", 12, Color(0.6, 0.6, 0.6))
	var dock: String = _dock_town_id()
	for i in range(route.stops.size()):
		var sid: String = String(route.stops[i])
		var tt: Town = WorldState.get_town(sid)
		var mark: String = ">" if sid == dock else " "
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 3)
		_route_panel.add_child(row)
		_mkbutton(row, "Up", Callable(self, "_on_route_move").bind(sid, -1), 30.0, 20.0, 11, Color(0.75, 0.78, 0.82))
		_mkbutton(row, "Dn", Callable(self, "_on_route_move").bind(sid, 1), 30.0, 20.0, 11, Color(0.75, 0.78, 0.82))
		_mklabel(row, "%s %s" % [mark, tt.name if tt != null else sid], 12, Color(0.85, 0.85, 0.85))
		_mkbutton(row, "Del", Callable(self, "_on_route_remove").bind(sid), 34.0, 20.0, 11, Color(0.95, 0.6, 0.55))
	# Add the currently selected town (disabled if already in the route or empty).
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 4)
	_route_panel.add_child(add_row)
	var sel: Town = WorldState.get_town(_selected_town)
	var sel_name: String = sel.name if sel != null else _selected_town
	var already: bool = route != null and route.stops.has(_selected_town)
	var add_btn := _mkbutton(add_row, "+ Add %s" % sel_name, Callable(self, "_on_route_add"),
			130.0, 22.0, 12, Color(0.5, 0.85, 1.0))
	add_btn.disabled = already or _selected_town == ""

# --- diplomacy panel (bribe + citizenship per state) ---
# One row per colonial power: current-flag star, name, rep (green/red), Bribe
# button (cost scales with hostility, 4-week cooldown), Citizenship button
# (needs rep>50 + $5000, switches the ship's flag_state). All mutations are
# delegated to the Main controller (bribe_state / apply_citizenship); the panel
# only reads state to set its own disable flags and button labels.
# Below the per-state rows, a read-only state↔state relations
# matrix + active-wars summary (who is at war with whom) — refreshed weekly
# by _on_day_advanced (cadence matches WarSystem.roll_weekly).
func _rebuild_diplo_panel() -> void:
	_clear(_diplo_panel)
	var company: Company = WorldState.get_company("player")
	if company == null:
		_mklabel(_diplo_panel, "(no company)", 12, Color(0.6, 0.6, 0.6))
		return
	var ship: Ship = WorldState.get_player_ship()
	var flag_now: String = ship.flag_state if ship != null else ""
	for s in WorldState.states:
		var rep: float = WorldState.get_player_rep(s.id)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_diplo_panel.add_child(row)
		var flag_mark: String = "★" if s.id == flag_now else "  "
		_mklabel(row, "%s %-12s" % [flag_mark, s.name], 12, Color(0.85, 0.85, 0.85))
		var rep_color: Color = Color(0.45, 0.85, 0.45) if rep >= 0.0 else Color(0.95, 0.55, 0.45)
		_mklabel(row, "rep %+5.0f" % rep, 12, rep_color)
		var bribe_cost: float = 500.0 * (1.0 + max(0.0, -rep / 50.0))
		var last_week: int = int(company.bribe_cooldowns.get(s.id, -999))
		var on_cd: bool = SimulationClock.week - last_week < 4
		var bribe_btn := _mkbutton(row, "Bribe %.0f" % bribe_cost, Callable(self, "_on_bribe").bind(s.id),
			80.0, 20.0, 11, Color(0.85, 0.75, 0.45))
		bribe_btn.disabled = on_cd or company.money < bribe_cost
		var cit_btn := _mkbutton(row, "Citizenship", Callable(self, "_on_citizenship").bind(s.id),
			90.0, 20.0, 11, Color(0.55, 0.75, 0.95))
		cit_btn.disabled = rep <= 50.0 or company.money < 5000.0 or s.id == flag_now
	# --- State↔state relations matrix + active wars ---
	# Read-only view of who is at war with whom (the per-state rows above show
	# the player's own standing). Wars block enemy-flag docking (ShipsTick) and
	# double customs for foreign traders (TradeSystem war tariff), so seeing
	# them here is what makes route planning + citizenship tactical.
	_diplo_panel.add_child(_sep())
	_mklabel(_diplo_panel, "— state relations —", 12, Color(0.7, 0.75, 0.7))
	# Active wars summary line (or "(no active wars)" in peacetime).
	var war_parts: PackedStringArray = PackedStringArray()
	for w in WorldState.active_wars:
		var sa: State = WorldState.get_state(w.state_a)
		var sb: State = WorldState.get_state(w.state_b)
		var na: String = sa.name if sa != null else w.state_a
		var nb: String = sb.name if sb != null else w.state_b
		war_parts.append("%s ↔ %s" % [na, nb])
	var war_txt: String = ("⚔ " + ", ".join(war_parts)) if war_parts.size() > 0 else "(no active wars)"
	var war_col: Color = Color(0.95, 0.4, 0.4) if war_parts.size() > 0 else Color(0.5, 0.6, 0.5)
	_mklabel(_diplo_panel, war_txt, 11, war_col)
	# One row per state pair (C(N,2), deterministic order): relation value
	# colored by warmth — red+⚔ at war, orange <= -40, yellow < 0, green >= 0.
	var sarr: Array = WorldState.states
	for i in sarr.size():
		for j in range(i + 1, sarr.size()):
			var a: State = sarr[i]
			var b: State = sarr[j]
			var rel: float = WorldState.get_relation(a.id, b.id)
			var aw: bool = WorldState.at_war(a.id, b.id)
			var rrow := HBoxContainer.new()
			rrow.add_theme_constant_override("separation", 4)
			_diplo_panel.add_child(rrow)
			var mark: String = "⚔" if aw else "  "
			var rc: Color
			if aw:
				rc = Color(0.95, 0.35, 0.35)
			elif rel <= -40.0:
				rc = Color(0.95, 0.6, 0.3)
			elif rel < 0.0:
				rc = Color(0.95, 0.85, 0.4)
			else:
				rc = Color(0.5, 0.85, 0.5)
			_mklabel(rrow, "%s %-11s ↔ %-11s %+5.0f" % [mark, a.name, b.name, rel], 11, rc)

func _on_bribe(state_id: String) -> void:
	_controller.call("bribe_state", state_id)
	call_deferred("_after_diplo_edit")

func _on_citizenship(state_id: String) -> void:
	_controller.call("apply_citizenship", state_id)
	call_deferred("_after_diplo_edit")

func _after_diplo_edit() -> void:
	_render_money()
	_render_ship()
	_rebuild_diplo_panel()

# -------------------------------------------------------------- rendering --

func _render_clock() -> void:
	_day_label.text = "Day %d · Wk %d" % [SimulationClock.day, SimulationClock.week]

func _render_money() -> void:
	var co: Company = WorldState.get_company("player")
	_money_label.text = "$ %.0f" % (co.money if co != null else 0.0)

func _render_town() -> void:
	var t: Town = WorldState.get_town(_selected_town)
	if t == null:
		_town_title.text = "— Town —"
		_town_body.text = "(no town selected)"
		return
	_town_title.text = "— %s —" % t.name
	if _dock_town_id() == _selected_town:
		# The trade panel renders the per-good rows; the read-only table is hidden.
		_town_body.text = ""
		return
	# A distant town shows the player's PRICE MEMORY only — the
	# last-seen price per good with a staleness tag — not live stock/demand. A
	# captain knows which goods a port trades (common knowledge) but only what
	# they last paid/heard; dock to refresh. Real prices + stock show only at
	# the docked town (the trade panel above). Symmetric with the AI's info
	# model (AIBrain reads the same memory), so scouting is what beats a rival.
	var lines := PackedStringArray()
	var co: Company = WorldState.get_company("player")
	var mem: PriceMemory = co.memory if co != null else null
	var day: int = SimulationClock.day
	var fresh_count: int = 0
	var ids: Array = t.market.entries.keys()
	ids.sort()
	for gid in ids:
		var est: Dictionary = mem.estimate(t.id, String(gid), day) if mem != null else {}
		if est.is_empty():
			continue   # never seen a price for this good here -> don't list it
		var da: int = int(est["days_ago"])
		if da <= PriceMemory.MEMORY_DAYS:
			fresh_count += 1
		var tag: String = "now" if da == 0 else ("%dd" % da)
		if da > PriceMemory.MEMORY_DAYS:
			tag += "*"   # stale — older than MEMORY_DAYS, trust at your risk
		lines.append("%-11s %7.2f  %s" % [String(gid), float(est["price"]), tag])
	if lines.is_empty():
		lines.append("(no price memory for %s — sail there to learn)" % t.name)
	else:
		lines.insert(0, "%-11s %7s  %s" % ["good", "price", "last saw"])
		lines.insert(0, "(memory, %d fresh — dock to refresh; * = stale)" % fresh_count)
	_town_body.text = "\n".join(lines)

func _render_ship() -> void:
	var s: Ship = WorldState.get_player_ship()
	if s == null:
		_ship_body.text = "(no ship)"
		return
	var co: Company = WorldState.get_company(s.owner_id)
	var here: Town = WorldState.get_town(s.current_town_id)
	var lines := PackedStringArray()
	lines.append("state %-8s at %-11s dest %s" %
			[s.state, here.name if here != null else "—",
			 WorldState.get_town(s.destination_id).name if s.destination_id != "" and WorldState.get_town(s.destination_id) != null else s.destination_id])
	# today's net wallet delta — money - last_day_money (snapshot taken at
	# the start of the day in SimulationEngine.step_day). Shown only from day 1
	# on; on day 0 last_day_money is still the default 0 and the delta would be
	# meaningless. With the per-event upkeep log this answers "where did the
	# money go" both in aggregate (here) and per drain (log panel).
	var day_delta := ""
	if co != null and SimulationClock.day >= 1:
		day_delta = "   day Δ %+.0f" % (co.money - co.last_day_money)
	lines.append("cargo %.0f/%.0f   wallet $%.0f%s" %
			[s.cargo_used, s.cargo_capacity, co.money if co != null else 0.0, day_delta])
	if not s.cargo.is_empty():
		var parts := PackedStringArray()
		for gid in s.cargo.keys():
			parts.append("%s=%.0f" % [String(gid), float(s.cargo[gid])])
		lines.append("hold: " + ", ".join(parts))
	_ship_body.text = "\n".join(lines)
