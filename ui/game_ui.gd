extends Control

## Stage UI-4 game_ui — the right-column controller with a 4-page tab switch.
##
## UI-1 split the static parts into scenes (hud/town_panel/event_log/world_map)
## and UI-1-fix made their roots real Containers so they lay out. UI-3 added a
## 3-button tab bar (Main/Town/Log) so the player navigates between views
## instead of scrolling one giant column. UI-4 adds the first aggregate screen:
##
##   Main page      — Ship readout + Route + Diplomacy (the player's daily ops).
##                   Route/Diplo are still built in code here; a later stage will
##                   scene them and move each to its own tab.
##   Town page      — TownPanel (price-memory inspection, or the trade panel
##                   when docked). Auto-selected on map click and on dock.
##   Log page       — EventLog. Self-contained (subscribes to EventBus.message
##                   itself), keeps buffering while hidden.
##   Companies page — CompaniesPanel. Self-contained (subscribes to
##                   EventBus.day_advanced itself). Lists every company in the
##                   world with money / day-delta / fleet / loans / bankrupt —
##                   the first screen that shows the competition, which the old
##                   UI never exposed.
##
## HUD stays visible on every page (speed/day/money are global). Selecting a
## town or docking flips to the Town page automatically; the tab buttons are
## the way back to Main / Log / Companies. Companies is an overview screen, so
## it is never auto-selected. No economic state is held here — same reads
## (WorldState / SimulationClock) and same EventBus emissions as before, so
## determinism and money conservation are unaffected.
##
## The public surface main.gd / AsciiMap relied on is unchanged: select_town
## and the _on_* signal handlers.

const TAB_MAIN: int = 0
const TAB_TOWN: int = 1
const TAB_LOG: int = 2
const TAB_COMPANIES: int = 3

var _controller: Node = null          # the Main root node (owns the engine)
var _selected_town: String = "tortuga"
var _tab: int = TAB_MAIN

# Static view nodes from the scene (sub-scene internals via their scripts).
# Stage UI-3: TownPanel and EventLog moved under Pages/{TownPage,LogPage};
# Ship/Route/Diplo moved under Pages/MainPage. UI-4: CompaniesPanel under
# Pages/CompaniesPage.
@onready var _hud: Control = $Split/Right/HUD
@onready var _tab_main_btn: Button = %TabMain
@onready var _tab_town_btn: Button = %TabTown
@onready var _tab_log_btn: Button = %TabLog
@onready var _tab_companies_btn: Button = %TabCompanies
@onready var _main_page: VBoxContainer = %MainPage
@onready var _town_page: VBoxContainer = %TownPage
@onready var _log_page: VBoxContainer = %LogPage
@onready var _companies_page: VBoxContainer = %CompaniesPage
@onready var _town_panel: Control = $Split/Right/Pages/TownPage/TownPanel
@onready var _ship_body: Label = %ShipBody
@onready var _route_panel: VBoxContainer = %RouteSlot
@onready var _diplo_panel: VBoxContainer = %DiploSlot

# Convenience accessors into the sub-scene's exposed nodes.
@onready var _town_title: Label = _town_panel.title_label
@onready var _town_body: Label = _town_panel.body_label
@onready var _trade_panel: VBoxContainer = _town_panel.trade_slot

