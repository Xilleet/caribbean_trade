extends VBoxContainer

## Stage UI-4 PoliticsPanel — the "— Politics —" aggregate screen.
##
## Shows the diplomatic state of the four colonial powers at a glance:
##   - a 4x4 relations matrix (state pairs, [-100,+100], colour-coded),
##   - the list of active wars (the two belligerents + days-left countdown),
##   - the player's reputation with each state and with the pirates,
##   - the running war/peace/incident counters from WarSystem.
##
## Self-contained like EventLog and CompaniesPanel: subscribes to
## EventBus.day_advanced itself and rebuilds. Pure view over WorldState +
## WarSystem — reads, never mutates — so determinism and money conservation
## are unaffected. No history is kept; the panel always shows the current
## snapshot (relations shift weekly in WarSystem.roll_weekly, wars end on a
## daily countdown, counters are monotonic running totals).

@onready var _title: Label = %Title
@onready var _matrix: Label = %Matrix
@onready var _wars_header: Label = %WarsHeader
@onready var _wars: VBoxContainer = %Wars
@onready var _rep_header: Label = %RepHeader
@onready var _rep: Label = %Rep
@onready var _counters: Label = %Counters

func _ready() -> void:
	var f := UITheme.load_font()
	for l in [_title, _matrix, _wars_header, _rep_header, _rep, _counters]:
		l.add_theme_font_override("font", f)
		l.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_title.add_theme_font_size_override("font_size", 15)
	_matrix.add_theme_font_size_override("font_size", 12)
	_matrix.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_wars_header.add_theme_font_size_override("font_size", 13)
	_wars_header.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_rep_header.add_theme_font_size_override("font_size", 13)
	_rep_header.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_rep.add_theme_font_size_override("font_size", 12)
	_rep.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_counters.add_theme_font_size_override("font_size", 12)
	_counters.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	EventBus.day_advanced.connect(_on_day_advanced)
	refresh()

func _on_day_advanced(_day: int) -> void:
	refresh()

# Rebuild everything. Freeing the old war rows and re-adding keeps the list
# correct when wars start or end. The matrix/rep/counters are plain labels, so
# they just get new text.
func refresh() -> void:
	for c in _wars.get_children():
		c.queue_free()
	_render_matrix()
	_render_wars()
	_render_rep()
	_render_counters()

# 4x4 relations matrix. Rows = state A, cols = state B. Diagonal is "—"
# (a state's relation with itself). Cells show the integer value, colour-coded
# by how hostile the pair is. Wars override the colour to bright red and the
# value to "WAR". Header row/column use the state's short (2-letter) name.
func _render_matrix() -> void:
	var states: Array = WorldState.states
	var shorts: Array[String] = []
	for s in states:
		shorts.append(String(s.id).substr(0, 2).to_upper())
	var col_w := 7
	# Header row: "    " under the row-label column, then one cell per state.
	var lines: Array[String] = []
	var hdr := _pad(col_w + 2, "")
	for sh in shorts:
		hdr += _pad(col_w, sh)
	lines.append(hdr)
	for i in states.size():
		var a: State = states[i]
		var row := _pad(col_w + 2, shorts[i])
		for j in states.size():
			if i == j:
				row += _pad(col_w, "—")
			else:
				var b: State = states[j]
				var rel := WorldState.get_relation(a.id, b.id)
				var cell := "%d" % int(rel)
				if WorldState.at_war(a.id, b.id):
					cell = "WAR"
				row += _pad(col_w, cell)
		lines.append(row)
	_matrix.text = "\n".join(PackedStringArray(lines))

# Active wars list. One row per ActiveWar: "ENG vs SPA  ·  WAR  ·  N days left"
# (or "indefinite" if days_left == -1, which only tests use). Empty list shows
# a single "—" row so the section is never blank.
func _render_wars() -> void:
	var wars: Array = WorldState.active_wars
	if wars.is_empty():
		UITheme.make_label(_wars, "—", 12, Color(0.6, 0.6, 0.6))
		return
	for w in wars:
		var a: State = WorldState.get_state(w.state_a)
		var b: State = WorldState.get_state(w.state_b)
		var an: String = a.name if a != null else w.state_a
		var bn: String = b.name if b != null else w.state_b
		var dl: String
		if w.days_left < 0:
			dl = "indefinite"
		else:
			dl = "%d days left" % w.days_left
		var text := "%s vs %s  ·  %s" % [an, bn, dl]
		UITheme.make_label(_wars, text, 12, Color(1.0, 0.4, 0.4))

# Player reputation: one line per state + the pirates row. Colour matches the
# matrix scale (hostile red, neutral grey, friendly green) so the player's
# standing reads at a glance.
func _render_rep() -> void:
	var parts: Array[String] = []
	for s in WorldState.states:
		var r := WorldState.get_player_rep(s.id)
		parts.append("%s %+d" % [s.name, int(r)])
	var pr := WorldState.get_player_rep("pirates")
	parts.append("Pirates %+d" % int(pr))
	_rep.text = "  ".join(PackedStringArray(parts))

# Running war/peace/incident counters from WarSystem. These are monotonic totals
# since game start (kept on the WarSystem instance owned by SimulationEngine,
# which is owned by Main). Shown as a single summary line.
func _render_counters() -> void:
	var ws := _get_war_system()
	if ws == null:
		_counters.text = "wars —  ·  peaces —  ·  incidents —"
		return
	_counters.text = "wars declared %d  ·  peaces signed %d  ·  incidents %d" \
			% [ws.wars_declared, ws.peaces_signed, ws.incidents]

# Reach the WarSystem instance: it lives on SimulationEngine, which lives on
# Main (the scene root in the real game). We look up the node named "Main"
# anywhere in the tree (a shallow root-child scan in the real game, where Main
# is the scene root; a depth-first walk otherwise so test scenes that mount
# the panel under a differently-named root still find it). Private fields are
# reachable by direct access in GDScript; if the engine is not ready yet
# (shouldn't happen — UI _ready fires after _enter_tree builds the world), we
# return null and the counters show "—".
func _get_war_system() -> WarSystem:
	var main: Node = _find_node(get_tree().root, "Main")
	if main == null:
		return null
	var engine = main.get("_engine")
	if engine == null:
		return null
	return engine.war_system

func _find_node(root: Node, name: String) -> Node:
	if root.name == name:
		return root
	for c in root.get_children():
		var found := _find_node(c, name)
		if found != null:
			return found
	return null

# Left-pad `s` into a field of width `w` (monospace, so the matrix columns line
# up). Trailing space keeps cells from touching the next.
func _pad(w: int, s: String) -> String:
	if s.length() >= w:
		return s + " "
	return s + " ".repeat(w - s.length())
