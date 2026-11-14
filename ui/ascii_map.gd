class_name AsciiMap
extends Control

## ASCII map (Dwarf-Fortress-style character grid), drawn entirely in code —
## no sprites, no tileset, no .tscn. A monospace font lays out a GW×GH grid of
## cells; world coordinates (Town.coords / Ship.pos) map onto it linearly.
##
##   ~   sea (left as the background)
##   ·   the player ship's planned route (dotted Bresenham between stops)
##   T P C G S   a town (first letter of its name)
##   b   the player's ship, at sea
##   B   the player's ship, docked in port (overrides the town letter)
##   a / A   a rival AI trader, at sea / docked
##
## Rebuilt once per simulated day on EventBus.day_advanced — towns, ship and
## route all change at day granularity, so redrawing per frame is unnecessary.
## Left-click a town glyph to select it (emits town_selected).

signal town_selected(town_id: String)

const GW: int = 60                # grid columns
const GH: int = 30                # grid rows
const FONT_SIZE: int = 16
# World bbox from data/towns.json (x 120..520, y 180..380) + 20-unit margin so
# glyphs do not kiss the border.
const WX0: float = 100.0
const WX1: float = 540.0
const WY0: float = 160.0
const WY1: float = 400.0
const FONT_PATH: String = "res://ui/fonts/DejaVuSansMono.ttf"

var _font: Font
var _cell_w: float = 10.0
var _cell_h: float = 19.0
var _grid: PackedStringArray = []          # GH rows, each a GW-char string
var _town_cells: Dictionary = {}           # "cx,cy" -> town_id

func _load_font() -> Font:
	# Prefer the bundled .ttf (consistent everywhere once the editor has imported
	# it); fall back to the OS monospace font so a direct `godot --path .` run
	# with no prior editor import still works.
	var f = load(FONT_PATH)
	if f != null and f is Font:
		return f
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"])
	return sf