func _ready() -> void:
	_controller = get_parent()
	# Theme the static labels game_ui still owns (ShipHeader / RouteHeader /
	# DiploHeader) and the dynamic body label, so they match the old look.
	# UI-3: these labels now live under Pages/MainPage.
	var f := UITheme.load_font()
	for lname in ["ShipHeader", "RouteHeader", "DiploHeader"]:
		var l: Label = get_node("Split/Right/Pages/MainPage/" + lname)
		l.add_theme_font_override("font", f)
		l.add_theme_font_size_override("font_size", 15)
		l.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_ship_body.add_theme_font_override("font", f)
	_ship_body.add_theme_font_size_override("font_size", 13)
	_ship_body.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_ship_body.custom_minimum_size = Vector2(0.0, 70.0)
	# UI-3: theme the tab buttons (same font/size as HUD speed buttons) and wire
	# them. Active-tab highlight is applied by _set_tab. UI-4 adds Companies.
	for b in [_tab_main_btn, _tab_town_btn, _tab_log_btn, _tab_companies_btn]:
		b.add_theme_font_override("font", f)
		b.add_theme_font_size_override("font_size", 13)
	_tab_main_btn.pressed.connect(_set_tab.bind(TAB_MAIN))
	_tab_town_btn.pressed.connect(_set_tab.bind(TAB_TOWN))
	_tab_log_btn.pressed.connect(_set_tab.bind(TAB_LOG))
	_tab_companies_btn.pressed.connect(_set_tab.bind(TAB_COMPANIES))
	# The AsciiMap is now a sub-scene; wire its town_selected signal here (it
	# used to be wired in _build_layout right after .new()).
	var map: AsciiMap = $Split/WorldMap
	map.town_selected.connect(_on_town_selected)
	# EventLog now self-subscribes to EventBus.message; game_ui no longer owns
	# the log label or the ring buffer. The old welcome messages are emitted
	# directly so the log scene picks them up.
	EventBus.day_advanced.connect(_on_day_advanced)
	EventBus.trade_completed.connect(_on_trade_completed)
	EventBus.town_updated.connect(_on_town_updated)
	EventBus.ship_docked.connect(_on_ship_docked)
	_refresh_all()
	_set_tab(TAB_MAIN)
	EventBus.message.emit("UI ready — docked at Tortuga. Trade, edit the route, then Depart.")
	EventBus.message.emit("Tabs: Main (ship/route/diplo) · Town (inspect/trade) · Log · Companies (rivals).")
	EventBus.message.emit("Space pause · 1/2/3 speed · click a town to inspect it.")

# -------------------------------------------------------------- tab switching --

# Show exactly one page, highlight the active tab. Called on tab-button press
# and on auto-select (click a town / dock). Idempotent — safe to call with the
# current tab.
func _set_tab(idx: int) -> void:
	_tab = idx
	_main_page.visible = (idx == TAB_MAIN)
	_town_page.visible = (idx == TAB_TOWN)
	_log_page.visible = (idx == TAB_LOG)
	_companies_page.visible = (idx == TAB_COMPANIES)
	var active_color := Color(1.0, 0.9, 0.2)
	var idle_color := Color(0.75, 0.78, 0.82)
	_tab_main_btn.add_theme_color_override("font_color",
			active_color if idx == TAB_MAIN else idle_color)
	_tab_town_btn.add_theme_color_override("font_color",
			active_color if idx == TAB_TOWN else idle_color)
	_tab_log_btn.add_theme_color_override("font_color",
			active_color if idx == TAB_LOG else idle_color)
	_tab_companies_btn.add_theme_color_override("font_color",
			active_color if idx == TAB_COMPANIES else idle_color)

# ----------------------------------------------------------------- public api --

# Called by main.gd when the ship docks (auto-selects the port town so the
# trade panel opens immediately). Also used to sync selection.
func select_town(town_id: String) -> void:
	_selected_town = town_id
	_render_town()
	_rebuild_trade_panel()
	_rebuild_route_panel()
	_rebuild_diplo_panel()
	# UI-3: clicking a town (or auto-select on dock) jumps to the Town page so
	# the inspection / trade panel is immediately in view, not 3 screens down.
	_set_tab(TAB_TOWN)

# -------------------------------------------------------------- signal ops --

func _on_day_advanced(_day: int) -> void:
	_render_ship()
	_render_town()
	_rebuild_trade_panel()
	# Refresh the diplomacy panel (state-pair relations + active wars + per-state
	# rep) on the weekly boundary — wars/relations only change in
	# WarSystem.roll_weekly, which fires when the week advances, so a weekly
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
	_rebuild_diplo_panel()
	_hud.call("refresh")
	# UI-3: docking flips to the Town page so the trade panel is in view — the
	# player's next action is almost always "trade here", not "scroll to Town".
	_set_tab(TAB_TOWN)

