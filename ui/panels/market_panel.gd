extends VBoxContainer

## Stage UI-6 MarketPanel — the "— Market —" aggregate screen.
##
## A 16-goods × 15-towns price matrix. Each cell shows a good's current_price
## in a town, colour-coded by deviation from that good's base_price:
##   green  — expensive (> +10% over base → a place to SELL into)
##   red    — cheap    (< -10% under base → a place to BUY from)
##   grey   — near base (±10%)
## This is the trade-opportunity view the old UI never exposed as a whole:
## the player sees at a glance where each good is dear or cheap across the
## whole Caribbean, which is exactly what makes a trade route profitable.
## Town-level stock/demand/supply stay on the Town page (per-port); this
## screen is the cross-port price comparison.
##
## Self-contained like the other aggregate panels: subscribes to
## EventBus.day_advanced itself and rebuilds. Pure view over WorldState.towns →
## town.market.entries — reads, never mutates — so determinism and money
## conservation are unaffected.
##
## Sorting: the three sort buttons reorder the ROWS (goods). Default is by
## name; "base price" puts expensive goods at the top; "avg dev %" puts the
## goods with the widest cross-port price spread at the top (the most
## arbitrageable). The town columns are always in WorldState.towns order
## (deterministic; the town list never changes during a game).

const SORT_NAME := 0
const SORT_BASE := 1
const SORT_DEV := 2

@onready var _title: Label = %Title
@onready var _sort_name: Button = %SortName
@onready var _sort_base: Button = %SortBase
@onready var _sort_dev: Button = %SortDev
@onready var _header: Label = %Header
@onready var _list: VBoxContainer = %List
@onready var _summary: Label = %Summary

# Column widths in monospace chars. The good label is COL_GOOD; each town
# column is COL_TOWN. With 15 towns: COL_GOOD(10) + 15×COL_TOWN(5) = 85 chars
# ≈ 595px at font 12 (~7px/char) — fits the 640px right pane.
const COL_GOOD := 10
const COL_TOWN := 5

var _sort_key: int = SORT_NAME
var _sort_desc: bool = false   # name default asc (A..Z); base/dev default desc

# good_id -> {name, base_price} cache from data/goods.json. Loaded once.
var _goods_meta: Dictionary = {}
# Deterministic good order (the keys of _goods_meta as loaded) so the matrix
# is stable across refreshes regardless of dict iteration order.
var _good_ids: Array[String] = []
# Town short labels (first 4 chars, uppercased) so the 15-column header fits.
# Cached once per refresh — town list is stable during a game.
var _town_short: Array[String] = []

func _ready() -> void:
	var f := UITheme.load_font()
	_title.add_theme_font_override("font", f)
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_header.add_theme_font_override("font", f)
	_header.add_theme_font_size_override("font_size", 12)
	_header.add_theme_color_override("font_color", Color(0.6, 0.7, 0.75))
	_summary.add_theme_font_override("font", f)
	_summary.add_theme_font_size_override("font_size", 12)
	_summary.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	for b in [_sort_name, _sort_base, _sort_dev]:
		b.add_theme_font_override("font", f)
		b.add_theme_font_size_override("font_size", 11)
		b.add_theme_color_override("font_color", Color(0.6, 0.7, 0.75))
		b.flat = true
	_sort_name.pressed.connect(_sort_by.bind(SORT_NAME))
	_sort_base.pressed.connect(_sort_by.bind(SORT_BASE))
	_sort_dev.pressed.connect(_sort_by.bind(SORT_DEV))
	_load_goods_meta()
	_update_sort_markers()
	EventBus.day_advanced.connect(_on_day_advanced)
	refresh()

