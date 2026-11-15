extends Node

## Minimal market tests. Run the scene directly (it prints PASS/FAIL and
## quits) to sanity-check the price model and transaction limits:
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
	# Tranched pricing — draining stock 5→0 raises price per tranche.
	# Stock=5 vs default target=10 → first tranche at price ~176 (above base 83),
	# last tranche clamped at max=300. Total cost is between 5*base and 5*max.
	var ms := MarketSystem.new()
	var m := Market.new()
	m.add_good("metal", 83.0, 10.0, 300.0, 5.0)  # 5 in stock, target 10 = mild shortage
	var res := ms.buy(m, "metal", 100.0, 10000.0)  # wants 100, only 5 in stock, plenty money
	var qty: float = float(res["qty"])
	var cost: float = float(res["cost"])
	var passed: bool = qty == 5.0 and cost > 5.0 * 83.0 and cost < 5.0 * 300.0
	_report("buy_stock_limit", passed, "qty=%.2f cost=%.2f (expect qty=5, 415<cost<1500)" % [qty, cost])
	return passed

func test_buy_money_limit() -> bool:
	# Stage 7.1: in mild shortage, tranche prices rise as buyer drains stock →
	# the buyer can afford FEWER units than the flat-pricing baseline 200/base.
	# Stock 8 vs target 10 → first tranche ~112, second tranche pricier, etc.
	var ms := MarketSystem.new()
	var m := Market.new()
	m.add_good("metal", 83.0, 10.0, 300.0, 8.0)  # stock 8 vs target 10 = mild shortage
	var res := ms.buy(m, "metal", 100.0, 200.0)  # wants 100, money 200
	var qty: float = float(res["qty"])
	var flat_baseline: float = 200.0 / 83.0   # ~2.41
	var passed: bool = qty > 0.0 and qty < flat_baseline
	_report("buy_money_limit", passed, "qty=%.3f (expect 0<qty<%.3f due to rising tranche prices)" % [qty, flat_baseline])
	return passed

func test_production_needs_inputs() -> bool:
	# A textile mill with no cloth on the market must produce 0 textiles.
	# Stage C7: textile_mill now takes cloth (intermediate) instead of cotton
	# (raw) — see data/recipes.json. Test mirrors the live data recipe.
	var ms := MarketSystem.new()
	var prod := ProductionSystem.new(ms)
	var t := Town.new("t_test", "TestTown")
	t.market.add_good("cloth", 80.0, 15.0, 220.0, 0.0)   # no cloth
	t.market.add_good("textiles", 150.0, 20.0, 500.0, 0.0)
	var ind := Industry.new("i1", "textile_mill", "t_test", 10.0, 1000.0)
	t.industries.append(ind)
	var recipes := {
		"textile_mill": {"id":"textile_mill","inputs":{"cloth":2},"outputs":{"textiles":1},
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