func _on_trade_completed(_town_id: String, _good_id: String, _qty: float, _price: float) -> void:
	# trade_system already emitted a human-readable message; refresh the
	# wallet/cargo/stock displays without waiting for the next day. (HUD owns
	# clock+money now; it subscribes to day_advanced directly, so no manual
	# clock/money refresh is needed here.)
	_render_ship()
	_render_town()
	_rebuild_trade_panel()

func _refresh_all() -> void:
	_render_town()
	_render_ship()
	_rebuild_trade_panel()
	_rebuild_route_panel()
	_rebuild_diplo_panel()
	_hud.call("refresh")

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
	_render_ship()
	_render_town()
	_rebuild_trade_panel()

func _after_route_edit() -> void:
	_render_ship()
	_rebuild_trade_panel()
	_rebuild_route_panel()
	_rebuild_diplo_panel()
	_hud.call("refresh")

# -------------------------------------------------------------- panel builders --

func _clear(c: Node) -> void:
	for child in c.get_children():
		child.free()

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
	UITheme.make_label(hdr, "Docked at %s [%s]" % [t.name, st_name], 14, Color(0.5, 0.85, 1.0))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(spacer)
	var dep := UITheme.make_button(hdr, "Depart -> %s" % next_name, Callable(self, "_on_depart"),
			150.0, 26.0, 13, Color(1.0, 0.9, 0.2))
	if next_id == "" or next_id == dock:
		dep.disabled = true
	# port economic readout — population, market fund, satisfaction, and
	# the customs tax rate. The docked view used to clear this entirely; now it
	# shows the same context the read-only inspection view does.
	UITheme.make_label(_trade_panel, "pop %d · fund $%.0f · sat %d%% · tax %d%%" %
			[int(t.total_population()), t.market.fund, int(t.satisfaction * 100.0), tax_pct],
			12, Color(0.6, 0.65, 0.7))

	# Column header. U1: dem/sup columns added so the docked player sees market
	# pressure at the port they're trading in (the read-only inspection view
	# already had them; the docked trade panel dropped them).
	UITheme.make_label(_trade_panel, "%-12s %6s %7s %4s %4s %4s" %
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
		var lab := UITheme.make_label(row, "%-12s %6.1f %7.2f %4.0f %4.0f %4.0f" %
				[String(gid), e.stock, e.current_price, e.daily_demand, e.daily_supply, hold],
				12, Color(0.85, 0.85, 0.85))
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.make_button(row, "Buy 1", Callable(self, "_on_buy").bind(String(gid), 1.0), 50.0, 22.0, 12, Color(0.5, 0.9, 0.55))
		UITheme.make_button(row, "Buy 10", Callable(self, "_on_buy").bind(String(gid), 10.0), 58.0, 22.0, 12, Color(0.5, 0.9, 0.55))
		UITheme.make_button(row, "Sell 1", Callable(self, "_on_sell").bind(String(gid), 1.0), 52.0, 22.0, 12, Color(0.95, 0.6, 0.55))
		UITheme.make_button(row, "Sell 10", Callable(self, "_on_sell").bind(String(gid), 10.0), 60.0, 22.0, 12, Color(0.95, 0.6, 0.55))
		UITheme.make_button(row, "All", Callable(self, "_on_sell").bind(String(gid), 99999.0), 40.0, 22.0, 12, Color(0.95, 0.6, 0.55))

func _rebuild_route_panel() -> void:
	_clear(_route_panel)
	var ship: Ship = WorldState.get_player_ship()
	if ship == null:
		UITheme.make_label(_route_panel, "(no ship)", 12, Color(0.6, 0.6, 0.6))
		return
	var route: TradeRoute = WorldState.get_route(ship.route_id)
	if route == null:
		UITheme.make_label(_route_panel, "(no route)", 12, Color(0.6, 0.6, 0.6))
		return
	# Bugfix: do NOT early-return on empty stops — the "+ Add" button below
	# is the ONLY way to put the first town back into an emptied route.
	# Render the hint label and fall through.
	if route.stops.is_empty():
		UITheme.make_label(_route_panel, "(empty — click a town then + Add)", 12, Color(0.6, 0.6, 0.6))
	var dock: String = _dock_town_id()
	for i in range(route.stops.size()):
		var sid: String = String(route.stops[i])
		var tt: Town = WorldState.get_town(sid)
		var mark: String = ">" if sid == dock else " "
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 3)
		_route_panel.add_child(row)
		UITheme.make_button(row, "Up", Callable(self, "_on_route_move").bind(sid, -1), 30.0, 20.0, 11, Color(0.75, 0.78, 0.82))
		UITheme.make_button(row, "Dn", Callable(self, "_on_route_move").bind(sid, 1), 30.0, 20.0, 11, Color(0.75, 0.78, 0.82))
		UITheme.make_label(row, "%s %s" % [mark, tt.name if tt != null else sid], 12, Color(0.85, 0.85, 0.85))
		UITheme.make_button(row, "Del", Callable(self, "_on_route_remove").bind(sid), 34.0, 20.0, 11, Color(0.95, 0.6, 0.55))
	# Add the currently selected town (disabled if already in the route or empty).
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 4)
	_route_panel.add_child(add_row)
	var sel: Town = WorldState.get_town(_selected_town)
	var sel_name: String = sel.name if sel != null else _selected_town
	var already: bool = route != null and route.stops.has(_selected_town)
	var add_btn := UITheme.make_button(add_row, "+ Add %s" % sel_name, Callable(self, "_on_route_add"),
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
		UITheme.make_label(_diplo_panel, "(no company)", 12, Color(0.6, 0.6, 0.6))
		return
	var ship: Ship = WorldState.get_player_ship()
	var flag_now: String = ship.flag_state if ship != null else ""
	for s in WorldState.states:
		var rep: float = WorldState.get_player_rep(s.id)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_diplo_panel.add_child(row)
		var flag_mark: String = "★" if s.id == flag_now else "  "
		UITheme.make_label(row, "%s %-12s" % [flag_mark, s.name], 12, Color(0.85, 0.85, 0.85))
		var rep_color: Color = Color(0.45, 0.85, 0.45) if rep >= 0.0 else Color(0.95, 0.55, 0.45)
		UITheme.make_label(row, "rep %+5.0f" % rep, 12, rep_color)
		var bribe_cost: float = 500.0 * (1.0 + max(0.0, -rep / 50.0))
		var last_week: int = int(company.bribe_cooldowns.get(s.id, -999))
		var on_cd: bool = SimulationClock.week - last_week < 4
		var bribe_btn := UITheme.make_button(row, "Bribe %.0f" % bribe_cost, Callable(self, "_on_bribe").bind(s.id),
			80.0, 20.0, 11, Color(0.85, 0.75, 0.45))
		bribe_btn.disabled = on_cd or company.money < bribe_cost
		var cit_btn := UITheme.make_button(row, "Citizenship", Callable(self, "_on_citizenship").bind(s.id),
			90.0, 20.0, 11, Color(0.55, 0.75, 0.95))
		cit_btn.disabled = rep <= 50.0 or company.money < 5000.0 or s.id == flag_now
	# --- State↔state relations matrix + active wars ---
	# Read-only view of who is at war with whom (the per-state rows above show
	# the player's own standing). Wars block enemy-flag docking (ShipsTick) and
	# double customs for foreign traders (TradeSystem war tariff), so seeing
	# them here is what makes route planning + citizenship tactical.
	_diplo_panel.add_child(UITheme.make_separator())
	UITheme.make_label(_diplo_panel, "— state relations —", 12, Color(0.7, 0.75, 0.7))
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
	UITheme.make_label(_diplo_panel, war_txt, 11, war_col)
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
			UITheme.make_label(rrow, "%s %-11s ↔ %-11s %+5.0f" % [mark, a.name, b.name, rel], 11, rc)

func _on_bribe(state_id: String) -> void:
	_controller.call("bribe_state", state_id)
	call_deferred("_after_diplo_edit")

func _on_citizenship(state_id: String) -> void:
	_controller.call("apply_citizenship", state_id)
	call_deferred("_after_diplo_edit")

func _after_diplo_edit() -> void:
	_render_ship()
	_rebuild_diplo_panel()

# -------------------------------------------------------------- rendering --

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