# Load goods.json once: {good_id -> {name, base_price}}. The file is flat;
# each value carries "name" and "base_price". Caches the key order too so the
# matrix rows are deterministic across refreshes.
func _load_goods_meta() -> void:
	var f := FileAccess.open("res://data/goods.json", FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	for k in parsed.keys():
		var v = parsed[k]
		if v is Dictionary and v.has("name") and v.has("base_price"):
			var gid := String(k)
			_goods_meta[gid] = {
				name = String(v.name),
				base = float(v.base_price),
			}
			_good_ids.append(gid)

# Sort button handler. Same key + same direction flips asc/desc; a different
# key resets to that key's default (name asc, base/dev desc).
func _sort_by(key: int) -> void:
	if key == _sort_key:
		_sort_desc = not _sort_desc
	else:
		_sort_key = key
		_sort_desc = _default_desc_for(key)
	_update_sort_markers()
	refresh()

func _default_desc_for(key: int) -> bool:
	return key != SORT_NAME

func _update_sort_markers() -> void:
	var down := " ▼"
	var up := " ▲"
	var markers := {
		SORT_NAME: ["name", _sort_name],
		SORT_BASE: ["base price", _sort_base],
		SORT_DEV: ["avg dev %", _sort_dev],
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

# Rebuild the matrix. The header is a one-line label (good label + 15 short
# town names). Each row is a label (good name + 15 prices). Summary rolls up
# the world: avg deviation, count of goods in shortage somewhere (stock <
# target_stock at any port).
func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	_build_town_short()
	_render_header()
	# Sort good_ids by the current key/direction (operate on a copy — the
	# cached _good_ids order is the name-asc default and must stay stable).
	var gids: Array[String] = _good_ids.duplicate()
	gids.sort_custom(_cmp_good)
	var g_dev_sum := 0.0
	var g_dev_count := 0
	var g_shortage := 0
	for gid in gids:
		var row_dev := _render_row(gid)
		g_dev_sum += row_dev
		g_dev_count += 1
		# Shortage count: any town where this good's stock < target_stock.
		for t in WorldState.towns:
			if t.market.has_good(gid):
				var e = t.market.get_entry(gid)
				if e.stock < e.target_stock * 0.5:
					g_shortage += 1
					break
	var avg_dev := (g_dev_sum / g_dev_count) if g_dev_count > 0 else 0.0
	_summary.text = "Goods %d  ·  towns %d  ·  avg deviation %+.1f%%  ·  goods in shortage somewhere %d" \
			% [gids.size(), WorldState.towns.size(), avg_dev, g_shortage]

# Header: good label + 15 short town names, right-padded to COL_TOWN. The town
# short label is the first 4 chars of the name uppercased (HAV, SDM, PRT...) —
# not unique in theory but the full row context disambiguates. The legend in
# the title line ("price / % from base") explains the colouring.
func _render_header() -> void:
	var s := _pad(COL_GOOD, "good")
	for ts in _town_short:
		s += _pad(COL_TOWN, ts)
	_header.text = s

# One row per good: good name + 15 prices. Returns the row's average deviation
# from base (so the caller can roll up a world average). Price shown as int;
# colour by deviation: green > +10%, red < -10%, grey otherwise. A good with
# no entry in a town (shouldn't happen — build_world adds all 16 to all towns)
# renders as "—" in dim grey.
func _render_row(gid: String) -> float:
	var meta: Dictionary = _goods_meta.get(gid, {name = gid, base = 1.0})
	var name_str: String = meta.get("name", gid)
	var base: float = float(meta.get("base", 1.0))
	var s := _pad(COL_GOOD, name_str)
	var dev_sum := 0.0
	var dev_count := 0
	# Build the row as a single label (monospace) so the cells align with the
	# header. Colour applies to the whole label — a row is one good, so a
	# single row colour (the row's own avg deviation) is more readable than
	# 16 separate coloured cells in one line. We compute that avg here.
	for t in WorldState.towns:
		if t.market.has_good(gid):
			var e = t.market.get_entry(gid)
			s += _pad(COL_TOWN, "%d" % int(e.current_price))
			dev_sum += (e.current_price - base) / base
			dev_count += 1
		else:
			s += _pad(COL_TOWN, "—")
	var row_dev: float = (dev_sum / dev_count * 100.0) if dev_count > 0 else 0.0
	# Row colour by the row's avg deviation: green if the good is generally
	# dear, red if generally cheap, grey if near base. Within a row the
	# per-town deviations still differ, but the row tint is the headline.
	var color: Color
	if row_dev > 10.0:
		color = Color(0.55, 0.85, 0.55)
	elif row_dev < -10.0:
		color = Color(0.95, 0.55, 0.45)
	else:
		color = Color(0.8, 0.8, 0.8)
	UITheme.make_label(_list, s, 12, color)
	return row_dev

# Sort comparator for goods. name lexicographic; base/dev numeric. dev is
# computed per good over all towns (the avg we render).
func _cmp_good(a: String, b: String) -> bool:
	if _sort_key == SORT_NAME:
		var na: String = _goods_meta.get(a, {}).get("name", a)
		var nb: String = _goods_meta.get(b, {}).get("name", b)
		if na != nb:
			return na < nb if not _sort_desc else na > nb
		return a < b
	if _sort_key == SORT_BASE:
		var ba: float = float(_goods_meta.get(a, {}).get("base", 0.0))
		var bb: float = float(_goods_meta.get(b, {}).get("base", 0.0))
		if ba != bb:
			return ba > bb if _sort_desc else ba < bb
		return a < b
	# SORT_DEV
	var da: float = _avg_dev(a)
	var db: float = _avg_dev(b)
	if da != db:
		return da > db if _sort_desc else da < db
	return a < b

# Average per-good deviation across all towns (percent). Used for sorting
# and as a tie-breaker reference. -100..+large; matches the row tint threshold.
func _avg_dev(gid: String) -> float:
	var meta: Dictionary = _goods_meta.get(gid, {base = 1.0})
	var base: float = float(meta.get("base", 1.0))
	var sum := 0.0
	var n := 0
	for t in WorldState.towns:
		if t.market.has_good(gid):
			var e = t.market.get_entry(gid)
			sum += (e.current_price - base) / base
			n += 1
	return (sum / n * 100.0) if n > 0 else 0.0

# Cache the 15 towns' short labels (first 4 chars uppercased) on each refresh
# — cheap, and keeps the matrix deterministic if town names ever changed.
func _build_town_short() -> void:
	_town_short.clear()
	for t in WorldState.towns:
		var n: String = t.name
		_town_short.append(n.substr(0, 4).to_upper())

# Left-pad `s` into a field of width `w` (monospace, so column-aligned).
func _pad(w: int, s: String) -> String:
	if s.length() >= w:
		return s + " "
	return s + " ".repeat(w - s.length())
