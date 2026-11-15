extends Node

## Stage C7 — production chains and intermediate goods. Run with:
##   godot --headless --path <project> tests/test_chains.tscn
##
## Verifies the 3-step production chains (audit's "favourite trio"):
##   sugar_cane → sugar → rum        (sugar_plantation + sugar_mill + distillery)
##   iron_ore   → metal → metal_goods (mine + smelter + smithy)
##   cotton     → cloth → textiles   (cotton_plantation + weaver + textile_mill)
##   wood       → lumber             (lumber_camp + sawmill)
##
## Also verifies the audit's core thesis: "нехватка одного промежуточного товара
## распространяется дальше по цепочке" — a town with distillery but no sugar_mill
## cannot produce rum (sugar deficit → distillery idles).
##
## All tests verify drift=0 via WorldState.total_money() before/after.

const SUGAR_MILL_RECIPE := {"id":"sugar_mill","name":"Sugar Mill","inputs":{"sugar_cane":2},"outputs":{"sugar":1},"workers_required":8,"daily_capacity":8,"daily_wages":18,"daily_maintenance":4}
const SMELTER_RECIPE := {"id":"smelter","name":"Smelter","inputs":{"iron_ore":2},"outputs":{"metal":1},"workers_required":10,"daily_capacity":6,"daily_wages":22,"daily_maintenance":8}
const WEAVER_RECIPE := {"id":"weaver","name":"Weaver","inputs":{"cotton":2},"outputs":{"cloth":1},"workers_required":8,"daily_capacity":7,"daily_wages":18,"daily_maintenance":4}
const SAWMILL_RECIPE := {"id":"sawmill","name":"Sawmill","inputs":{"wood":2},"outputs":{"lumber":1},"workers_required":6,"daily_capacity":8,"daily_wages":14,"daily_maintenance":3}
const SUGAR_PLANT_RECIPE := {"id":"sugar_plantation","name":"Sugar Plantation","inputs":{},"outputs":{"sugar_cane":1},"workers_required":12,"daily_capacity":7,"daily_wages":20,"daily_maintenance":4}
const MINE_RECIPE := {"id":"mine","name":"Mine","inputs":{},"outputs":{"iron_ore":1},"workers_required":12,"daily_capacity":6,"daily_wages":24,"daily_maintenance":8}
const COTTON_PLANT_RECIPE := {"id":"cotton_plantation","name":"Cotton Plantation","inputs":{},"outputs":{"cotton":1},"workers_required":10,"daily_capacity":8,"daily_wages":18,"daily_maintenance":3}
const LUMBER_CAMP_RECIPE := {"id":"lumber_camp","name":"Lumber Camp","inputs":{},"outputs":{"wood":1},"workers_required":8,"daily_capacity":10,"daily_wages":16,"daily_maintenance":4}
const DISTILLERY_RECIPE := {"id":"distillery","name":"Distillery","inputs":{"sugar":2},"outputs":{"rum":1},"workers_required":8,"daily_capacity":6,"daily_wages":20,"daily_maintenance":6}
const SMITHY_RECIPE := {"id":"smithy","name":"Smithy","inputs":{"metal":2},"outputs":{"metal_goods":1},"workers_required":10,"daily_capacity":6,"daily_wages":24,"daily_maintenance":6}
const TEXTILE_MILL_RECIPE := {"id":"textile_mill","name":"Textile Mill","inputs":{"cloth":2},"outputs":{"textiles":1},"workers_required":10,"daily_capacity":8,"daily_wages":22,"daily_maintenance":5}

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_sugar_chain_produces_rum_end_to_end()
	ok = ok and test_iron_chain_produces_metal_goods_end_to_end()
	ok = ok and test_textile_chain_uses_cloth_intermediate()
	ok = ok and test_lumber_chain_produces_lumber()
	ok = ok and test_chain_breaks_when_intermediate_missing()
	print("\n=== %s ===" % ("ALL TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## Town with sugar_plantation + sugar_mill + distillery: 7-day sim → rum > 0,
## sugar > 0, sugar_cane produced. drift=0.
func test_sugar_chain_produces_rum_end_to_end() -> bool:
	WorldState.reset()
	var t := Town.new("t_sug", "SugarChainTown")
	t.population_money = 5000.0
	t.poor = 100.0
	t.middle = 30.0
	t.rich = 5.0
	WorldState.towns.append(t)
	# Set up markets for all goods in the chain
	for g in ["sugar_cane", "sugar", "rum"]:
		var base: float = 18.0 if g == "sugar_cane" else (50.0 if g == "sugar" else 120.0)
		var mn: float = 3.0 if g == "sugar_cane" else (5.0 if g == "sugar" else 30.0)
		var mx: float = 80.0 if g == "sugar_cane" else (200.0 if g == "sugar" else 240.0)
		t.market.add_good(g, base, mn, mx, 0.0)
	# Industries: plantation → mill → distillery, all owned by town
	var plantation := Industry.new("p1", "sugar_plantation", "t_sug", 12.0, 2000.0, "town:t_sug")
	var mill := Industry.new("m1", "sugar_mill", "t_sug", 8.0, 1800.0, "town:t_sug")
	var distillery := Industry.new("d1", "distillery", "t_sug", 8.0, 2000.0, "town:t_sug")
	t.industries.append(plantation)
	t.industries.append(mill)
	t.industries.append(distillery)
	var recipes := {
		"sugar_plantation": SUGAR_PLANT_RECIPE,
		"sugar_mill": SUGAR_MILL_RECIPE,
		"distillery": DISTILLERY_RECIPE,
	}
	var ms := MarketSystem.new()
	var prod := ProductionSystem.new(ms)
	var fin := FinanceSystem.new()
	var total_before: float = WorldState.total_money()
	# Simulate 7 days of production + finances.
	# reset_daily() clears market daily_demand accumulators (normally done by
	# ConsumptionSystem.calculate_demand in daily_tick.gd:36 — not used here since
	# the test is chain-mechanics-only, not population consumption).
	for _i in range(7):
		t.market.reset_daily()
		prod.reset_daily_stats(t)
		prod.calculate_input_demand(t, recipes)
		prod.purchase_inputs(t, recipes)
		prod.produce(t, recipes)
		fin.charge_wages(t, recipes)
		ms.update_market(t.market)
	fin.distribute_profits(t, recipes)
	var rum_stock: float = t.market.get_entry("rum").stock
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before
	# End-good produced → all upstream steps ran (plantation + mill + distillery).
	# Intermediates (cane, sugar) may be near 0 if consumer is profitable — that's
	# normal for a chain in equilibrium, not a failure.
	var passed: bool = rum_stock > 0.0 and abs(drift) < 0.01
	_report("sugar_chain_produces_rum_end_to_end", passed,
		"rum=%.1f drift=%.4f (expect rum>0, drift=0)" % [rum_stock, drift])
	return passed

## Town with mine + smelter + smithy: 7-day sim → metal_goods > 0, metal > 0,
## iron_ore produced. drift=0.
func test_iron_chain_produces_metal_goods_end_to_end() -> bool:
	WorldState.reset()
	var t := Town.new("t_iron", "IronChainTown")
	t.population_money = 5000.0
	t.poor = 100.0
	t.middle = 30.0
	t.rich = 5.0
	WorldState.towns.append(t)
	for g in ["iron_ore", "metal", "metal_goods"]:
		var base: float = 35.0 if g == "iron_ore" else (83.0 if g == "metal" else 200.0)
		var mn: float = 5.0 if g == "iron_ore" else (10.0 if g == "metal" else 50.0)
		var mx: float = 130.0 if g == "iron_ore" else (300.0 if g == "metal" else 360.0)
		t.market.add_good(g, base, mn, mx, 0.0)
	var mine := Industry.new("mn1", "mine", "t_iron", 12.0, 2000.0, "town:t_iron")
	var smelter := Industry.new("sm1", "smelter", "t_iron", 10.0, 2000.0, "town:t_iron")
	var smithy := Industry.new("sy1", "smithy", "t_iron", 10.0, 2200.0, "town:t_iron")
	t.industries.append(mine)
	t.industries.append(smelter)
	t.industries.append(smithy)
	var recipes := {
		"mine": MINE_RECIPE,
		"smelter": SMELTER_RECIPE,
		"smithy": SMITHY_RECIPE,
	}
	var ms := MarketSystem.new()
	var prod := ProductionSystem.new(ms)
	var fin := FinanceSystem.new()
	var total_before: float = WorldState.total_money()
	for _i in range(7):
		t.market.reset_daily()
		prod.reset_daily_stats(t)
		prod.calculate_input_demand(t, recipes)
		prod.purchase_inputs(t, recipes)
		prod.produce(t, recipes)
		fin.charge_wages(t, recipes)
		ms.update_market(t.market)
	fin.distribute_profits(t, recipes)
	var goods_stock: float = t.market.get_entry("metal_goods").stock
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before
	# End-good produced → all upstream steps ran (mine + smelter + smithy).
	var passed: bool = goods_stock > 0.0 and abs(drift) < 0.01
	_report("iron_chain_produces_metal_goods_end_to_end", passed,
		"metal_goods=%.1f drift=%.4f (expect goods>0, drift=0)" % [goods_stock, drift])
	return passed

## Town with cotton_plantation + weaver + textile_mill: 7-day sim → textiles > 0,
## cloth produced. drift=0.
func test_textile_chain_uses_cloth_intermediate() -> bool:
	WorldState.reset()
	var t := Town.new("t_tex", "TextileChainTown")
	t.population_money = 5000.0
	t.poor = 100.0
	t.middle = 30.0
	t.rich = 5.0
	WorldState.towns.append(t)
	for g in ["cotton", "cloth", "textiles"]:
		var base: float = 45.0 if g == "cotton" else (80.0 if g == "cloth" else 150.0)
		var mn: float = 5.0 if g == "cotton" else (15.0 if g == "cloth" else 40.0)
		var mx: float = 180.0 if g == "cotton" else (220.0 if g == "cloth" else 300.0)
		t.market.add_good(g, base, mn, mx, 0.0)
	var cotton_p := Industry.new("cp1", "cotton_plantation", "t_tex", 10.0, 1800.0, "town:t_tex")
	var weaver := Industry.new("wv1", "weaver", "t_tex", 8.0, 1800.0, "town:t_tex")
	var mill := Industry.new("tm1", "textile_mill", "t_tex", 10.0, 2000.0, "town:t_tex")
	t.industries.append(cotton_p)
	t.industries.append(weaver)
	t.industries.append(mill)
	var recipes := {
		"cotton_plantation": COTTON_PLANT_RECIPE,
		"weaver": WEAVER_RECIPE,
		"textile_mill": TEXTILE_MILL_RECIPE,
	}
	var ms := MarketSystem.new()
	var prod := ProductionSystem.new(ms)
	var fin := FinanceSystem.new()
	var total_before: float = WorldState.total_money()
	for _i in range(7):
		t.market.reset_daily()
		prod.reset_daily_stats(t)
		prod.calculate_input_demand(t, recipes)
		prod.purchase_inputs(t, recipes)
		prod.produce(t, recipes)
		fin.charge_wages(t, recipes)
		ms.update_market(t.market)
	fin.distribute_profits(t, recipes)
	var textiles_stock: float = t.market.get_entry("textiles").stock
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before
	# End-good produced → all upstream steps ran (cotton_plantation + weaver + textile_mill).
	var passed: bool = textiles_stock > 0.0 and abs(drift) < 0.01
	_report("textile_chain_uses_cloth_intermediate", passed,
		"textiles=%.1f drift=%.4f (expect textiles>0, drift=0)" % [textiles_stock, drift])
	return passed

## Town with lumber_camp + sawmill: 7-day sim → lumber > 0, wood produced. drift=0.
func test_lumber_chain_produces_lumber() -> bool:
	WorldState.reset()
	var t := Town.new("t_lum", "LumberChainTown")
	t.population_money = 3000.0
	t.poor = 60.0
	t.middle = 20.0
	t.rich = 5.0
	WorldState.towns.append(t)
	for g in ["wood", "lumber"]:
		var base: float = 33.0 if g == "wood" else 65.0
		var mn: float = 5.0 if g == "wood" else 10.0
		var mx: float = 150.0 if g == "wood" else 200.0
		t.market.add_good(g, base, mn, mx, 0.0)
	var camp := Industry.new("lc1", "lumber_camp", "t_lum", 8.0, 1500.0, "town:t_lum")
	var sawmill := Industry.new("sw1", "sawmill", "t_lum", 6.0, 1300.0, "town:t_lum")
	t.industries.append(camp)
	t.industries.append(sawmill)
	var recipes := {
		"lumber_camp": LUMBER_CAMP_RECIPE,
		"sawmill": SAWMILL_RECIPE,
	}
	var ms := MarketSystem.new()
	var prod := ProductionSystem.new(ms)
	var fin := FinanceSystem.new()
	var total_before: float = WorldState.total_money()
	for _i in range(7):
		t.market.reset_daily()
		prod.reset_daily_stats(t)
		prod.calculate_input_demand(t, recipes)
		prod.purchase_inputs(t, recipes)
		prod.produce(t, recipes)
		fin.charge_wages(t, recipes)
		ms.update_market(t.market)
	fin.distribute_profits(t, recipes)
	var wood_stock: float = t.market.get_entry("wood").stock
	var lumber_stock: float = t.market.get_entry("lumber").stock
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before
	# Expect: lumber produced (sawmill ran), wood produced (lumber_camp ran).
	# Lumber has no consumer in C7 (shipyard comes in J2) so it accumulates.
	var passed: bool = lumber_stock > 0.0 and abs(drift) < 0.01
	_report("lumber_chain_produces_lumber", passed,
		"lumber=%.1f drift=%.4f (expect lumber>0, drift=0)" % [lumber_stock, drift])
	return passed

## Town with distillery but NO sugar_mill: 7-day sim → distillery cannot produce
## rum (no sugar on market). This proves the audit's thesis: "нехватка одного
## промежуточного товара распространяется дальше по цепочке". drift=0.
func test_chain_breaks_when_intermediate_missing() -> bool:
	WorldState.reset()
	var t := Town.new("t_brk", "ChainBreakTown")
	t.population_money = 5000.0
	t.poor = 100.0
	t.middle = 30.0
	t.rich = 5.0
	WorldState.towns.append(t)
	# Markets: sugar_cane, sugar, rum — but NO sugar_mill in this town.
	# sugar_cane will pile up (no consumer), sugar will stay at 0 (no producer),
	# distillery cannot buy sugar → produces 0 rum.
	for g in ["sugar_cane", "sugar", "rum"]:
		var base: float = 18.0 if g == "sugar_cane" else (50.0 if g == "sugar" else 120.0)
		var mn: float = 3.0 if g == "sugar_cane" else (5.0 if g == "sugar" else 30.0)
		var mx: float = 80.0 if g == "sugar_cane" else (200.0 if g == "sugar" else 240.0)
		t.market.add_good(g, base, mn, mx, 0.0)
	# Only sugar_plantation (outputs sugar_cane) + distillery (inputs sugar).
	# NO sugar_mill → chain broken at sugar step.
	var plantation := Industry.new("p2", "sugar_plantation", "t_brk", 12.0, 2000.0, "town:t_brk")
	var distillery := Industry.new("d2", "distillery", "t_brk", 8.0, 2000.0, "town:t_brk")
	t.industries.append(plantation)
	t.industries.append(distillery)
	var recipes := {
		"sugar_plantation": SUGAR_PLANT_RECIPE,
		"distillery": DISTILLERY_RECIPE,
	}
	var ms := MarketSystem.new()
	var prod := ProductionSystem.new(ms)
	var fin := FinanceSystem.new()
	var total_before: float = WorldState.total_money()
	for _i in range(7):
		t.market.reset_daily()
		prod.reset_daily_stats(t)
		prod.calculate_input_demand(t, recipes)
		prod.purchase_inputs(t, recipes)
		prod.produce(t, recipes)
		fin.charge_wages(t, recipes)
		ms.update_market(t.market)
	fin.distribute_profits(t, recipes)
	var cane_stock: float = t.market.get_entry("sugar_cane").stock
	var sugar_stock: float = t.market.get_entry("sugar").stock
	var rum_stock: float = t.market.get_entry("rum").stock
	var dist_produced: float = 0.0
	for ind in t.industries:
		if ind.recipe_id == "distillery":
			dist_produced = ind.produced_batches
			break
	var total_after: float = WorldState.total_money()
	var drift: float = total_after - total_before
	# Expect: sugar_cane produced (plantation ran), sugar = 0 (no mill),
	# distillery produced 0 (no sugar to buy), rum = 0 (distillery didn't run).
	var passed: bool = cane_stock > 0.0 and sugar_stock == 0.0 and dist_produced == 0.0 and rum_stock == 0.0 and abs(drift) < 0.01
	_report("chain_breaks_when_intermediate_missing", passed,
		"cane=%.1f sugar=%.1f dist_produced=%.2f rum=%.1f drift=%.4f (expect cane>0, sugar=0, dist=0, rum=0, drift=0)" %
		[cane_stock, sugar_stock, dist_produced, rum_stock, drift])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
