extends Node

## C5 (soft death prevention) tests. Run with:
##   godot --headless --path <project> tests/test_soft_death.tscn
##
## Verifies the C5 interim fix in ShipsTick._step_ship:
##  1. A ship whose owner has $0 still sails — upkeep is debited, money goes
##     negative (down to the credit floor), ship is NOT idled. This closes the
##     pre-C5 dead-end ($0 → idle → no revenue → game over with no UI).
##  2. A ship whose owner is below the credit floor (-(upkeep × GRACE_DAYS))
##     truly strands — state="idle", no debit (real bankruptcy/credit_limit is C4).
##  3. The negative-balance debit is conserved — drift stays ~0 over a multi-day
##     run on credit (crew wages + port services are still credited).

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_zero_money_sails_on_credit()
	ok = ok and test_below_credit_floor_strands()
	ok = ok and test_credit_debit_conserved()
	print("\n=== %s ===" % ("ALL C5 TESTS PASSED" if ok else "SOME C5 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## The player's ship (build_world gives the player exactly one ship with a
## route, so we can drive a deterministic credit/strand scenario on it).
func _player_ship() -> Ship:
	for s in WorldState.ships:
		if s.owner_id == "player":
			return s
	return null

## Test 1: owner money = 0 → upkeep still debited, money goes negative, ship
## is not idled (sails on credit). Drift stays 0 (debit credits crew + port).
func test_zero_money_sails_on_credit() -> bool:
	WorldState.build_world()
	var ship: Ship = _player_ship()
	if ship == null:
		_report("zero_money_sails_on_credit", false, "no player ship in build_world")
		return false
	var company: Company = WorldState.get_company("player")
	company.money = 0.0   # the pre-C5 softlock point
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(1)
	var drift: float = WorldState.total_money() - total_before
	# money went negative (upkeep debited despite $0), ship moved (not idled),
	# and the debit was conserved (crew + port services credited).
	var passed: bool = company.money < 0.0 and ship.state != "idle" and abs(drift) < 0.001
	_report("zero_money_sails_on_credit", passed,
			"money=%.2f state=%s drift=%.4f (expect money<0, state!=idle, drift=0)" %
			[company.money, ship.state, drift])
	return passed

## Test 2: owner money below the credit floor → ship truly strands (idle, no
## debit). The floor is -(upkeep × GRACE_DAYS); well below it must idle.
func test_below_credit_floor_strands() -> bool:
	WorldState.build_world()
	var ship: Ship = _player_ship()
	if ship == null:
		_report("below_credit_floor_strands", false, "no player ship in build_world")
		return false
	var company: Company = WorldState.get_company("player")
	var floor: float = -(ship.upkeep_daily * float(ShipsTick.SOFT_CREDIT_GRACE_DAYS))
	company.money = floor - ship.upkeep_daily * 10.0   # well below the floor
	var money_before: float = company.money
	var engine := SimulationEngine.new()
	engine.run_days(1)
	# Strand: state flips to idle, and no upkeep is debited (money unchanged —
	# the early return skips the debit, and an idled ship reaches no trade code).
	var passed: bool = ship.state == "idle" and company.money == money_before
	_report("below_credit_floor_strands", passed,
			"state=%s money=%.2f->%.2f floor=%.2f (expect idle, money unchanged)" %
			[ship.state, money_before, company.money, floor])
	return passed

## Test 3: run several days with the owner on credit (money=0) — the negative
## debit must be conserved (drift ~0) across all days, since every debit credits
## crew wages + port services back into total_money.
func test_credit_debit_conserved() -> bool:
	WorldState.build_world()
	var ship: Ship = _player_ship()
	if ship == null:
		_report("credit_debit_conserved", false, "no player ship in build_world")
		return false
	var company: Company = WorldState.get_company("player")
	company.money = 0.0
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(5)
	var drift: float = WorldState.total_money() - total_before
	var passed: bool = abs(drift) < 1.0
	_report("credit_debit_conserved", passed,
			"drift=%.4f over 5d on credit (expect |drift|<1)" % [drift])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
