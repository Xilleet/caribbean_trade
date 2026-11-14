extends Node

## Stage-2 tests. Run directly (prints PASS/FAIL and quits with exit code) OR via
## GUT:   godot --headless --path <project> tests/test_trade.tscn
##
## Covers the Stage-2 quality criteria from the v0.1 plan:
##  - a ship cannot sell a good it does not carry;
##  - a circular route earns a verifiable profit over 60 days;
##  - money is still conserved (profit is arbitrage, not created cash).

const RUN_DAYS: int = 60

func _ready() -> void:
	var ok := true
	ok = ok and test_ship_cannot_sell_empty_cargo()
	ok = ok and test_route_profitable_60d()
	print("\n=== %s ===" % ("ALL STAGE-2 TESTS PASSED" if ok else "SOME STAGE-2 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_ship_cannot_sell_empty_cargo() -> bool:
	WorldState.build_world()
	var ship: Ship = WorldState.ships[0]
	ship.cargo.clear()
	ship.cargo_used = 0.0
	var company: Company = WorldState.get_company(ship.owner_id)
	var town: Town = WorldState.get_town("port_royal")
	var trade := TradeSystem.new(MarketSystem.new())
	var rule := TradeRoute.StopRule.new()
	rule.good_id = "rum"
	rule.action = "sell"
	rule.threshold = 10.0
	rule.max_qty = 40.0
	rule.price_limit = 100.0
	var res: Dictionary = trade.execute_sell(ship, company, town, rule)
	var passed: bool = float(res["qty"]) == 0.0 and float(res["revenue"]) == 0.0
	_report("ship_cannot_sell_empty_cargo", passed,
			"qty=%.2f revenue=%.2f" % [float(res["qty"]), float(res["revenue"])])
	return passed

func test_route_profitable_60d() -> bool:
	WorldState.build_world()
	var player: Company = WorldState.get_company("player")
	var start: float = player.money
	var total_start: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(RUN_DAYS)
	var profit: float = player.money - start
	var drift: float = WorldState.total_money() - total_start
	var passed: bool = profit > 0.0 and abs(drift) < 1.0
	_report("route_profitable_60d", passed,
			"profit=%.1f drift=%.4f (need profit>0, |drift|<1)" % [profit, drift])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
