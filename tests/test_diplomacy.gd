extends Node

##  tests for the diplomacy system (bribes + citizenship). Run:
##   godot --headless --path <project> tests/test_diplomacy.tscn
##
## Covers:
##  - bribe conserves money (company -> state.treasury), raises rep, sets cooldown
##  - bribe on cooldown is a no-op (money/rep/treasury unchanged)
##  - bribe with insufficient funds is a no-op
##  - citizenship changes flag_state and conserves money (fee -> state.treasury)
##  - citizenship blocked when rep <= 50 (flag/money unchanged)
##
## The bribe/citizenship logic lives on Main (main.gd) as controller methods.
## We instantiate Main without adding it to the scene tree (so _ready never
## runs) and call the methods via .call(); they touch only autoloads (WorldState
## / EventBus / SimulationClock) and the player company/ship, so no engine/UI
## wiring is needed.

func _ready() -> void:
	var ok := true
	ok = ok and test_bribe_conserves_and_raises_rep()
	ok = ok and test_bribe_cooldown_blocks()
	ok = ok and test_bribe_blocked_no_funds()
	ok = ok and test_citizenship_changes_flag_and_conserves()
	ok = ok and test_citizenship_blocked_low_rep()
	print("\n=== %s ===" % ("ALL STAGE-A3.1 TESTS PASSED" if ok else "SOME STAGE-A3.1 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

# A bare Main node (not in the tree). Its diplomacy methods only use autoloads,
# so this is enough — no _ready, no engine, no UI.
func _main() -> Node:
	return load("res://main.gd").new()

func test_bribe_conserves_and_raises_rep() -> bool:
	WorldState.build_world()
	var main: Node = _main()
	var state_id := "france"
	var st: State = WorldState.get_state(state_id)
	var company: Company = WorldState.get_company("player")
	company.money = 5000.0
	WorldState.player_rep[state_id] = 0.0   # deterministic baseline: rep 0 -> cost 500
	var rep_before := WorldState.get_player_rep(state_id)
	var cost: float = 500.0 * (1.0 + max(0.0, -rep_before / 50.0))
	var treasury_before := st.treasury
	var total_before := WorldState.total_money()
	main.call("bribe_state", state_id)
	var drift := WorldState.total_money() - total_before
	var rep_after := WorldState.get_player_rep(state_id)
	var cd_week := int(company.bribe_cooldowns.get(state_id, -999))
	# Money flows company -> state.treasury (both in total_money -> drift 0),
	# rep rises by BRIBE_REP_GAIN (20), cooldown stamped to this week.
	var passed: bool = abs(drift) < 0.01 \
		and abs(company.money - (5000.0 - cost)) < 0.01 \
		and abs(st.treasury - (treasury_before + cost)) < 0.01 \
		and abs(rep_after - (rep_before + 20.0)) < 0.01 \
		and cd_week == SimulationClock.week
	_report("bribe_conserves_and_raises_rep", passed,
		"cost=%.0f drift=%.4f rep=%.0f->%.0f money=%.0f treasury+=%.0f cd_week=%d" %
		[cost, drift, rep_before, rep_after, company.money, st.treasury - treasury_before, cd_week])
	return passed

func test_bribe_cooldown_blocks() -> bool:
	WorldState.build_world()
	var main: Node = _main()
	var state_id := "france"
	var st: State = WorldState.get_state(state_id)
	var company: Company = WorldState.get_company("player")
	company.money = 5000.0
	WorldState.player_rep[state_id] = 0.0
	main.call("bribe_state", state_id)   # first bribe succeeds
	var money_after := company.money
	var rep_after := WorldState.get_player_rep(state_id)
	var treasury_after := st.treasury
	main.call("bribe_state", state_id)   # same week -> on 4-week cooldown, must no-op
	var passed: bool = abs(company.money - money_after) < 0.01 \
		and abs(WorldState.get_player_rep(state_id) - rep_after) < 0.01 \
		and abs(st.treasury - treasury_after) < 0.01
	_report("bribe_cooldown_blocks", passed,
		"money=%.0f (was %.0f) rep=%.0f treasury_delta=%.0f" %
		[company.money, money_after, WorldState.get_player_rep(state_id), st.treasury - treasury_after])
	return passed

func test_bribe_blocked_no_funds() -> bool:
	WorldState.build_world()
	var main: Node = _main()
	var state_id := "france"
	var st: State = WorldState.get_state(state_id)
	var company: Company = WorldState.get_company("player")
	company.money = 100.0   # below the 500 base cost at rep 0
	WorldState.player_rep[state_id] = 0.0
	var treasury_before := st.treasury
	var rep_before := WorldState.get_player_rep(state_id)
	main.call("bribe_state", state_id)
	var passed: bool = abs(company.money - 100.0) < 0.01 \
		and abs(st.treasury - treasury_before) < 0.01 \
		and abs(WorldState.get_player_rep(state_id) - rep_before) < 0.01
	_report("bribe_blocked_no_funds", passed,
		"money=%.0f treasury_delta=%.0f rep=%.0f" %
		[company.money, st.treasury - treasury_before, WorldState.get_player_rep(state_id)])
	return passed

func test_citizenship_changes_flag_and_conserves() -> bool:
	WorldState.build_world()
	var main: Node = _main()
	var state_id := "france"
	var st: State = WorldState.get_state(state_id)
	var company: Company = WorldState.get_company("player")
	var ship: Ship = WorldState.get_player_ship()
	company.money = 5000.0
	WorldState.player_rep[state_id] = 60.0   # rep > 50 threshold -> eligible
	var flag_before := ship.flag_state   # player starts flying "england"
	var treasury_before := st.treasury
	var total_before := WorldState.total_money()
	main.call("apply_citizenship", state_id)
	var drift := WorldState.total_money() - total_before
	# Flag switches to the new state; 5000 fee flows company -> state.treasury.
	var passed: bool = ship.flag_state == state_id \
		and abs(drift) < 0.01 \
		and abs(company.money) < 0.01 \
		and abs(st.treasury - (treasury_before + 5000.0)) < 0.01
	_report("citizenship_changes_flag_and_conserves", passed,
		"flag=%s->%s drift=%.4f money=%.0f treasury+=%.0f" %
		[flag_before, ship.flag_state, drift, company.money, st.treasury - treasury_before])
	return passed

func test_citizenship_blocked_low_rep() -> bool:
	WorldState.build_world()
	var main: Node = _main()
	var state_id := "france"
	var company: Company = WorldState.get_company("player")
	var ship: Ship = WorldState.get_player_ship()
	company.money = 5000.0
	WorldState.player_rep[state_id] = 0.0   # rep <= 50 -> blocked
	var flag_before := ship.flag_state
	var money_before := company.money
	main.call("apply_citizenship", state_id)
	var passed: bool = ship.flag_state == flag_before and abs(company.money - money_before) < 0.01
	_report("citizenship_blocked_low_rep", passed,
		"flag=%s (was %s) money=%.0f" % [ship.flag_state, flag_before, company.money])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
