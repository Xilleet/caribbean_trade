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

@onready var _title: Label = %Title
@onready var _header: Label = %Header
@onready var _list: VBoxContainer = %List
@onready var _summary: Label = %Summary

const COL_NAME := 26
const COL_MONEY := 11
const COL_DELTA := 8
const COL_SHIPS := 7
const COL_LOANS := 18

func _ready() -> void:
	var f := UITheme.load_font()
	for l in [_title, _header, _summary]:
		l.add_theme_font_override("font", f)
		l.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_title.add_theme_font_size_override("font_size", 15)
	_header.add_theme_font_size_override("font_size", 12)
	_header.add_theme_color_override("font_color", Color(0.6, 0.7, 0.75))
	_summary.add_theme_font_size_override("font_size", 12)
	_summary.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_header.text = _pad(COL_NAME, "company") + _pad(COL_MONEY, "money") \
			+ _pad(COL_DELTA, "d/day") + _pad(COL_SHIPS, "ships") \
			+ _padl(COL_LOANS, "loans / status")
	EventBus.day_advanced.connect(_on_day_advanced)
	refresh()

# Day tick — companies' money/loans change daily; fleet changes rarely. A daily
# rebuild is cheap (9 rows) and keeps the screen in sync with the wallet.
func _on_day_advanced(_day: int) -> void:
	refresh()

# Rebuild the list. Freeing the old rows and re-adding keeps the row count
# correct if a company ever appears or disappears (today the set is fixed
# from build_world, but this is the same pattern the trade/route panels use).
func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	var companies: Array = WorldState.companies
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
			# player_money is set on the first (player) row; for AI rows after it,
			# this counts who is strictly richer. (Player is always first in the
			# list — build_world appends it before the AI companies.)
			richer_than_player += 1
		var row := _row_for(co)
		_list.add_child(row)
	var player_rank := richer_than_player + 1
	_summary.text = "Total $%d  ·  bankrupt %d/%d  ·  player rank %d/%d" \
			% [int(total_money), bankrupt_count, total, player_rank, total]

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
