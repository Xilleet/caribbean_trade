extends VBoxContainer

## Stage UI-5 PopulationPanel — the "— Population —" aggregate screen.
##
## Lists every town (15) as one row each: total population, the three strata
## (poor / middle / rich), the population-weighted average SoL and satisfaction,
## the employed share of the labour force, and the migration queue depth.
## This is the society view the old UI never exposed — without it the player
## can't see where people are unhappy (low SoL → emigration), where labour is
## tight (low employ% → high wages → uncompetitive), or where a town is growing
## (waiting migrants). Pairs with the Companies panel (the economy) to show
## the two sides of the Victoria-3-style world: who trades and who lives.
##
## Self-contained like EventLog / CompaniesPanel / PoliticsPanel: subscribes to
## EventBus.day_advanced itself and rebuilds. Pure view over WorldState.towns
## + each town's pops — reads, never mutates — so determinism and money
## conservation are unaffected.
##
## Sorting: column headers are buttons (same pattern as CompaniesPanel). Click
## a header to sort by that column; click again to flip asc/desc. Default is
## total population desc (biggest cities first). The chosen sort survives daily
## refreshes — _sort_key/_sort_desc are kept across rebuilds.

const SORT_TOWN := 0
const SORT_TOTAL := 1
const SORT_POOR := 2
const SORT_MID := 3
const SORT_RICH := 4
const SORT_SOL := 5
const SORT_SAT := 6
const SORT_EMP := 7
const SORT_MIGR := 8

@onready var _title: Label = %Title
@onready var _h_town: Button = %HTown
@onready var _h_total: Button = %HTotal
@onready var _h_poor: Button = %HPoor
@onready var _h_mid: Button = %HMid
@onready var _h_rich: Button = %HRich
@onready var _h_sol: Button = %HSoL
@onready var _h_sat: Button = %HSat
@onready var _h_emp: Button = %HEmp
@onready var _h_migr: Button = %HMigr
@onready var _list: VBoxContainer = %List
@onready var _summary: Label = %Summary

# Column widths in monospace chars. Tuned so the 9 columns fit the 640px right
# pane (font 12, ~7px/char). Town is the widest; the rest are 3-7 chars wide.
const COL_TOWN := 14
const COL_TOTAL := 7
const COL_POOR := 7
const COL_MID := 7
const COL_RICH := 6
const COL_SOL := 6
const COL_SAT := 6
const COL_EMP := 8
const COL_MIGR := 6

var _sort_key: int = SORT_TOTAL
var _sort_desc: bool = true

func _ready() -> void:
	var f := UITheme.load_font()
	_title.add_theme_font_override("font", f)
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_summary.add_theme_font_override("font", f)
	_summary.add_theme_font_size_override("font_size", 12)
	_summary.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	for b in [_h_town, _h_total, _h_poor, _h_mid, _h_rich, _h_sol, _h_sat, _h_emp, _h_migr]:
		b.add_theme_font_override("font", f)
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color", Color(0.6, 0.7, 0.75))
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_h_town.custom_minimum_size = Vector2(COL_TOWN * 7, 18)
	_h_total.custom_minimum_size = Vector2(COL_TOTAL * 7, 18)
	_h_poor.custom_minimum_size = Vector2(COL_POOR * 7, 18)
	_h_mid.custom_minimum_size = Vector2(COL_MID * 7, 18)
	_h_rich.custom_minimum_size = Vector2(COL_RICH * 7, 18)
	_h_sol.custom_minimum_size = Vector2(COL_SOL * 7, 18)
	_h_sat.custom_minimum_size = Vector2(COL_SAT * 7, 18)
	_h_emp.custom_minimum_size = Vector2(COL_EMP * 7, 18)
	_h_migr.custom_minimum_size = Vector2(COL_MIGR * 7, 18)
	_h_town.pressed.connect(_sort_by.bind(SORT_TOWN))
	_h_total.pressed.connect(_sort_by.bind(SORT_TOTAL))
	_h_poor.pressed.connect(_sort_by.bind(SORT_POOR))
	_h_mid.pressed.connect(_sort_by.bind(SORT_MID))
	_h_rich.pressed.connect(_sort_by.bind(SORT_RICH))
	_h_sol.pressed.connect(_sort_by.bind(SORT_SOL))
	_h_sat.pressed.connect(_sort_by.bind(SORT_SAT))
	_h_emp.pressed.connect(_sort_by.bind(SORT_EMP))
	_h_migr.pressed.connect(_sort_by.bind(SORT_MIGR))
	_update_header_markers()
	EventBus.day_advanced.connect(_on_day_advanced)
	refresh()

