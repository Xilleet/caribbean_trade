extends Node

## Stage C8.1 (wear & maintenance) tests. Run with:
##   godot --headless --path <project> tests/test_wear.tscn
##
## Verifies the C8.1 wear/efficiency/repair model:
##  1. idle (produced_batches=0) accrues NO wear — Stage 1 "idle is free".
##  2. full utilisation accrues wear → efficiency drops (but stays ≥ floor).
##  3. efficiency floor (0.3) holds at wear=1.0 (hard stop deferred to C3/C4).
##  4. wear cuts capacity via the efficiency getter in _capacity_batches.
##  5. drift stays ~0 over 365d (wear is state-only; money conserved).

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_idle_no_wear()
	ok = ok and test_full_util_wear_accrues()
	ok = ok and test_efficiency_floor_at_max_wear()
	ok = ok and test_wear_cuts_capacity()
	ok = ok and test_drift_zero_365d()
	print("\n=== %s ===" % ("ALL C8.1 TESTS PASSED" if ok else "SOME C8.1 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## Lumber camp recipe (no inputs → produced=planned; wood is not a crop so
## drought_multiplier is never called — fully isolated from WorldState events).
func _lumber_recipe() -> Dictionary:
	return {"id":"lumber_camp","inputs":{},"outputs":{"wood":1},
		"workers_required":8,"daily_capacity":10,"daily_wages":16,"daily_maintenance":4,
		"profession_required":"laborer"}

## A minimal town + market with wood registered at a profitable price and a
## high target_stock so no glut triggers over the test horizon.
func _town_with_wood(town_id: String) -> Town:
	var t := Town.new(town_id, "WearTown")
	# Need a laborer Pop so charge_wages credits wages (else they silently drop).
	t.pops.append(Pop.new("p_lab", town_id, "poor", "laborer", 8.0))
	t.market.add_good("wood", 10.0, 1.0, 50.0, 0.0)
	t.market.get_entry("wood").target_stock = 10000.0   # anti-glut
	return t

## Test 1: idle industry (produced_batches=0) accrues no wear over 30 days.
func test_idle_no_wear() -> bool:
	WorldState.reset()
	var t := _town_with_wood("t_idle")
	var ind := Industry.new("i_idle", "lumber_camp", "t_idle", 8.0, 1000.0)
	ind.produced_batches = 0.0   # idle — no output today
	t.industries.append(ind)
	var recipes := {"lumber_camp": _lumber_recipe()}
	var ms := MarketSystem.new()
	var ps := ProductionSystem.new(ms)
	var fs := FinanceSystem.new()
	for _d in range(30):
		ind.produced_batches = 0.0
		ps.produce(t, recipes)         # accrual: util=0 → wear += 0
		fs.charge_wages(t, recipes)    # repair:  util=0 → wear -= 0
	var passed: bool = ind.wear == 0.0 and ind.efficiency == 1.0
	_report("idle_no_wear", passed,
			"wear=%.6f efficiency=%.4f (expect wear=0, eff=1.0 after 30 idle days)" %
			[ind.wear, ind.efficiency])
	return passed

## Test 2: full utilisation accrues wear → efficiency drops but stays ≥ floor.
func test_full_util_wear_accrues() -> bool:
	WorldState.reset()
	var t := _town_with_wood("t_full")
	var ind := Industry.new("i_full", "lumber_camp", "t_full", 8.0, 10000.0)
	t.industries.append(ind)
	var recipes := {"lumber_camp": _lumber_recipe()}
	var ms := MarketSystem.new()
	var ps := ProductionSystem.new(ms)
	var fs := FinanceSystem.new()
	for _d in range(100):
		ps.calculate_input_demand(t, recipes)   # plan (reads efficiency)
		ps.purchase_inputs(t, recipes)          # lumber_camp: produced = planned
		ps.produce(t, recipes)                  # sell + accrue wear (+0.003×util)
		fs.charge_wages(t, recipes)             # wages + repair (-0.002×util)
	# Net full-util drift = +0.001/day → wear ~0.1, eff ~0.93 (feedback slows it).
	var passed: bool = ind.wear > 0.0 and ind.efficiency < 1.0 and \
		ind.efficiency >= Industry.EFFICIENCY_FLOOR and ind.wear < 1.0
	_report("full_util_wear_accrues", passed,
			"wear=%.4f efficiency=%.4f floor=%.2f (expect wear>0, eff<1, eff≥floor, wear<1)" %
			[ind.wear, ind.efficiency, Industry.EFFICIENCY_FLOOR])
	return passed

## Test 3: at wear=1.0, efficiency == EFFICIENCY_FLOOR (0.3). Hard stop (eff=0)
## is deferred to C3/C4 — the floor prevents the death spiral until then.
func test_efficiency_floor_at_max_wear() -> bool:
	var ind := Industry.new("i_max", "lumber_camp", "t", 8.0, 0.0)
	ind.wear = 1.0
	var passed: bool = abs(ind.efficiency - Industry.EFFICIENCY_FLOOR) < 0.0001
	_report("efficiency_floor_at_max_wear", passed,
			"wear=1.0 efficiency=%.4f floor=%.2f (expect eff=floor)" %
			[ind.efficiency, Industry.EFFICIENCY_FLOOR])
	return passed

## Test 4: wear=0.5 → efficiency=0.65 → _capacity_batches returns cap×0.65.
## Verified via the public path: calculate_input_demand sets planned_batches.
func test_wear_cuts_capacity() -> bool:
	WorldState.reset()
	var t := _town_with_wood("t_cut")
	var ind := Industry.new("i_cut", "lumber_camp", "t_cut", 8.0, 10000.0)
	ind.wear = 0.5    # efficiency = 1 - 0.5×0.7 = 0.65
	t.industries.append(ind)
	var recipes := {"lumber_camp": _lumber_recipe()}
	var ps := ProductionSystem.new(MarketSystem.new())
	ps.calculate_input_demand(t, recipes)
	# cap=10, worker_ratio=1, efficiency=0.65, drought=1 → cap_batches=6.5.
	# No glut, break-even passes (rev 10 ≥ cost 2), affordable huge → planned=6.5.
	var expected_cap: float = 10.0 * 0.65
	var passed: bool = abs(ind.efficiency - 0.65) < 0.0001 and \
		abs(ind.planned_batches - expected_cap) < 0.01
	_report("wear_cuts_capacity", passed,
			"wear=0.5 efficiency=%.4f planned=%.4f expected=%.4f (expect eff=0.65, planned=6.5)" %
			[ind.efficiency, ind.planned_batches, expected_cap])
	return passed

## Test 5: 365-day full-world sim — wear is state-only (no money moved), so
## total_money stays conserved (|drift| < 1.0). Wear cuts output → cuts revenue
## → cuts wages/dividends, but every cut is a conserved redistribution.
func test_drift_zero_365d() -> bool:
	WorldState.build_world()
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(365)
	var drift: float = WorldState.total_money() - total_before
	var passed: bool = abs(drift) < 1.0
	_report("drift_zero_365d", passed,
			"drift=%.4f over 365d (expect |drift|<1 — wear is state-only)" % [drift])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
