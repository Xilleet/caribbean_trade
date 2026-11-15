extends Node

## Stage C1 (minimal) ownership tests. Run with:
##   godot --headless --path <project> tests/test_ownership.tscn
##
## Verifies that Industry.owner_id routes dividends correctly in
## FinanceSystem.distribute_profits:
##  1. default "town:<id>" owner → payout to town.population_money (baseline
##     preserved — Stage 1-6 behavior unchanged)
##  2. "player" owner → payout to player Company.money (NOT to population)
##  3. unknown/"entrepreneur:<id>" owner → falls back to population (no crash)
##
## Conservation invariant (WorldState.total_money) verified in tests 2 and 3
## by snapshotting before/after distribute_profits.

func _ready() -> void:
	# Clean any prior state from autoloaded WorldState (other test scenes in
	# the same process may have pushed companies/states).
	WorldState.reset()
	var ok := true
	ok = ok and test_dividend_routes_to_town_by_default()
	ok = ok and test_dividend_routes_to_player_when_owned()
	ok = ok and test_unknown_owner_falls_back_to_population()
	print("\n=== %s ===" % ("ALL TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## Test 1: industry with owner_id="town:t" → payout goes to t.population_money.
## This is the baseline (Stage 1-6 behavior preserved). No companies/states
## needed — pure unit test on FinanceSystem + Town + Industry.
func test_dividend_routes_to_town_by_default() -> bool:
	var fin := FinanceSystem.new()
	var t := Town.new("t_own", "OwnerTown")
	t.population_money = 0.0
	# A lumber camp with way more money than its reserve — guaranteed payout.
	var ind := Industry.new("i1", "lumber_camp", "t_own", 8.0, 5000.0, "town:t_own")
	t.industries.append(ind)
	var recipes := {
		"lumber_camp": {"id":"lumber_camp","inputs":{},"outputs":{"wood":1},
			"workers_required":8,"daily_capacity":10,"daily_wages":16,"daily_maintenance":4}
	}
	var pop_before: float = t.population_money
	fin.distribute_profits(t, recipes)
	var payout: float = t.population_money - pop_before
	# Expect payout > 0 (industry had 5000, reserve ~ max(300, 2*20)=40 → payout ~4960)
	# and industry.money should equal the reserve.
	var passed: bool = payout > 0.0 and ind.money < 5000.0
	_report("dividend_routes_to_town_by_default", passed,
		"payout=%.2f ind.money=%.2f (expect payout>0, ind.money<5000)" % [payout, ind.money])
	return passed

## Test 2: industry with owner_id="player" → payout goes to player Company.money,
## NOT to town.population_money. Conservation: total_money before == after.
func test_dividend_routes_to_player_when_owned() -> bool:
	WorldState.reset()
	var player := Company.new("player", "Player Trading Co.", 1000.0, false)
	WorldState.companies.append(player)

	var fin := FinanceSystem.new()
	var t := Town.new("t_pl", "PlayerOwnsTown")
	t.population_money = 0.0
	WorldState.towns.append(t)
	# Industry owned by player; load it with money > reserve.
	var ind := Industry.new("i2", "smithy", "t_pl", 10.0, 8000.0, "player")
	t.industries.append(ind)
	var recipes := {
		"smithy": {"id":"smithy","inputs":{"metal":2},"outputs":{"metal_goods":1},
			"workers_required":10,"daily_capacity":6,"daily_wages":24,"daily_maintenance":6}
	}
	# Need a market entry for "metal" so input_cost_per_batch is computable
	# (distribute_profits reads market prices for inputs). Without it the
	# input cost = 0, reserve = max(300, 2*(0*6+24+6)) = max(300, 60) = 300.
	# Either way payout > 0 because ind.money=8000 >> any reserve.
	t.market.add_good("metal", 83.0, 10.0, 300.0, 50.0)

	var pop_before: float = t.population_money
	var player_before: float = player.money
	var total_before: float = WorldState.total_money()

	fin.distribute_profits(t, recipes)

	var pop_payout: float = t.population_money - pop_before
	var player_payout: float = player.money - player_before
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before

	# Player should get the payout; population should get 0; drift == 0.
	var passed: bool = player_payout > 0.0 and pop_payout == 0.0 and abs(drift) < 0.001
	_report("dividend_routes_to_player_when_owned", passed,
		"player_payout=%.2f pop_payout=%.2f drift=%.4f (expect player>0, pop=0, drift=0)" %
		[player_payout, pop_payout, drift])
	return passed

## Test 3: industry with owner_id="entrepreneur:foo" (no such entity) →
## payout falls back to town.population_money. No crash, conservation holds.
func test_unknown_owner_falls_back_to_population() -> bool:
	WorldState.reset()
	var fin := FinanceSystem.new()
	var t := Town.new("t_unk", "UnknownOwnerTown")
	t.population_money = 0.0
	WorldState.towns.append(t)
	var ind := Industry.new("i3", "bakery", "t_unk", 10.0, 6000.0, "entrepreneur:foo")
	t.industries.append(ind)
	var recipes := {
		"bakery": {"id":"bakery","inputs":{"corn":1},"outputs":{"bread":1},
			"workers_required":10,"daily_capacity":18,"daily_wages":22,"daily_maintenance":5}
	}
	t.market.add_good("corn", 22.0, 3.0, 90.0, 30.0)

	var pop_before: float = t.population_money
	var total_before: float = WorldState.total_money()

	fin.distribute_profits(t, recipes)

	var pop_payout: float = t.population_money - pop_before
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before

	# Population got the payout (fallback), drift == 0 (population is in total_money).
	var passed: bool = pop_payout > 0.0 and abs(drift) < 0.001
	_report("unknown_owner_falls_back_to_population", passed,
		"pop_payout=%.2f drift=%.4f (expect pop>0 fallback, drift=0)" % [pop_payout, drift])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
