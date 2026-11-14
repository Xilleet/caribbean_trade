extends Node

## tests for player agency: bribes and citizenship.
## Run directly (prints PASS/FAIL and quits with an exit code) OR via GUT:
##   godot --headless --path <project> tests/test_diplomacy.tscn
##
## Covers:
##  - bribe raises rep by +5 and deducts money
##  - bribe respects per-state 4-week cooldown (second bribe within 4 weeks refused)
##  - bribe cost scales with negative rep (rep=-50 → cost 1000 vs 500 at rep=0)
##  - citizenship changes flag_state to the new state
##  - citizenship requires rep > +50 (lower rep refused)
##  - citizenship drops other states' rep by 10 each

func _ready() -> void:
	var ok := true
	ok = ok and test_bribe_raises_rep_and_deducts()
	ok = ok and test_bribe_respects_cooldown()
	ok = ok and test_bribe_costs_more_at_low_rep()
	ok = ok and test_citizenship_changes_flag_state()
	ok = ok and test_citizenship_requires_rep_threshold()
	ok = ok and test_citizenship_drops_other_rep()
	print("\n=== %s ===" % ("ALL STAGE-A3.1 TESTS PASSED" if ok else "SOME STAGE-A3.1 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

# Helper: build a Main controller instance with a fresh world, so we can call
# bribe_state/apply_citizenship the same way the UI button does.
func _fresh_main() -> Node:
	WorldState.build_world()
	# SimulationClock.week starts at 0 after build_world (reset() re-aligns it).
	# Give the player company plenty of money for bribe/citizenship tests.
	var company: Company = WorldState.get_company("player")
	company.money = 50000.0
	# Main is autoloaded via project.godot? No — Main is the scene root. We need
	# an instance. main.gd extends Node, so we can instantiate it.
	var main := preload("res://main.gd").new()
	# Main._ready() runs build_world + engine init, but since we already called
	# build_world and the node is not in the tree, _ready won't fire. We need
	# the engine to be set up for some methods, but bribe/citizenship don't use
	# the engine. Set _controller manually if needed — but these methods are on
	# main itself. We just need WorldState populated (done above).
	return main

func test_bribe_raises_rep_and_deducts() -> bool:
	var main := _fresh_main()
	var state_id: String = "spain"
	var st: State = WorldState.get_state(state_id)
	var rep_before: float = WorldState.get_player_rep(state_id)
	var company: Company = WorldState.get_company("player")
	var money_before: float = company.money
	var treasury_before: float = st.treasury
	var total_before: float = WorldState.total_money()
	var accepted: bool = main.bribe_state(state_id)
	var rep_after: float = WorldState.get_player_rep(state_id)
	var money_after: float = company.money
	var treasury_after: float = st.treasury
	# rep=0 → cost = 500. money: -500. treasury: +500. rep: +5.
	var passed: bool = accepted \
		and abs((rep_after - rep_before) - 5.0) < 0.001 \
		and abs((money_before - money_after) - 500.0) < 0.001 \
		and abs((treasury_after - treasury_before) - 500.0) < 0.001 \
		and abs(WorldState.total_money() - total_before) < 0.001
	_report("bribe_raises_rep_and_deducts", passed,
		"accepted=%s rep %.0f->%.0f money %.0f->%.0f treasury %.0f->%.0f drift=%.4f" %
		[accepted, rep_before, rep_after, money_before, money_after, treasury_before, treasury_after,
		 WorldState.total_money() - total_before])
	return passed

func test_bribe_respects_cooldown() -> bool:
	var main := _fresh_main()
	var state_id: String = "spain"
	# First bribe at week 0 — should succeed.
	var first: bool = main.bribe_state(state_id)
	# Second bribe same week — should fail (cooldown).
	var second: bool = main.bribe_state(state_id)
	# Advance simulation 4 weeks via SimulationClock + rebuild main's engine so
	# SimulationClock.week advances. Simpler: directly bump SimulationClock.week.
	# But SimulationClock is an autoload — we can call advance_week 4 times.
	for _i in 4:
		SimulationClock.advance_week()
	# Third bribe at week 4 — should succeed (cooldown expired).
	var third: bool = main.bribe_state(state_id)
	var passed: bool = first and not second and third
	_report("bribe_respects_cooldown", passed,
		"first=%s second(same week, expect false)=%s third(after 4 weeks, expect true)=%s" %
		[first, second, third])
	return passed

func test_bribe_costs_more_at_low_rep() -> bool:
	var main := _fresh_main()
	# Set spain rep to -50 — cost should be 1000 (vs 500 at rep=0).
	WorldState.player_rep["spain"] = -50.0
	var st: State = WorldState.get_state("spain")
	var company: Company = WorldState.get_company("player")
	var money_before: float = company.money
	var accepted: bool = main.bribe_state("spain")
	var cost: float = money_before - company.money
	# rep=-50 → cost = 500 × (1 + 50/50) = 500 × 2 = 1000.
	var passed: bool = accepted and abs(cost - 1000.0) < 0.001
	_report("bribe_costs_more_at_low_rep", passed,
		"rep=-50 cost=%.0f (expect 1000)" % cost)
	return passed

func test_citizenship_changes_flag_state() -> bool:
	var main := _fresh_main()
	# Set england rep to +60 (> threshold +50).
	WorldState.player_rep["england"] = 60.0
	var ship: Ship = WorldState.get_player_ship()
	var flag_before: String = ship.flag_state   # "england" already (default)
	# Apply for netherlands citizenship — rep must be > 50, set it.
	WorldState.player_rep["netherlands"] = 60.0
	var accepted: bool = main.apply_citizenship("netherlands")
	var flag_after: String = ship.flag_state
	var passed: bool = accepted and flag_after == "netherlands" and flag_before == "england"
	_report("citizenship_changes_flag_state", passed,
		"accepted=%s flag '%s'->'%s" % [accepted, flag_before, flag_after])
	return passed

func test_citizenship_requires_rep_threshold() -> bool:
	var main := _fresh_main()
	# spain rep = 0 — below threshold +50.
	WorldState.player_rep["spain"] = 0.0
	var company: Company = WorldState.get_company("player")
	var money_before: float = company.money
	var accepted: bool = main.apply_citizenship("spain")
	var money_after: float = company.money
	# Should be refused — no money spent, no flag change.
	var passed: bool = not accepted and abs(money_after - money_before) < 0.001
	_report("citizenship_requires_rep_threshold", passed,
		"rep=0 accepted=%s (expect false), money %.0f->%.0f (expect unchanged)" %
		[accepted, money_before, money_after])
	return passed

func test_citizenship_drops_other_rep() -> bool:
	var main := _fresh_main()
	# Set netherlands rep to +60 (> threshold). Other 3 states start at 0.
	WorldState.player_rep["netherlands"] = 60.0
	var rep_sp_before: float = WorldState.get_player_rep("spain")
	var rep_en_before: float = WorldState.get_player_rep("england")
	var rep_fr_before: float = WorldState.get_player_rep("france")
	var accepted: bool = main.apply_citizenship("netherlands")
	var rep_sp_after: float = WorldState.get_player_rep("spain")
	var rep_en_after: float = WorldState.get_player_rep("england")
	var rep_fr_after: float = WorldState.get_player_rep("france")
	# All OTHER states (not netherlands) rep -= 10. Netherlands unchanged.
	var passed: bool = accepted \
		and abs((rep_sp_before - rep_sp_after) - 10.0) < 0.001 \
		and abs((rep_en_before - rep_en_after) - 10.0) < 0.001 \
		and abs((rep_fr_before - rep_fr_after) - 10.0) < 0.001
	_report("citizenship_drops_other_rep", passed,
		"accepted=%s spain %.0f->%.0f england %.0f->%.0f france %.0f->%.0f (expect -10 each)" %
		[accepted, rep_sp_before, rep_sp_after, rep_en_before, rep_en_after, rep_fr_before, rep_fr_after])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
