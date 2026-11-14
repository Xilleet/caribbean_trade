extends Node

## Minimal market tests. Run with GUT (https://github.com/bitwes/Gut) by placing
## this file in a test/ dir and pointing GUT at it, OR just run the scene
## directly (it prints PASS/FAIL and quits) to sanity-check the price model and
## transaction limits without GUT installed:
##   godot --headless --path <project> tests/test_market.tscn
##
## These tests cover the Stage-1 quality criteria from the v0.1 plan:
##  - shortage raises price above base; surplus lowers it below base
##  - buy is capped by stock and by buyer money
##  - production needs inputs (a mill with no cotton produces nothing)

const CONSUMPTION_BASKETS_PATH := "res://data/goods.json"

func _ready() -> void:
	var ok := true
	ok = ok and test_price_shortage()
	ok = ok and test_price_surplus()
	ok = ok and test_buy_stock_limit()
	ok = ok and test_buy_money_limit()
	ok = ok and test_production_needs_inputs()
	print("\n=== %s ===" % ("ALL TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_price_shortage() -> bool:
	var ms := MarketSystem.new()
	var m := Market.new()
	m.add_good("wood", 33.0, 5.0, 150.0, 2.0)  # stock far below target
	var e := m.get_entry("wood")
	e.daily_demand = 10.0
	ms.update_target(e)
	var p := ms.calculate_price(e)
	var passed: bool = p > 33.0
	_report("price_shortage", passed, "price=%.2f (expect > 33)" % p)
	return passed

func test_price_surplus() -> bool:
	var ms := MarketSystem.new()
	var m := Market.new()
	m.add_good("wood", 33.0, 5.0, 150.0, 200.0)  # glut
	var e := m.get_entry("wood")
	e.daily_demand = 2.0
	ms.update_target(e)
	var p := ms.calculate_price(e)
	var passed: bool = p < 33.0
	_report("price_surplus", passed, "price=%.2f (expect < 33)" % p)
	return passed

func test_buy_stock_limit() -> bool:
	var ms := MarketSystem.new()
	var m := Market.new()
	m.add_good("metal", 83.0, 10.0, 300.0, 5.0)
	var res := ms.buy(m, "metal", 100.0, 10000.0)  # wants 100, only 5 in stock
	var passed: bool = float(res["qty"]) == 5.0 and abs(float(res["cost"]) - 5.0 * 83.0) < 0.001
	_report("buy_stock_limit", passed, "qty=%.2f cost=%.2f" % [float(res["qty"]), float(res["cost"])])
	return passed

func test_buy_money_limit() -> bool:
	var ms := MarketSystem.new()
	var m := Market.new()
	m.add_good("metal", 83.0, 10.0, 300.0, 1000.0)
	# wants 100, stock 1000, but only 200 money -> can afford 200/83 = 2.41
	var res := ms.buy(m, "metal", 100.0, 200.0)
	var expected := 200.0 / 83.0
	var passed: bool = abs(float(res["qty"]) - expected) < 0.01
	_report("buy_money_limit", passed, "qty=%.3f (expect ~%.3f)" % [float(res["qty"]), expected])
	return passed

func test_production_needs_inputs() -> bool:
	# A textile mill with no cotton on the market must produce 0 textiles.
	var ms := MarketSystem.new()
	var prod := ProductionSystem.new(ms)
	var t := Town.new("t_test", "TestTown")
	t.market.add_good("cotton", 45.0, 5.0, 180.0, 0.0)   # no cotton
	t.market.add_good("textiles", 150.0, 20.0, 500.0, 0.0)
	var ind := Industry.new("i1", "textile_mill", "t_test", 10.0, 1000.0)
	t.industries.append(ind)
	var recipes := {
		"textile_mill": {"id":"textile_mill","inputs":{"cotton":2},"outputs":{"textiles":1},
			"workers_required":10,"daily_capacity":8,"daily_wages":22,"daily_maintenance":5}
	}
	prod.reset_daily_stats(t)
	prod.calculate_input_demand(t, recipes)
	prod.purchase_inputs(t, recipes)
	prod.produce(t, recipes)
	var passed: bool = ind.produced_batches == 0.0 and t.market.get_entry("textiles").stock == 0.0
	_report("production_needs_inputs", passed,
			"produced_batches=%.2f textiles_stock=%.2f" % [ind.produced_batches, t.market.get_entry("textiles").stock])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
