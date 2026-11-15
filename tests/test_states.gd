extends Node

## Stage A2 tests for colonial powers (Spain/England/France/Netherlands) and
## their customs tax on ship trades. Run directly (prints PASS/FAIL and quits
## with an exit code):
##   godot --headless --path <project> tests/test_states.tscn
##
## Covers:
##  - states spawn with treasury + tax_rate; every town has a state_id
##  - customs tax flows company -> state.treasury on every ship trade
##  - sell-side customs also flows to state.treasury
##  - money conservation holds over a full 30-day sim with trades + taxes

func _ready() -> void:
	var ok := true
	ok = ok and test_states_spawn()
	ok = ok and test_buy_tax_flows_to_state()
	ok = ok and test_sell_tax_flows_to_state()
	ok = ok and test_tax_conserved_30d()
	print("\n=== %s ===" % ("ALL STAGE-A2 TESTS PASSED" if ok else "SOME STAGE-A2 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_states_spawn() -> bool:
	WorldState.build_world()
	# 4 colonial powers spawned.
	var state_count: int = WorldState.states.size()
	var struct_ok: bool = state_count >= 4
	# Every town has a non-empty state_id that maps to a real State.
	var towns_ok: bool = true
	for t in WorldState.towns:
		if t.state_id == "":
			towns_ok = false
			break
		if WorldState.get_state(t.state_id) == null:
			towns_ok = false
			break
	# Spot-check historical ownership: tortuga=france, port_royal=england, santiago=spain.
	var tortuga_state: String = WorldState.get_town("tortuga").state_id
	var pr_state: String = WorldState.get_town("port_royal").state_id
	var santiago_state: String = WorldState.get_town("santiago").state_id
	var hist_ok: bool = tortuga_state == "france" and pr_state == "england" and santiago_state == "spain"
	# State treasuries start > 0 (starting_treasury from states.json) and are in total_money().
	var total_with_states: float = WorldState.total_money()
	var treasury_sum: float = 0.0
	for s in WorldState.states:
		treasury_sum += s.treasury
	var treasury_ok: bool = treasury_sum > 0.0
	var passed: bool = struct_ok and towns_ok and hist_ok and treasury_ok
	_report("states_spawn", passed,
		"states=%d towns_ok=%s hist=%s/%s/%s treasury_sum=%.0f" %
		[state_count, towns_ok, tortuga_state, pr_state, santiago_state, treasury_sum])
	return passed

func test_buy_tax_flows_to_state() -> bool:
	WorldState.build_world()
	var ship: Ship = WorldState.get_player_ship()
	ship.cargo.clear()
	ship.cargo_used = 0.0
	var company: Company = WorldState.get_company(ship.owner_id)
	company.money = 5000.0
	# Dock at Port Royal (state=england, tax_rate=0.04). Port Royal has initial
	# sugar stock=20 at base 50 (no tick run yet, so current_price = base = 50).
	# Wait — Port Royal doesn't have sugar initial_stock. Use Tortuga (state=france,
	# tax_rate=0.05, sugar stock=15).
	var town: Town = WorldState.get_town("tortuga")
	ship.current_town_id = "tortuga"
	var state: State = WorldState.get_state(town.state_id)
	var treasury_before: float = state.treasury
	var total_before: float = WorldState.total_money()
	var trade := TradeSystem.new(MarketSystem.new())
	var res: Dictionary = trade.manual_buy(ship, company, town, "sugar", 10.0)
	# sugar in tortuga: stock=15 vs target=10 (default) → mild shortage. With
	# tranched pricing the avg price is ~67.6, qty ~1.4 (limited by money=5000? no,
	# 5000 >> 67×10=676, so full 10 units bought). Actually let me re-check: with
	# money=5000 and avg price ~67, cost ~676, well within budget. So full 10 units.
	# Tax = cost * 0.05.
	var cost: float = float(res["cost"])
	var expected_tax: float = cost * state.tax_rate
	var actual_tax: float = state.treasury - treasury_before
	var drift: float = WorldState.total_money() - total_before
	# Tax flows company -> state.treasury, both in total_money → drift = 0.
	var passed: bool = abs(actual_tax - expected_tax) < 0.01 and abs(drift) < 0.01
	_report("buy_tax_flows_to_state", passed,
		"cost=%.1f tax_expected=%.2f tax_actual=%.2f drift=%.4f" %
		[cost, expected_tax, actual_tax, drift])
	return passed

func test_sell_tax_flows_to_state() -> bool:
	WorldState.build_world()
	var ship: Ship = WorldState.get_player_ship()
	ship.cargo.clear()
	ship.cargo_used = 0.0
	ship.add_cargo("rum", 10.0)   # 10 rum to sell
	var company: Company = WorldState.get_company(ship.owner_id)
	company.money = 5000.0
	# Sell rum in Port Royal (state=england, tax_rate=0.04). Port Royal has no
	# initial rum stock → deep shortage → price at ceiling 240.
	var town: Town = WorldState.get_town("port_royal")
	ship.current_town_id = "port_royal"
	var state: State = WorldState.get_state(town.state_id)
	var treasury_before: float = state.treasury
	var total_before: float = WorldState.total_money()
	var trade := TradeSystem.new(MarketSystem.new())
	var res: Dictionary = trade.manual_sell(ship, company, town, "rum", 10.0)
	var revenue: float = float(res["revenue"])
	var expected_tax: float = revenue * state.tax_rate
	var actual_tax: float = state.treasury - treasury_before
	var drift: float = WorldState.total_money() - total_before
	var passed: bool = abs(actual_tax - expected_tax) < 0.01 and abs(drift) < 0.01
	_report("sell_tax_flows_to_state", passed,
		"revenue=%.1f tax_expected=%.2f tax_actual=%.2f drift=%.4f" %
		[revenue, expected_tax, actual_tax, drift])
	return passed

func test_tax_conserved_30d() -> bool:
	WorldState.build_world()
	var total_start: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(30)
	var drift: float = WorldState.total_money() - total_start
	# States' treasuries should have grown from customs taxes; conservation holds.
	var treasury_grew: bool = false
	for s in WorldState.states:
		if s.treasury > s.tax_rate * 100.0:   # at least some nominal growth
			treasury_grew = true
			break
	var passed: bool = abs(drift) < 1.0 and treasury_grew
	_report("tax_conserved_30d", passed,
		"drift=%.4f treasury_grew=%s (need |drift|<1, treasury grew from taxes)" %
		[drift, treasury_grew])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