# Header click handler. Same column + same direction request flips asc/desc;
# a different column resets to that column's default direction (total/poor/
# mid/rich/sol/sat/emp/migr default desc — more is more interesting; town
# defaults asc — alphabetical).
func _sort_by(key: int) -> void:
	if key == _sort_key:
		_sort_desc = not _sort_desc
	else:
		_sort_key = key
		_sort_desc = _default_desc_for(key)
	_update_header_markers()
	refresh()

func _default_desc_for(key: int) -> bool:
	return key != SORT_TOWN

# Put a ▼ (desc) / ▲ (asc) marker on the active header and strip it from the
# rest, so the current sort is visible at a glance.
func _update_header_markers() -> void:
	var down := " ▼"
	var up := " ▲"
	var markers := {
		SORT_TOWN: ["town", _h_town],
		SORT_TOTAL: ["total", _h_total],
		SORT_POOR: ["poor", _h_poor],
		SORT_MID: ["mid", _h_mid],
		SORT_RICH: ["rich", _h_rich],
		SORT_SOL: ["SoL", _h_sol],
		SORT_SAT: ["sat", _h_sat],
		SORT_EMP: ["employ%", _h_emp],
		SORT_MIGR: ["migr", _h_migr],
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

# Rebuild the list. Sort by the current key/direction, then render one row per
# town. Summary line rolls the whole world up (total population + weighted SoL
# + satisfaction + employed share + total waiting migrants).
func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	var towns: Array = WorldState.towns.duplicate()
	towns.sort_custom(_cmp)
	var g_total := 0.0
	var g_sol_w := 0.0   # weighted SoL accumulator
	var g_sat_w := 0.0   # weighted satisfaction accumulator
	var g_employed := 0.0
	var g_labour := 0.0
	var g_migr := 0
	for t in towns:
		var total_pop: float = t.total_population()
		g_total += total_pop
		# Population-weighted SoL/satisfaction: sum (pop.living_standard × count)
		# over the town's pops, divided by the town total. town.satisfaction is
		# already the weighted satisfaction; we mirror the same weighting for
		# SoL since there is no town-level SoL getter.
		if total_pop > 0.0:
			var sol_w := 0.0
			for p in t.pops:
				sol_w += p.living_standard * p.count
			g_sol_w += sol_w
			g_sat_w += t.satisfaction * total_pop
		var emp := _employed_share(t)
		g_employed += emp.numerator
		g_labour += emp.denominator
		g_migr += t.waiting_passengers.size()
		_row_for(t)
	_summary.text = "World pop %d  ·  SoL avg %.2f  ·  sat avg %.2f  ·  employed %.0f%%  ·  migrants %d" \
			% [int(g_total), g_sol_w / g_total if g_total > 0.0 else 0.0,
			   g_sat_w / g_total if g_total > 0.0 else 0.0,
			   (g_employed / g_labour * 100.0) if g_labour > 0.0 else 0.0,
			   g_migr]

# Sort comparator. sort_custom expects true when `a` should come BEFORE `b`:
# for desc we want larger first (a before b iff a > b), for asc smaller first.
# Town name uses lexicographic compare directly; the rest are numeric.
func _cmp(a: Town, b: Town) -> bool:
	if _sort_key == SORT_TOWN:
		if a.name != b.name:
			return a.name < b.name if not _sort_desc else a.name > b.name
		return a.total_population() > b.total_population()
	var av: float = _sort_value(a)
	var bv: float = _sort_value(b)
	if av != bv:
		return av > bv if _sort_desc else av < bv
	# tie-break: total population desc keeps a deterministic, city-size order
	return a.total_population() > b.total_population()

# Numeric value used for sorting a town under the current key.
func _sort_value(t: Town) -> float:
	match _sort_key:
		SORT_TOTAL:
			return t.total_population()
		SORT_POOR:
			return t.poor
		SORT_MID:
			return t.middle
		SORT_RICH:
			return t.rich
		SORT_SOL:
			return _weighted_sol(t)
		SORT_SAT:
			return t.satisfaction
		SORT_EMP:
			var emp := _employed_share(t)
			return emp.numerator / emp.denominator if emp.denominator > 0.0 else 0.0
		SORT_MIGR:
			return float(t.waiting_passengers.size())
		_:
			return 0.0

# Population-weighted average living_standard for a town (0..1). Town has no
# SoL getter (satisfaction covers it for the existing UI), so we compute it
# here from the per-Pop living_standard. Identical weighting to the global
# roll-up in refresh().
func _weighted_sol(t: Town) -> float:
	var total: float = t.total_population()
	if total <= 0.0:
		return 0.0
	var s: float = 0.0
	for p in t.pops:
		s += p.living_standard * p.count
	return s / total

# Employed share of the labour force. Labour force = (poor + middle) × 0.5
# (Town.labor_force, the share that can work). Employed = Σ Pop.employed_count
# (set by PopulationSystem Phase 4 each week). Returns the raw numerator and
# denominator so the global roll-up can sum them before dividing (a weighted
# average of percentages is wrong; we need total employed / total labour).
class _Share:
	var numerator: float
	var denominator: float
	func _init(n: float, d: float) -> void:
		numerator = n
		denominator = d

func _employed_share(t: Town) -> _Share:
	var labour: float = t.labor_force()
	var employed: float = 0.0
	for p in t.pops:
		employed += p.employed_count
	return _Share.new(employed, labour)

# One row per town. Monospace columns so the numbers line up. SoL/sat are shown
# to 2 decimals; employed% as an integer; strata and totals as integers (the
# underlying counts are floats for fractional growth, but a person is a person
# — showing 2400 not 2400.3 reads better). The player's home town is
# highlighted gold; other towns neutral.
func _row_for(t: Town) -> Label:
	var emp := _employed_share(t)
	var emp_pct := (emp.numerator / emp.denominator * 100.0) if emp.denominator > 0.0 else 0.0
	var sol := _weighted_sol(t)
	var sat := t.satisfaction
	var text := _pad(COL_TOWN, t.name) \
			+ _pad(COL_TOTAL, "%d" % int(round(t.total_population()))) \
			+ _pad(COL_POOR, "%d" % int(round(t.poor))) \
			+ _pad(COL_MID, "%d" % int(round(t.middle))) \
			+ _pad(COL_RICH, "%d" % int(round(t.rich))) \
			+ _pad(COL_SOL, "%.2f" % sol) \
			+ _pad(COL_SAT, "%.2f" % sat) \
			+ _pad(COL_EMP, "%.0f%%" % emp_pct) \
			+ _padl(COL_MIGR, "%d" % t.waiting_passengers.size())
	# Colour by SoL: green >= 0.7, yellow >= 0.4, red below — so unhappy towns
	# (emigration sources) stand out at a glance, prosperous ones read calm.
	var color: Color
	if sol >= 0.7:
		color = Color(0.55, 0.85, 0.55)
	elif sol >= 0.4:
		color = Color(0.9, 0.85, 0.5)
	else:
		color = Color(0.95, 0.55, 0.45)
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
