extends Node

## Stage C8.2 (investment & expansion) tests. Run with:
##   godot --headless --path <project> tests/test_expansion.tscn
##
## Verifies the C8.2 expansion model:
##  1. town-owned self-finances: shortage signal → reserve raised → funded from
##     retained earnings → construction starts (drift=0).
##  2. player-owned is NOT auto-expanded by process_expansion (player = manual).
##  3. request_expansion() debits the player wallet above its floor → starts.
##  4. completion (after EXPANSION_WEEKS): capacity_level += 1, wear = 0.
##  5. no shortage signal → no expansion.
##  6. shortage but unprofitable → no expansion.
##  7. drift stays ~0 over 365d (expansion debits → market.fund, conserved).

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_town_self_finance_expansion()
	ok = ok and test_player_auto_skipped()
	ok = ok and test_player_request_expansion()
	ok = ok and test_completion_raises_capacity_resets_wear()
	ok = ok and test_no_expansion_without_shortage()
	ok = ok and test_unprofitable_no_expansion()
	ok = ok and test_drift_zero_365d()
	print("\n=== %s ===" % ("ALL C8.2 TESTS PASSED" if ok else "SOME C8.2 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func _lumber_recipe() -> Dictionary:
	return {"id":"lumber_camp","inputs":{},"outputs":{"wood":1},
		"workers_required":8,"daily_capacity":10,"daily_wages":16,"daily_maintenance":4,
		"profession_required":"laborer"}

## Build a one-industry town with a controllable wood market (shortage signal
## = stock < target×0.5 AND price > base×1.2; base=10, target=100 → shortage
## needs stock<50 and price>12). Registers the town (and a player company for
## player-owned tests) in WorldState so total_money() sees it.
func _setup_exp_town(owner_id: String, wood_stock: float, wood_price: float, weekly_profit: float, ind_money: float) -> Town:
	var t := Town.new("t_exp", "ExpTown")
	t.pops.append(Pop.new("p_lab", "t_exp", "poor", "laborer", 8.0))
	t.market.add_good("wood", 10.0, 1.0, 50.0, wood_stock)
	t.market.get_entry("wood").target_stock = 100.0
	t.market.get_entry("wood").current_price = wood_price
	var ind := Industry.new("i_exp", "lumber_camp", "t_exp", 8.0, ind_money, owner_id)
	ind.weekly_profit = weekly_profit
	t.industries.append(ind)
	WorldState.towns.append(t)
	if owner_id == "player":
		WorldState.companies.append(Company.new("player", "Player", 10000.0, false))
	return t

## Test 1: town-owned (self-financing) — shortage + profitable → distribute_profits
## raises reserve by expansion_cost, process_expansion debits retained earnings
## → construction starts. Money conserved (debit → market.fund).
func test_town_self_finance_expansion() -> bool:
	WorldState.reset()
	var t := _setup_exp_town("", 0.0, 13.0, 100.0, 5000.0)   # shortage, profitable, $5000
	var ind: Industry = t.industries[0]
	var recipes := {"lumber_camp": _lumber_recipe()}
	var fs := FinanceSystem.new()
	var total_before: float = WorldState.total_money()
	fs.distribute_profits(t, recipes)
	fs.process_expansion(t, recipes)
	var drift: float = WorldState.total_money() - total_before
	var cost: float = ind.expansion_cost(recipes["lumber_camp"])   # 80×10×1 = 800
	var passed: bool = ind.expansion_weeks_left == Industry.EXPANSION_WEEKS and \
		abs(drift) < 0.001 and abs(t.market.fund - cost) < 0.001
	_report("town_self_finance_expansion", passed,
		"weeks_left=%d drift=%.4f fund=%.2f cost=%.2f (expect weeks=2, drift=0, fund=cost)" %
		[ind.expansion_weeks_left, drift, t.market.fund, cost])
	return passed

## Test 2: player-owned industry with shortage + profitable → process_expansion
## must NOT auto-expand (player expands only via request_expansion). No debit.
func test_player_auto_skipped() -> bool:
	WorldState.reset()
	var t := _setup_exp_town("player", 0.0, 13.0, 100.0, 5000.0)   # shortage, profitable, player-owned
	var ind: Industry = t.industries[0]
	var player: Company = WorldState.get_company("player")
	var recipes := {"lumber_camp": _lumber_recipe()}
	var fs := FinanceSystem.new()
	var money_before: float = player.money
	fs.process_expansion(t, recipes)
	var passed: bool = ind.expansion_weeks_left == 0 and player.money == money_before
	_report("player_auto_skipped", passed,
		"weeks_left=%d player.money=%.2f->%.2f (expect no auto-expansion for player)" %
		[ind.expansion_weeks_left, money_before, player.money])
	return passed

## Test 3: request_expansion() on a player-owned industry → debits player wallet
## above PLAYER_WORKING_CAPITAL, starts construction, money conserved.
func test_player_request_expansion() -> bool:
	WorldState.reset()
	var t := _setup_exp_town("player", 1000.0, 8.0, 0.0, 0.0)   # no shortage, unprofitable — doesn't matter for manual
	var ind: Industry = t.industries[0]
	var player: Company = WorldState.get_company("player")
	var recipes := {"lumber_camp": _lumber_recipe()}
	var fs := FinanceSystem.new()
	var total_before: float = WorldState.total_money()
	var money_before: float = player.money
	var started: bool = fs.request_expansion(ind, recipes, t)
	var drift: float = WorldState.total_money() - total_before
	var cost: float = ind.expansion_cost(recipes["lumber_camp"])
	var passed: bool = started and ind.expansion_weeks_left == Industry.EXPANSION_WEEKS and \
		abs(player.money - (money_before - cost)) < 0.001 and abs(drift) < 0.001
	_report("player_request_expansion", passed,
		"started=%s weeks_left=%d player=%.2f->%.2f cost=%.2f drift=%.4f (expect started, debited, drift=0)" %
		[started, ind.expansion_weeks_left, money_before, player.money, cost, drift])
	return passed

## Test 4: completion after EXPANSION_WEEKS → capacity_level += 1, wear = 0.
func test_completion_raises_capacity_resets_wear() -> bool:
	WorldState.reset()
	var t := _setup_exp_town("", 1000.0, 8.0, 0.0, 1000.0)   # market irrelevant; we drive weeks_left directly
	var ind: Industry = t.industries[0]
	ind.expansion_weeks_left = Industry.EXPANSION_WEEKS
	ind.wear = 0.5
	ind.capacity_level = 1
	var recipes := {"lumber_camp": _lumber_recipe()}
	var fs := FinanceSystem.new()
	# Run EXPANSION_WEEKS weekly passes to count down to completion.
	for _w in range(Industry.EXPANSION_WEEKS):
		fs.process_expansion(t, recipes)
	var passed: bool = ind.capacity_level == 2 and ind.wear == 0.0 and \
		ind.expansion_weeks_left == 0
	_report("completion_raises_capacity_resets_wear", passed,
		"capacity_level=%d wear=%.4f weeks_left=%d (expect level=2, wear=0, weeks=0)" %
		[ind.capacity_level, ind.wear, ind.expansion_weeks_left])
	return passed

## Test 5: no shortage signal (stock high) → no expansion queued.
func test_no_expansion_without_shortage() -> bool:
	WorldState.reset()
	var t := _setup_exp_town("", 1000.0, 13.0, 100.0, 5000.0)   # stock=1000 (>50) → no shortage
	var ind: Industry = t.industries[0]
	var recipes := {"lumber_camp": _lumber_recipe()}
	var fs := FinanceSystem.new()
	var money_before: float = ind.money
	fs.distribute_profits(t, recipes)
	fs.process_expansion(t, recipes)
	var passed: bool = ind.expansion_weeks_left == 0 and ind.money <= money_before
	_report("no_expansion_without_shortage", passed,
		"weeks_left=%d money=%.2f->%.2f (expect no expansion, no funding debit)" %
		[ind.expansion_weeks_left, money_before, ind.money])
	return passed

## Test 6: shortage signal BUT weekly_profit ≤ 0 → no expansion (auto-reinvest
## requires profitability — don't grow a losing line).
func test_unprofitable_no_expansion() -> bool:
	WorldState.reset()
	var t := _setup_exp_town("", 0.0, 13.0, -50.0, 5000.0)   # shortage but losing money
	var ind: Industry = t.industries[0]
	var recipes := {"lumber_camp": _lumber_recipe()}
	var fs := FinanceSystem.new()
	fs.distribute_profits(t, recipes)
	fs.process_expansion(t, recipes)
	var passed: bool = ind.expansion_weeks_left == 0
	_report("unprofitable_no_expansion", passed,
		"weeks_left=%d weekly_profit=%.2f (expect no expansion when unprofitable)" %
		[ind.expansion_weeks_left, ind.weekly_profit])
	return passed

## Test 7: 365-day full-world sim with expansions firing — total_money stays
## conserved (|drift| < 1.0). Expansion debits land in market.fund; capacity_level
## and wear changes are state-only.
func test_drift_zero_365d() -> bool:
	WorldState.build_world()
	var total_before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(365)
	var drift: float = WorldState.total_money() - total_before
	# Confirm expansions actually fired somewhere (at least one industry leveled up),
	# else the drift check is vacuous.
	var expansions: int = 0
	for t in WorldState.towns:
		for ind in t.industries:
			if ind.capacity_level > 1 or ind.expansion_weeks_left > 0:
				expansions += 1
	var passed: bool = abs(drift) < 1.0 and expansions > 0
	_report("drift_zero_365d", passed,
		"drift=%.4f expansions_observed=%d (expect |drift|<1, ≥1 expansion fired)" %
		[drift, expansions])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
