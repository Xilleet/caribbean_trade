extends Node

## Stage B2 — labour market tests. Run with:
##   godot --headless --path <project> tests/test_labour.tscn
##
## Verifies profession-based hiring + wage dynamics:
##  1. Industry hires from matching-profession Pop (lumber_camp → laborer)
##  2. Industry cannot hire without matching Pop (no laborer → workers=0)
##  3. Wage rises on shortage (2 smithies + 1 smith Pop → wage_rate > 1.0)
##  4. Wage falls on surplus (no industries + many Pops → wage_rate < 1.0)
##  5. employed_count tracks hiring (after update_employment, matches)
##  6. Multiple industries share same profession pool (2 lumber_camps ≤ supply)
##  7. drift=0 with wage dynamics (30-day sim)
##
## All tests verify drift=0 via WorldState.total_money() where applicable.

const LUMBER_RECIPE := {"id":"lumber_camp","name":"Lumber Camp","inputs":{},"outputs":{"wood":1},"workers_required":8,"daily_capacity":10,"daily_wages":16,"daily_maintenance":4,"profession_required":"laborer"}
const SMITHY_RECIPE := {"id":"smithy","name":"Smithy","inputs":{"metal":2},"outputs":{"metal_goods":1},"workers_required":10,"daily_capacity":6,"daily_wages":24,"daily_maintenance":6,"profession_required":"smith"}
const DISTILLERY_RECIPE := {"id":"distillery","name":"Distillery","inputs":{"sugar":2},"outputs":{"rum":1},"workers_required":8,"daily_capacity":6,"daily_wages":20,"daily_maintenance":6,"profession_required":"artisan"}

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_industry_hires_from_matching_profession()
	ok = ok and test_industry_cannot_hire_without_matching_pop()
	ok = ok and test_wage_rises_on_shortage()
	ok = ok and test_wage_falls_on_surplus()
	ok = ok and test_employed_count_tracks_hiring()
	ok = ok and test_multiple_industries_share_profession_pool()
	ok = ok and test_drift_zero_with_wage_dynamics()
	print("\n=== %s ===" % ("ALL TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## Industry with matching-profession Pop hires workers.
## lumber_camp requires "laborer" → town with laborer Pop → workers > 0.
func test_industry_hires_from_matching_profession() -> bool:
	WorldState.reset()
	var t := Town.new("t_hire", "HireTown")
	t.population_money = 5000.0
	WorldState.towns.append(t)
	# Create a laborer Pop with enough count.
	t.pops.append(Pop.new("p1", "t_hire", "poor", "laborer", 100.0))
	# Create a lumber_camp (requires laborer) with positive weekly_profit → hires.
	var ind := Industry.new("i1", "lumber_camp", "t_hire", 8.0, 2000.0, "town:t_hire")
	ind.weekly_profit = 100.0  # positive → should hire
	t.industries.append(ind)
	var recipes := {"lumber_camp": LUMBER_RECIPE}
	var pop_sys := PopulationSystem.new()
	pop_sys.update_employment(t, recipes)
	var passed: bool = ind.workers > 0.0
	_report("industry_hires_from_matching_profession", passed,
		"workers=%.1f (expect >0, lumber_camp + laborer Pop)" % ind.workers)
	return passed

## Industry without matching-profession Pop cannot hire.
## lumber_camp requires "laborer" → town with only artisan Pops → workers = 0.
func test_industry_cannot_hire_without_matching_pop() -> bool:
	WorldState.reset()
	var t := Town.new("t_nohire", "NoHireTown")
	t.population_money = 5000.0
	WorldState.towns.append(t)
	# Only artisan Pop — no laborer.
	t.pops.append(Pop.new("p1", "t_nohire", "middle", "artisan", 100.0))
	# lumber_camp requires laborer — none available.
	var ind := Industry.new("i1", "lumber_camp", "t_nohire", 8.0, 2000.0, "town:t_nohire")
	ind.weekly_profit = 100.0
	t.industries.append(ind)
	var recipes := {"lumber_camp": LUMBER_RECIPE}
	var pop_sys := PopulationSystem.new()
	pop_sys.update_employment(t, recipes)
	# target was min(req*1.5, workers+1) = min(12, 9) = 9, but supply=0 → scaled to 0.
	var passed: bool = ind.workers == 0.0
	_report("industry_cannot_hire_without_matching_pop", passed,
		"workers=%.1f (expect 0, no laborer Pop)" % ind.workers)
	return passed

## Wage rises when demand > supply for a profession.
## 2 smithies (each wants 10 workers) + 1 smith Pop (count=5) → shortage →
## wage_rate["smith"] > 1.0 after a few weeks.
func test_wage_rises_on_shortage() -> bool:
	WorldState.reset()
	var t := Town.new("t_short", "ShortageTown")
	t.population_money = 10000.0
	WorldState.towns.append(t)
	# Smith Pop with only 5 people — very scarce.
	t.pops.append(Pop.new("p1", "t_short", "middle", "smith", 5.0))
	# 2 smithies, each wants ~10 workers (weekly_profit > 0 → target = req*1.5=15).
	var ind1 := Industry.new("s1", "smithy", "t_short", 10.0, 3000.0, "town:t_short")
	ind1.weekly_profit = 200.0
	var ind2 := Industry.new("s2", "smithy", "t_short", 10.0, 3000.0, "town:t_short")
	ind2.weekly_profit = 200.0
	t.industries.append(ind1)
	t.industries.append(ind2)
	var recipes := {"smithy": SMITHY_RECIPE}
	var pop_sys := PopulationSystem.new()
	# Run update_employment + adjust_wages for 4 weeks.
	for _i in range(4):
		pop_sys.update_employment(t, recipes)
		pop_sys.adjust_wages(t, recipes)
	# Demand (30 target) >> supply (5) → ratio=6.0 → wage should have risen.
	var smith_wage: float = float(t.wage_rate.get("smith", 1.0))
	var passed: bool = smith_wage > 1.0
	_report("wage_rises_on_shortage", passed,
		"smith wage_rate=%.3f (expect >1.0, demand 30 vs supply 5)" % smith_wage)
	return passed

## Wage falls when supply > demand (no industries needing this profession).
## Town with many laborer Pops but no industries → wage_rate["laborer"] < 1.0.
func test_wage_falls_on_surplus() -> bool:
	WorldState.reset()
	var t := Town.new("t_surp", "SurplusTown")
	t.population_money = 5000.0
	WorldState.towns.append(t)
	# Many laborer Pops, no industries needing laborer.
	t.pops.append(Pop.new("p1", "t_surp", "poor", "laborer", 200.0))
	# One smithy (requires smith, not laborer) — no demand for laborer.
	var ind := Industry.new("s1", "smithy", "t_surp", 10.0, 3000.0, "town:t_surp")
	ind.weekly_profit = 100.0
	t.industries.append(ind)
	# Need a smith Pop for the smithy to function.
	t.pops.append(Pop.new("p2", "t_surp", "middle", "smith", 20.0))
	var recipes := {"smithy": SMITHY_RECIPE}
	var pop_sys := PopulationSystem.new()
	# Run for 4 weeks — laborer demand=0, supply=200 → ratio=0 → wage falls.
	for _i in range(4):
		pop_sys.update_employment(t, recipes)
		pop_sys.adjust_wages(t, recipes)
	var laborer_wage: float = float(t.wage_rate.get("laborer", 1.0))
	var passed: bool = laborer_wage < 1.0
	_report("wage_falls_on_surplus", passed,
		"laborer wage_rate=%.3f (expect <1.0, demand 0 vs supply 200)" % laborer_wage)
	return passed

## After update_employment, pop.employed_count = sum of matching ind.workers.
func test_employed_count_tracks_hiring() -> bool:
	WorldState.reset()
	var t := Town.new("t_emp", "EmployedTown")
	t.population_money = 5000.0
	WorldState.towns.append(t)
	# laborer Pop with 100 people.
	t.pops.append(Pop.new("p1", "t_emp", "poor", "laborer", 100.0))
	# 2 lumber_camps, both want workers.
	var ind1 := Industry.new("l1", "lumber_camp", "t_emp", 8.0, 2000.0, "town:t_emp")
	ind1.weekly_profit = 100.0
	var ind2 := Industry.new("l2", "lumber_camp", "t_emp", 8.0, 2000.0, "town:t_emp")
	ind2.weekly_profit = 100.0
	t.industries.append(ind1)
	t.industries.append(ind2)
	var recipes := {"lumber_camp": LUMBER_RECIPE}
	var pop_sys := PopulationSystem.new()
	pop_sys.update_employment(t, recipes)
	# employed_count should = ind1.workers + ind2.workers.
	var expected_employed: float = ind1.workers + ind2.workers
	var actual_employed: float = t.pops[0].employed_count
	var passed: bool = abs(actual_employed - expected_employed) < 0.01
	_report("employed_count_tracks_hiring", passed,
		"employed=%.1f (expect %.1f = ind1 %.1f + ind2 %.1f)" %
		[actual_employed, expected_employed, ind1.workers, ind2.workers])
	return passed

## Multiple industries sharing same profession pool don't exceed supply.
## 2 lumber_camps + 10 laborer Pops → both get workers, total ≤ 10.
func test_multiple_industries_share_profession_pool() -> bool:
	WorldState.reset()
	var t := Town.new("t_share", "ShareTown")
	t.population_money = 5000.0
	WorldState.towns.append(t)
	# Only 10 laborer Pops.
	t.pops.append(Pop.new("p1", "t_share", "poor", "laborer", 10.0))
	# 2 lumber_camps each want 12 workers (target = min(req*1.5=12, workers+1)).
	# Total demand = 24, supply = 10 → scaled down to fit 10.
	var ind1 := Industry.new("l1", "lumber_camp", "t_share", 8.0, 2000.0, "town:t_share")
	ind1.weekly_profit = 100.0
	var ind2 := Industry.new("l2", "lumber_camp", "t_share", 8.0, 2000.0, "town:t_share")
	ind2.weekly_profit = 100.0
	t.industries.append(ind1)
	t.industries.append(ind2)
	var recipes := {"lumber_camp": LUMBER_RECIPE}
	var pop_sys := PopulationSystem.new()
	pop_sys.update_employment(t, recipes)
	var total_workers: float = ind1.workers + ind2.workers
	# Both should have > 0 workers, total ≤ supply (10).
	var passed: bool = ind1.workers > 0.0 and ind2.workers > 0.0 and total_workers <= 10.0 + 0.01
	_report("multiple_industries_share_profession_pool", passed,
		"ind1=%.1f ind2=%.1f total=%.1f (expect both>0, total≤10)" %
		[ind1.workers, ind2.workers, total_workers])
	return passed

## 30-day sim with wage dynamics — drift=0 (money conserved).
func test_drift_zero_with_wage_dynamics() -> bool:
	WorldState.build_world()
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	for _i in range(30):
		engine.step_day()
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before
	# Check that wage_rate has been populated for at least some professions.
	var has_wages: bool = false
	for t in WorldState.towns:
		if t.wage_rate.size() > 0:
			has_wages = true
			break
	var passed: bool = abs(drift) < 1.0 and has_wages
	_report("drift_zero_with_wage_dynamics", passed,
		"drift=%.4f wage_rates_populated=%s (expect |drift|<1, wages exist)" %
		[drift, has_wages])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