func _ready() -> void:
	_font = _load_font()
	var sz: Vector2 = _font.get_string_size("M", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
	_cell_w = sz.x
	_cell_h = _font.get_height(FONT_SIZE) + 2.0
	# GW columns + one row below the grid for the legend.
	custom_minimum_size = Vector2(GW * _cell_w + 8.0, GH * _cell_h + _cell_h + 8.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_rebuild()
	EventBus.day_advanced.connect(_on_day_advanced)

func _on_day_advanced(_day: int) -> void:
	_rebuild()

func _rebuild() -> void:
	_town_cells.clear()
	var row_buf := "~".repeat(GW)
	_grid = PackedStringArray()
	for _r in range(GH):
		_grid.append(row_buf)
	# Towns first: their cells are reserved so the route dots skip them.
	for t in WorldState.towns:
		var c: Vector2i = _to_cell(t.coords)
		_set_cell(c.x, c.y, _town_glyph(t.id))
		_town_cells["%d,%d" % [c.x, c.y]] = t.id
	# Route dotted path between stops (wraparound circuit).
	_draw_route_path()
	# Ships. AI traders first ("a" at sea / "A" docked, cyan), then the player
	# ship on top ("b" / "B", red) so it is never hidden behind a rival sharing
	# the same town cell.
	for s in WorldState.ships:
		if s.owner_id == "player":
			continue
		var sc: Vector2i = _to_cell(s.pos)
		var adocked: bool = s.state == "docked" and _town_cells.has("%d,%d" % [sc.x, sc.y])
		_set_cell(sc.x, sc.y, "A" if adocked else "a")
	var pship: Ship = WorldState.get_player_ship()
	if pship != null:
		var psc: Vector2i = _to_cell(pship.pos)
		var pdocked: bool = pship.state == "docked" and _town_cells.has("%d,%d" % [psc.x, psc.y])
		_set_cell(psc.x, psc.y, "B" if pdocked else "b")
	queue_redraw()

func _draw_route_path() -> void:
	var s: Ship = WorldState.get_player_ship()
	if s == null:
		return
	var route: TradeRoute = WorldState.get_route(s.route_id)
	if route == null or route.stops.size() < 2:
		return
	var n: int = route.stops.size()
	for i in range(n):
		var a: Town = WorldState.get_town(route.stops[i])
		var b: Town = WorldState.get_town(route.stops[(i + 1) % n])
		if a == null or b == null:
			continue
		_bresenham_dots(_to_cell(a.coords), _to_cell(b.coords))

func _bresenham_dots(a0: Vector2i, b0: Vector2i) -> void:
	var x0: int = a0.x
	var y0: int = a0.y
	var x1: int = b0.x
	var y1: int = b0.y
	var dx: int = absi(x1 - x0)
	var dy: int = -absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy
	while true:
		var key := "%d,%d" % [x0, y0]
		# Do not overwrite town glyphs; the dot only fills open sea.
		if not _town_cells.has(key):
			_set_cell(x0, y0, "·")
		if x0 == x1 and y0 == y1:
			break
		var e2: int = 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy

func _to_cell(world: Vector2) -> Vector2i:
	var cx: int = int(round((world.x - WX0) / (WX1 - WX0) * float(GW - 1)))
	var cy: int = int(round((world.y - WY0) / (WY1 - WY0) * float(GH - 1)))
	return Vector2i(clampi(cx, 0, GW - 1), clampi(cy, 0, GH - 1))

func _set_cell(cx: int, cy: int, ch: String) -> void:
	if cx < 0 or cx >= GW or cy < 0 or cy >= GH:
		return
	var row: String = _grid[cy]
	_grid[cy] = row.substr(0, cx) + ch + row.substr(cx + 1)

func _town_glyph(town_id: String) -> String:
	# One uppercase letter per town; chosen so all five are distinct on the grid.
	match town_id:
		"tortuga": return "T"
		"port_royal": return "P"
		"cayman": return "C"
		"gibara": return "G"
		"santiago": return "S"
		_: return town_id.substr(0, 1).to_upper()

func _draw() -> void:
	var sea := Color(0.07, 0.16, 0.30)
	var route_c := Color(0.20, 0.55, 0.60)
	var town_c := Color(1.0, 0.84, 0.20)
	var ship_c := Color(1.0, 0.32, 0.30)
	var ai_c := Color(0.45, 0.85, 0.92)
	var off := Vector2(4.0, 4.0)
	draw_rect(Rect2(Vector2.ZERO, size), sea)
	var ascent: float = _font.get_ascent(FONT_SIZE)
	for r in range(GH):
		var row: String = _grid[r]
		for c in range(GW):
			var ch: String = row.substr(c, 1)
			if ch == "~":
				continue
			var col: Color
			match ch:
				"·": col = route_c
				"a", "A": col = ai_c
				"b", "B": col = ship_c
				_: col = town_c
			var px: float = off.x + float(c) * _cell_w
			var py: float = off.y + float(r) * _cell_h + ascent
			draw_string(_font, Vector2(px, py), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)
	# Legend row below the grid.
	var ly: float = off.y + float(GH) * _cell_h + ascent
	var legend := "towns T P C G S   you b/B   rival a/A   · = your route   [click a town]"
	draw_string(_font, Vector2(off.x, ly), legend, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(0.55, 0.6, 0.6))
	# Subtle border.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.2, 0.3, 0.4, 0.6), false, 1.0)

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	if not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var c: int = int((event.position.x - 4.0) / _cell_w)
	var r: int = int((event.position.y - 4.0) / _cell_h)
	# Exact cell, then a 3×3 neighbourhood so the single-glyph target is forgiving.
	if _select_if_town(c, r):
		return
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			if _select_if_town(c + dx, r + dy):
				return

func _select_if_town(c: int, r: int) -> bool:
	var key := "%d,%d" % [c, r]
	if _town_cells.has(key):
		town_selected.emit(_town_cells[key])
		return true
	return false
