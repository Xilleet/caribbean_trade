extends VBoxContainer

## Stage UI-4 CompaniesPanel — the "— Companies —" aggregate screen.
##
## Lists every company in the world (the player + the 8 AI) as one row each:
## money, today's wallet delta, fleet size, outstanding loans, bankrupt flag.
## This is the first screen that shows the competition — who is richer, who is
## in debt, who has gone bust — which the old UI never exposed.
##
## Self-contained like EventLog: it subscribes to EventBus.day_advanced itself
## and rebuilds the row list, so game_ui does not need to wire or refresh it.
## Pure view over WorldState.companies — reads, never mutates — so determinism
## and money conservation are unaffected. No history is kept here; the panel
## always shows the current snapshot (money/loans change daily, fleet rarely).
##
## Sorting: the column headers are buttons. Clicking a header sorts by that
## column; clicking the same header again flips asc/desc. Default is money
## desc (richest first), so the player sees the leaderboard immediately. The
## chosen sort survives daily refreshes — _sort_key/_sort_desc are kept across
## rebuilds. Bankrupt companies sort to the bottom under any key (a bust shop
## is never the "leader" of anything), which keeps the active companies in view.

const SORT_NAME := 0
const SORT_MONEY := 1
const SORT_DELTA := 2
const SORT_SHIPS := 3
const SORT_LOANS := 4

@onready var _title: Label = %Title
@onready var _h_name: Button = %HName
@onready var _h_money: Button = %HMoney
@onready var _h_delta: Button = %HDelta
@onready var _h_ships: Button = %HShips
@onready var _h_loans: Button = %HLoans
@onready var _list: VBoxContainer = %List
@onready var _summary: Label = %Summary

const COL_NAME := 26
const COL_MONEY := 11
const COL_DELTA := 8
const COL_SHIPS := 7
const COL_LOANS := 18

var _sort_key: int = SORT_MONEY
var _sort_desc: bool = true

func _ready() -> void:
	var f := UITheme.load_font()
	_title.add_theme_font_override("font", f)
	_title.add_theme_font_size_override("font_size", 15)
	_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_summary.add_theme_font_override("font", f)
	_summary.add_theme_font_size_override("font_size", 12)
	_summary.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	# Header buttons: monospace, small, fixed-width so they line up with the
	# rows below. Each shows the column title + a direction marker (▼/▲) for
	# the active sort, set by _update_header_markers().
	for b in [_h_name, _h_money, _h_delta, _h_ships, _h_loans]:
		b.add_theme_font_override("font", f)
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color", Color(0.6, 0.7, 0.75))
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_h_name.custom_minimum_size = Vector2(COL_NAME * 7, 18)
	_h_money.custom_minimum_size = Vector2(COL_MONEY * 7, 18)
	_h_delta.custom_minimum_size = Vector2(COL_DELTA * 7, 18)
	_h_ships.custom_minimum_size = Vector2(COL_SHIPS * 7, 18)
	_h_loans.custom_minimum_size = Vector2(COL_LOANS * 7, 18)
	_h_name.pressed.connect(_sort_by.bind(SORT_NAME))
	_h_money.pressed.connect(_sort_by.bind(SORT_MONEY))
	_h_delta.pressed.connect(_sort_by.bind(SORT_DELTA))
	_h_ships.pressed.connect(_sort_by.bind(SORT_SHIPS))
	_h_loans.pressed.connect(_sort_by.bind(SORT_LOANS))
	_update_header_markers()
	EventBus.day_advanced.connect(_on_day_advanced)
	refresh()

# Header click handler. Same column + same direction request flips asc/desc;
# a different column keeps the current direction (money defaults to desc,
# name to asc — see _default_desc_for). Marks the new active header and
# rebuilds.
func _sort_by(key: int) -> void:
	if key == _sort_key:
		_sort_desc = not _sort_desc
	else:
		_sort_key = key
		_sort_desc = _default_desc_for(key)
	_update_header_markers()
	refresh()

# money/ships/loans are "more is better" — default desc. name/delta default asc
# (alphabetical / chronological). Matches what a glance at a leaderboard reads.
func _default_desc_for(key: int) -> bool:
	return key in [SORT_MONEY, SORT_SHIPS, SORT_LOANS]

