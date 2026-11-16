extends VBoxContainer

## Stage UI-6 IndustryPanel — the "— Industry —" aggregate screen.
##
## Lists every industry in the world (16 recipes × up to 15 towns — usually
## ~80-140 rows since not every town builds every recipe) as one row each:
## town, recipe, owner, workers / target, capacity level, wear %, and the
## last day's profit. This is the production view the old UI never exposed:
## without it the player can't see who owns what, where lines are worn out
## (high wear → low efficiency → uncompetitive), or where capacity is being
## expanded (expansion_weeks_left > 0). Pairs with Population (labour) and
## Companies (capital) to complete the production-side picture.
##
## Self-contained like EventLog / CompaniesPanel / PoliticsPanel /
## PopulationPanel: subscribes to EventBus.day_advanced itself and rebuilds.
## Pure view over WorldState.towns → town.industries — reads, never mutates
## — so determinism and money conservation are unaffected.
##
## Sorting: column headers are buttons (same pattern as CompaniesPanel /
## PopulationPanel). Click a header to sort by that column; click again to
## flip asc/desc. Default is profit desc (the profitable lines first — what
## a player scanning for opportunities wants). The chosen sort survives daily
## refreshes — _sort_key/_sort_desc are kept across rebuilds.

const SORT_TOWN := 0
const SORT_RECIPE := 1
const SORT_OWNER := 2
const SORT_WORK := 3
const SORT_CAP := 4
const SORT_WEAR := 5
const SORT_PROFIT := 6

@onready var _title: Label = %Title
@onready var _h_town: Button = %HTown
@onready var _h_recipe: Button = %HRecipe
@onready var _h_owner: Button = %HOwner
@onready var _h_work: Button = %HWork
@onready var _h_cap: Button = %HCap
@onready var _h_wear: Button = %HWear
@onready var _h_profit: Button = %HProfit
@onready var _list: VBoxContainer = %List
@onready var _summary: Label = %Summary

# Column widths in monospace chars. Tuned so the 7 columns fit the 640px right
# pane (font 12, ~7px/char). Town + recipe are the widest; workers, cap and
# wear are 3-7 chars; profit is the trailing right-aligned column.
const COL_TOWN := 12
const COL_RECIPE := 14
const COL_OWNER := 12
const COL_WORK := 12
const COL_CAP := 5
const COL_WEAR := 7
const COL_PROFIT := 8

var _sort_key: int = SORT_PROFIT
var _sort_desc: bool = true

# Recipe names cache (recipe_id -> human name). Loaded once on _ready from
# data/recipes.json so the panel shows "Lumber Camp" not "lumber_camp".
var _recipe_names: Dictionary = {}

func _ready() -> void:
	var f := UITheme.load_font()
	_title.add_theme_font_override("font", f)
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_summary.add_theme_font_override("font", f)
	_summary.add_theme_font_size_override("font_size", 12)
	_summary.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	for b in [_h_town, _h_recipe, _h_owner, _h_work, _h_cap, _h_wear, _h_profit]:
		b.add_theme_font_override("font", f)
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color", Color(0.6, 0.7, 0.75))
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_h_town.custom_minimum_size = Vector2(COL_TOWN * 7, 18)
	_h_recipe.custom_minimum_size = Vector2(COL_RECIPE * 7, 18)
	_h_owner.custom_minimum_size = Vector2(COL_OWNER * 7, 18)
	_h_work.custom_minimum_size = Vector2(COL_WORK * 7, 18)
	_h_cap.custom_minimum_size = Vector2(COL_CAP * 7, 18)
	_h_wear.custom_minimum_size = Vector2(COL_WEAR * 7, 18)
	_h_profit.custom_minimum_size = Vector2(COL_PROFIT * 7, 18)
	_h_town.pressed.connect(_sort_by.bind(SORT_TOWN))
	_h_recipe.pressed.connect(_sort_by.bind(SORT_RECIPE))
	_h_owner.pressed.connect(_sort_by.bind(SORT_OWNER))
	_h_work.pressed.connect(_sort_by.bind(SORT_WORK))
	_h_cap.pressed.connect(_sort_by.bind(SORT_CAP))
	_h_wear.pressed.connect(_sort_by.bind(SORT_WEAR))
	_h_profit.pressed.connect(_sort_by.bind(SORT_PROFIT))
	_update_header_markers()
	_load_recipe_names()
	EventBus.day_advanced.connect(_on_day_advanced)
	refresh()