# Put a ▼ (desc) / ▲ (asc) marker on the active header and strip it from the
# rest, so the current sort is visible at a glance.
func _update_header_markers() -> void:
	var down := " ▼"
	var up := " ▲"
	var markers := {
		SORT_NAME: ["company", _h_name],
		SORT_MONEY: ["money", _h_money],
		SORT_DELTA: ["d/day", _h_delta],
		SORT_SHIPS: ["ships", _h_ships],
		SORT_LOANS: ["loans / status", _h_loans],
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

# Day tick — companies' money/loans change daily; fleet changes rarely. A daily
# rebuild is cheap (9 rows) and keeps the screen in sync with the wallet.
func _on_day_advanced(_day: int) -> void:
	refresh()

# Rebuild the list. Sort by the current key/direction, with bankrupt companies
# pushed to the bottom (they never lead the leaderboard under any sort).
func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	var companies: Array = WorldState.companies.duplicate()
	companies.sort_custom(_cmp)
	var total_money := 0.0
	var bankrupt_count := 0
	var player_money := 0.0
	var richer_than_player := 0
	var total := companies.size()
	for co in companies:
		if co.bankrupt:
			bankrupt_count += 1
		total_money += co.money
		if not co.is_ai:
			player_money = co.money
		elif co.money > player_money:
			# player_money is set when the player row is reached; this counts AI
			# companies strictly richer than the player regardless of sort order.
			richer_than_player += 1
		# make_label already add_child's to _list; no second add_child here.
		_row_for(co)
	var player_rank := richer_than_player + 1
	_summary.text = "Total $%d  ·  bankrupt %d/%d  ·  player rank %d/%d" \
			% [int(total_money), bankrupt_count, total, player_rank, total]

# Sort comparator. Bankrupt sorts last under every key; within the same key,
# ties fall back to money desc so the order is stable and meaningful.
# sort_custom expects true when `a` should come BEFORE `b`: for desc we want
# larger first (a before b iff a > b), for asc we want smaller first.
func _cmp(a: Company, b: Company) -> bool:
	if a.bankrupt != b.bankrupt:
		return not a.bankrupt
	var av: float = _sort_value(a)
	var bv: float = _sort_value(b)
	if _sort_key == SORT_NAME:
		# lexicographic; asc = A..Z, desc = Z..A
		if a.name != b.name:
			return a.name < b.name if not _sort_desc else a.name > b.name
	else:
		if av != bv:
			return av > bv if _sort_desc else av < bv
	# tie-break: money desc keeps a deterministic, leaderboard-like order
	if a.money != b.money:
		return a.money > b.money
	return a.name < b.name

# Numeric value used for sorting a company under the current key. Name uses
# lexicographic compare directly in _cmp (returns 0/0 here so the tie-break
# path handles it) — keeping this float-only avoids string/float branching.
func _sort_value(co: Company) -> float:
	match _sort_key:
		SORT_MONEY:
			return co.money
		SORT_DELTA:
			return co.money - co.last_day_money if co.last_day_money != 0.0 else 0.0
		SORT_SHIPS:
			return float(co.ship_ids.size())
		SORT_LOANS:
			var total := 0.0
			for k in co.loans.keys():
				total += float(co.loans[k])
			return total
		_:
			return 0.0

# One row per company. Monospace columns so the numbers line up. The player's
# row is highlighted gold; bankrupt rows are dimmed red; AI rows neutral.
func _row_for(co: Company) -> Label:
	var loans_str := _loans_str(co)
	var status := "BANKRUPT" if co.bankrupt else loans_str
	var kind := "YOU" if not co.is_ai else "AI"
	var text := _pad(COL_NAME, co.name) \
			+ _pad(COL_MONEY, "$%d" % int(co.money)) \
			+ _pad(COL_DELTA, _delta_str(co)) \
			+ _pad(COL_SHIPS, "%d" % co.ship_ids.size()) \
			+ _padl(COL_LOANS, "%s %s" % [kind, status])
	var color: Color
	if co.bankrupt:
		color = Color(0.7, 0.4, 0.4)
	elif not co.is_ai:
		color = Color(1.0, 0.9, 0.2)
	else:
		color = Color(0.85, 0.85, 0.85)
	return UITheme.make_label(_list, text, 12, color)

# Loans summary "NL:500 ES:200" or "—" if none. Capped at the first 2 lenders
# to keep the column narrow; "+N" marks any further.
func _loans_str(co: Company) -> String:
	var keys: Array = co.loans.keys()
	if keys.is_empty():
		return "—"
	var parts: Array[String] = []
	var shown := 0
	for k in keys:
		if shown >= 2:
			parts.append("+%d" % (keys.size() - shown))
			break
		var sid := String(k)
		var short := sid.substr(0, 2).to_upper()
		parts.append("%s:%d" % [short, int(co.loans[k])])
		shown += 1
	return " ".join(PackedStringArray(parts))

# Today's wallet delta. On day 0, last_day_money is still 0 (the snapshot is
# taken in step_day, which hasn't run yet at the first refresh) — show "—" so
# the starting wallet doesn't read as a +$5000 gain.
func _delta_str(co: Company) -> String:
	if co.last_day_money == 0.0:
		return "—"
	var d := co.money - co.last_day_money
	if d >= 0.0:
		return "+%d" % int(d)
	return "%d" % int(d)

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