# Load recipe_id -> human name once. data/recipes.json is a flat dict keyed by
# recipe_id; each value carries a "name" field. Cached in _recipe_names.
func _load_recipe_names() -> void:
	var f := FileAccess.open("res://data/recipes.json", FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		for k in parsed.keys():
			var v = parsed[k]
			if v is Dictionary and v.has("name"):
				_recipe_names[String(k)] = String(v["name"])

# Header click handler. Same column + same direction request flips asc/desc;
# a different column resets to that column's default direction (profit / cap /
# wear default desc — more is more interesting; town / recipe / owner / workers
# default asc — alphabetical / size).
func _sort_by(key: int) -> void:
	if key == _sort_key:
		_sort_desc = not _sort_desc
	else:
		_sort_key = key
		_sort_desc = _default_desc_for(key)
	_update_header_markers()
	refresh()

func _default_desc_for(key: int) -> bool:
	return key in [SORT_PROFIT, SORT_CAP, SORT_WEAR]

func _update_header_markers() -> void:
	var down := " ▼"
	var up := " ▲"
	var markers := {
		SORT_TOWN: ["town", _h_town],
		SORT_RECIPE: ["recipe", _h_recipe],
		SORT_OWNER: ["owner", _h_owner],
		SORT_WORK: ["workers", _h_work],
		SORT_CAP: ["cap", _h_cap],
		SORT_WEAR: ["wear", _h_wear],
		SORT_PROFIT: ["d/day", _h_profit],
	}
	for k in markers.keys():
		var base: String = markers[k][0]
		var btn: Button = markers[k][1]
		if k == _sort_key:
			btn.text = base + (down if _sort_desc else up)
			btn.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
		else:
			btn.text = base
			btn.add_theme_color_override("font_color", Color(0.6, 0.7, 0.75))

func _on_day_advanced(_day: int) -> void:
	refresh()

# Rebuild the list. Flatten all towns' industries into one array, sort by the
# current key/direction, then render one row per industry. Summary line rolls
# the whole world up (count + total workers + total profit + how many are
# mid-expansion).
func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	var rows: Array = []
	for t in WorldState.towns:
		for ind in t.industries:
			rows.append({town = t, ind = ind})
	rows.sort_custom(_cmp)
	var g_workers := 0.0
	var g_profit := 0.0
	var g_expanding := 0
	var g_player := 0
	for r in rows:
		var ind: Industry = r.ind
		g_workers += ind.workers
		g_profit += ind.last_profit
		if ind.expansion_weeks_left > 0:
			g_expanding += 1
		if ind.owner_id == "player":
			g_player += 1
		_row_for(r.town, ind)
	_summary.text = "Industries %d  ·  workers %d  ·  profit/day $%.0f  ·  expanding %d  ·  player-owned %d" \
			% [rows.size(), int(g_workers), g_profit, g_expanding, g_player]

# Sort comparator. sort_custom expects true when `a` should come BEFORE `b`.
# Town / recipe / owner use lexicographic compare; the rest are numeric.
func _cmp(a: Dictionary, b: Dictionary) -> bool:
	var ai: Industry = a.ind
	var bi: Industry = b.ind
	if _sort_key == SORT_TOWN:
		var an: String = a.town.name
		var bn: String = b.town.name
		if an != bn:
			return an < bn if not _sort_desc else an > bn
		return ai.recipe_id < bi.recipe_id
	if _sort_key == SORT_RECIPE:
		if ai.recipe_id != bi.recipe_id:
			return ai.recipe_id < bi.recipe_id if not _sort_desc else ai.recipe_id > bi.recipe_id
		return a.town.name < b.town.name
	if _sort_key == SORT_OWNER:
		var ao: String = _owner_short(ai.owner_id)
		var bo: String = _owner_short(bi.owner_id)
		if ao != bo:
			return ao < bo if not _sort_desc else ao > bo
		return a.town.name < b.town.name
	var av: float = _sort_value(ai)
	var bv: float = _sort_value(bi)
	if av != bv:
		return av > bv if _sort_desc else av < bv
	# tie-break: profit desc keeps a deterministic, money-first order
	if ai.last_profit != bi.last_profit:
		return ai.last_profit > bi.last_profit
	return a.town.name < b.town.name

func _sort_value(ind: Industry) -> float:
	match _sort_key:
		SORT_WORK:
			return ind.workers
		SORT_CAP:
			return float(ind.capacity_level)
		SORT_WEAR:
			return ind.wear
		SORT_PROFIT:
			return ind.last_profit
		_:
			return 0.0

# Short owner marker for the column. "town:tortuga" → "twn", "player" → "YOU",
# "ai:co3" → "AI3", "state:spain" → "stSP", "entrepreneur:..." → "ent". The
# full owner_id is verbose; a 3-4 char marker keeps the column tight and the
# player's own lines are immediately visible (YOU).
func _owner_short(owner_id: String) -> String:
	if owner_id == "" or owner_id.begins_with("town:"):
		return "twn"
	if owner_id == "player":
		return "YOU"
	if owner_id.begins_with("ai:"):
		return "AI" + owner_id.substr(3, 1)
	if owner_id.begins_with("state:"):
		return "st" + owner_id.substr(6, 2).to_upper()
	if owner_id.begins_with("entrepreneur:"):
		return "ent"
	return "?"

# One row per industry. Monospace columns so the numbers line up. Player-owned
# rows are highlighted gold; worn lines (wear >= 0.6) are red; profitable green;
# loss-making red — so the player sees at a glance which lines need attention.
func _row_for(t: Town, ind: Industry) -> Label:
	var recipe_name: String = _recipe_names.get(ind.recipe_id, ind.recipe_id)
	var owner: String = _owner_short(ind.owner_id)
	var work_str := "%d/%d" % [int(ind.workers), int(ind.target_workers)]
	var wear_str := "%d%%" % int(ind.wear * 100.0)
	var profit_str := "%+.0f" % ind.last_profit
	var cap_str := "L%d" % ind.capacity_level
	if ind.expansion_weeks_left > 0:
		cap_str = "%s(%dw)" % [cap_str, ind.expansion_weeks_left]
	var text := _pad(COL_TOWN, t.name) \
			+ _pad(COL_RECIPE, recipe_name) \
			+ _pad(COL_OWNER, owner) \
			+ _pad(COL_WORK, work_str) \
			+ _pad(COL_CAP, cap_str) \
			+ _pad(COL_WEAR, wear_str) \
			+ _padl(COL_PROFIT, profit_str)
	var color: Color
	if ind.owner_id == "player":
		color = Color(1.0, 0.9, 0.2)
	elif ind.wear >= 0.6:
		color = Color(0.95, 0.5, 0.45)
	elif ind.last_profit > 0.0:
		color = Color(0.55, 0.85, 0.55)
	elif ind.last_profit < 0.0:
		color = Color(0.95, 0.6, 0.5)
	else:
		color = Color(0.85, 0.85, 0.85)
	return UITheme.make_label(_list, text, 12, color)

# Left-pad `s` into a field of width `w` (monospace, so column-aligned).
func _pad(w: int, s: String) -> String:
	if s.length() >= w:
		return s + " "
	return s + " ".repeat(w - s.length())

# Right-pad variant for the last column (no trailing space, left-aligned).
func _padl(w: int, s: String) -> String:
	if s.length() >= w:
		return s
	return s + " ".repeat(w - s.length())
