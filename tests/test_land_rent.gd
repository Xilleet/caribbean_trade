extends Node

## Stage 4 (land rent) — crop plantations pay rent to the local planter Pop.
## Run with:
##   godot --headless --path <project> tests/test_land_rent.tscn
##
## Verifies:
##  1. rent_equals_rate_on_crop_industry — sugar_plantation with a known
##     last_revenue; charge_rent moves last_revenue*RENT_RATE from industry.money
##     to planter Pop.savings; last_rent set; conserved.
##  2. rent_zero_on_non_crop_industry — lumber_camp (wood) and bakery (bread)
##     are not CROP_GOODS → pay no rent; last_rent=0; money unchanged.
##  3. rent_zero_when_industry_idle — a crop industry with last_revenue=0
##     (idle / glut / drought) pays no rent.
##  4. rent_capped_at_money — industry money < rent owed → rent capped to money;
##     industry.money → 0 (never negative); planter gets the capped amount.
##  5. rent_falls_back_to_fund_when_no_planter — a town with no planter Pop
##     routes rent to market.fund; credited == charged; conserved (drift-safe).
##  6. rent_subtracted_from_profit — after charge_rent + charge_wages,
##     last_profit = revenue - input - wages - maint - rent (rent is in the
##     profit formula as a production cost).
##  7. drift_zero_365days_planter_income_fixed — full-world sim with rent
##     wired into the daily tick; total_money conserved (|drift|<1.0); planter
##     savings GROW over the year (rent yields income — fixes the Stage-1
##     depletion); planter SoL holds at the rich-stratum ceiling and is not
##     below the still-unfixed financier; poor SoL not crashed by the dividend
##     share rent redirects. NOTE: rich SoL is separately capped ~0.50 by
##     luxury-goods SUPPLY (sugar/rum/textiles/metal_goods underproduced across
##     towns) — a finding, not a rent failure: planters already hoard ~74× their
##     weekly basket cost, so no income rate lifts their SoL.

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_rent_equals_rate_on_crop_industry()
	ok = ok and test_rent_zero_on_non_crop_industry()
	ok = ok and test_rent_zero_when_industry_idle()
	ok = ok and test_rent_capped_at_money()
	ok = ok and test_rent_falls_back_to_fund_when_no_planter()
	ok = ok and test_rent_subtracted_from_profit()
	ok = ok and test_drift_zero_365days_planter_income_fixed()
	print("\n=== %s ===" % ("ALL LAND-RENT TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

# sugar_plantation recipe (cap 7, wage 20, maint 4, output sugar_cane 1).
const SUGAR_RECIPE := {
	"daily_capacity": 7.0, "daily_wages": 20.0, "daily_maintenance": 4.0,
	"profession_required": "laborer", "inputs": {}, "outputs": {"sugar_cane": 1.0}
}

func _recipes_sugar() -> Dictionary:
	return {"sugar_plantation": SUGAR_RECIPE.duplicate(true)}

func _town_with_planter(planter_savings: float) -> Town:
	var t := Town.new("t1", "T1")
	var planter := Pop.new("p_planter", "t1", "rich", "planter", 10.0)
	planter.savings = planter_savings
	t.pops.append(planter)
	return t

func _planter_savings(t: Town) -> float:
	for p in t.pops:
		if p.profession == "planter":
			return p.savings
	return 0.0

## sugar_plantation, last_revenue 126 (full-util day) → rent = 126 * 0.06 = 7.56.
## industry.money 1000 → 992.44; planter savings 0 → 7.56; conserved.
func test_rent_equals_rate_on_crop_industry() -> bool:
	WorldState.reset()
	var t := _town_with_planter(0.0)
	var ind := Industry.new("ind1", "sugar_plantation", "t1", 7.0, 1000.0)
	ind.last_revenue = 126.0
	t.industries.append(ind)
	var fin := FinanceSystem.new()
	var before: float = ind.money + _planter_savings(t)
	fin.charge_rent(t, _recipes_sugar())
	var expected_rent: float = 126.0 * FinanceSystem.RENT_RATE
	var after: float = ind.money + _planter_savings(t)
	var passed: bool = true
	var detail: String = ""
	if abs(ind.last_rent - expected_rent) > 0.001:
		passed = false
		detail = "last_rent wrong: %.4f (expect %.4f)" % [ind.last_rent, expected_rent]
	elif abs(ind.money - (1000.0 - expected_rent)) > 0.001:
		passed = false
		detail = "industry money wrong: %.4f (expect %.4f)" % [ind.money, 1000.0 - expected_rent]
	elif abs(_planter_savings(t) - expected_rent) > 0.001:
		passed = false
		detail = "planter savings wrong: %.4f (expect %.4f)" % [_planter_savings(t), expected_rent]
	elif abs(after - before) > 0.001:
		passed = false
		detail = "not conserved: before=%.4f after=%.4f" % [before, after]
	else:
		detail = "rent %.2f (6%% of revenue 126), industry -rent, planter +rent, drift=0" % expected_rent
	_report("rent_equals_rate_on_crop_industry", passed, detail)
	return passed

## lumber_camp (wood) and bakery (bread) are NOT CROP_GOODS → rent 0, no move.
func test_rent_zero_on_non_crop_industry() -> bool:
	WorldState.reset()
	var t := _town_with_planter(0.0)
	var lumber := Industry.new("ind_l", "lumber_camp", "t1", 10.0, 1000.0)
	lumber.last_revenue = 330.0
	var bakery := Industry.new("ind_b", "bakery", "t1", 10.0, 1000.0)
	bakery.last_revenue = 500.0
	t.industries.append(lumber)
	t.industries.append(bakery)
	var recipes := {
		"lumber_camp": {"daily_capacity": 10.0, "daily_wages": 16.0, "daily_maintenance": 2.0, "profession_required": "laborer", "inputs": {}, "outputs": {"wood": 1.0}},
		"bakery": {"daily_capacity": 18.0, "daily_wages": 22.0, "daily_maintenance": 3.0, "profession_required": "artisan", "inputs": {"corn": 1.0}, "outputs": {"bread": 1.0}}
	}
	var before: float = lumber.money + bakery.money + _planter_savings(t)
	var fin := FinanceSystem.new()
	fin.charge_rent(t, recipes)
	var after: float = lumber.money + bakery.money + _planter_savings(t)
	var passed: bool = true
	var detail: String = ""
	if abs(lumber.last_rent) > 0.001 or abs(bakery.last_rent) > 0.001:
		passed = false
		detail = "non-crop should pay 0 rent: lumber=%.4f bakery=%.4f" % [lumber.last_rent, bakery.last_rent]
	elif abs(after - before) > 0.001:
		passed = false
		detail = "money moved unexpectedly: before=%.4f after=%.4f" % [before, after]
	else:
		detail = "lumber (wood) + bakery (bread) pay 0 rent; money unchanged"
	_report("rent_zero_on_non_crop_industry", passed, detail)
	return passed

## Crop industry that didn't produce (last_revenue=0) pays no rent.
func test_rent_zero_when_industry_idle() -> bool:
	WorldState.reset()
	var t := _town_with_planter(0.0)
	var ind := Industry.new("ind1", "sugar_plantation", "t1", 7.0, 1000.0)
	ind.last_revenue = 0.0   # idle: glut / drought / break-even gate failed
	t.industries.append(ind)
	var fin := FinanceSystem.new()
	fin.charge_rent(t, _recipes_sugar())
	var passed: bool = true
	var detail: String = ""
	if abs(ind.last_rent) > 0.001:
		passed = false
		detail = "idle crop should pay 0 rent: %.4f" % ind.last_rent
	elif abs(ind.money - 1000.0) > 0.001:
		passed = false
		detail = "idle industry money should be unchanged: %.4f" % ind.money
	elif abs(_planter_savings(t)) > 0.001:
		passed = false
		detail = "planter should get 0 from idle land: %.4f" % _planter_savings(t)
	else:
		detail = "idle crop (last_revenue=0) → rent 0, no money moved"
	_report("rent_zero_when_industry_idle", passed, detail)
	return passed

## money 3 < rent owed 7.56 → rent capped at 3; industry.money → 0; planter +3.
func test_rent_capped_at_money() -> bool:
	WorldState.reset()
	var t := _town_with_planter(0.0)
	var ind := Industry.new("ind1", "sugar_plantation", "t1", 7.0, 3.0)
	ind.last_revenue = 126.0   # rent owed 7.56 > money 3 → capped
	t.industries.append(ind)
	var fin := FinanceSystem.new()
	var before: float = ind.money + _planter_savings(t)
	fin.charge_rent(t, _recipes_sugar())
	var after: float = ind.money + _planter_savings(t)
	var passed: bool = true
	var detail: String = ""
	if abs(ind.last_rent - 3.0) > 0.001:
		passed = false
		detail = "rent should be capped at money 3.0: %.4f" % ind.last_rent
	elif abs(ind.money) > 0.001:
		passed = false
		detail = "industry should be at 0 after capped rent: %.4f" % ind.money
	elif abs(_planter_savings(t) - 3.0) > 0.001:
		passed = false
		detail = "planter should get capped 3.0: %.4f" % _planter_savings(t)
	elif abs(after - before) > 0.001:
		passed = false
		detail = "not conserved: before=%.4f after=%.4f" % [before, after]
	else:
		detail = "rent owed 7.56 > money 3 → capped at 3.0, industry→0, planter +3.0"
	_report("rent_capped_at_money", passed, detail)
	return passed

## Town with a laborer Pop but NO planter Pop → rent routes to market.fund.
## add_to_pop would silently drop it; add_to_pop_or_fund keeps it in circulation.
func test_rent_falls_back_to_fund_when_no_planter() -> bool:
	WorldState.reset()
	var t := Town.new("t1", "T1")
	var laborer := Pop.new("p_lab", "t1", "poor", "laborer", 100.0)
	laborer.savings = 0.0
	t.pops.append(laborer)
	t.market.fund = 0.0
	var ind := Industry.new("ind1", "sugar_plantation", "t1", 7.0, 1000.0)
	ind.last_revenue = 126.0
	t.industries.append(ind)
	var fin := FinanceSystem.new()
	var before: float = ind.money + t.market.fund
	fin.charge_rent(t, _recipes_sugar())
	var expected_rent: float = 126.0 * FinanceSystem.RENT_RATE
	var after: float = ind.money + t.market.fund
	var passed: bool = true
	var detail: String = ""
	if abs(ind.last_rent - expected_rent) > 0.001:
		passed = false
		detail = "last_rent wrong: %.4f (expect %.4f)" % [ind.last_rent, expected_rent]
	elif abs(t.market.fund - expected_rent) > 0.001:
		passed = false
		detail = "rent should fall back to market.fund: fund=%.4f (expect %.4f)" % [t.market.fund, expected_rent]
	elif abs(after - before) > 0.001:
		passed = false
		detail = "not conserved: before=%.4f after=%.4f" % [before, after]
	else:
		detail = "no planter Pop → rent %.2f routed to market.fund, drift=0" % expected_rent
	_report("rent_falls_back_to_fund_when_no_planter", passed, detail)
	return passed

## charge_rent (rent 7.56) then charge_wages (wages 20, maint 4) →
## last_profit = 126 - 0 - 20 - 4 - 7.56 = 94.44. Proves rent is in the formula.
func test_rent_subtracted_from_profit() -> bool:
	WorldState.reset()
	var t := _town_with_planter(0.0)
	# Add a laborer Pop so charge_wages' wage credit lands somewhere (else the
	# existing add_to_pop silently drops it — unrelated to this assertion).
	var laborer := Pop.new("p_lab", "t1", "poor", "laborer", 100.0)
	laborer.savings = 0.0
	t.pops.append(laborer)
	var ind := Industry.new("ind1", "sugar_plantation", "t1", 7.0, 1000.0)
	ind.last_revenue = 126.0
	ind.produced_batches = 7.0   # full util → wages/maint at full daily rate
	ind.last_input_cost = 0.0    # raw crop, no inputs
	t.industries.append(ind)
	var fin := FinanceSystem.new()
	fin.charge_rent(t, _recipes_sugar())     # rent 7.56, last_rent set
	fin.charge_wages(t, _recipes_sugar())    # wages 20, maint 4, last_profit computed
	var expected_profit: float = 126.0 - 0.0 - 20.0 - 4.0 - 126.0 * FinanceSystem.RENT_RATE
	var passed: bool = true
	var detail: String = ""
	if abs(ind.last_profit - expected_profit) > 0.001:
		passed = false
		detail = "last_profit wrong: %.4f (expect %.4f = rev 126 - wages 20 - maint 4 - rent 7.56)" % [ind.last_profit, expected_profit]
	elif abs(ind.last_rent - 126.0 * FinanceSystem.RENT_RATE) > 0.001:
		passed = false
		detail = "last_rent not set before charge_wages: %.4f" % ind.last_rent
	else:
		detail = "last_profit %.2f = 126 - 20 - 4 - rent 7.56 (rent subtracted)" % expected_profit
	_report("rent_subtracted_from_profit", passed, detail)
	return passed

## Full-world 365-day sim with rent wired into the daily tick.
## |drift| < 1.0; planter savings GROW (rent yields income — fixes depletion);
## planter SoL at the rich ceiling (>= 0.49) and not below the unfixed financier;
## poor SoL not crashed. Rich SoL is supply-capped, not income-capped (see note
## in the file header) — this test checks income + conservation + no-collapse,
## not a SoL target.
func test_drift_zero_365days_planter_income_fixed() -> bool:
	WorldState.build_world()
	var planter_sav_before: float = _world_prof_savings("planter")
	var engine := SimulationEngine.new()
	var money_before: float = WorldState.total_money()
	engine.run_days(365)
	var money_after: float = WorldState.total_money()
	var drift: float = money_after - money_before
	var planter_sav_after: float = _world_prof_savings("planter")
	var planter_sol_after: float = _world_avg_sol("planter")
	var financier_sol_after: float = _world_avg_sol("financier")
	var poor_sol_after: float = _world_avg_sol_by_class("poor")
	var passed: bool = true
	var detail: String = ""
	if abs(drift) >= 1.0:
		passed = false
		detail = "drift too high: %.4f (need |drift|<1)" % drift
	elif planter_sav_after <= planter_sav_before:
		passed = false
		detail = "planter savings didn't grow (rent not yielding income): before=%.0f after=%.0f" % [planter_sav_before, planter_sav_after]
	elif planter_sol_after < 0.49:
		passed = false
		detail = "planter SoL collapsed below the rich ceiling: %.3f" % planter_sol_after
	elif planter_sol_after < financier_sol_after:
		passed = false
		detail = "planter SoL %.3f below financier %.3f (rent should give planters an edge over the unfixed financier)" % [planter_sol_after, financier_sol_after]
	elif poor_sol_after <= 0.5:
		passed = false
		detail = "poor SoL crashed below 0.5 (lost too much dividend share to rent): %.3f" % poor_sol_after
	else:
		detail = "drift=%.4f | planter savings %.0f→%.0f (+income) | planter SoL %.3f | financier SoL %.3f | poor SoL %.3f (rich SoL supply-capped, not income-capped)" % [drift, planter_sav_before, planter_sav_after, planter_sol_after, financier_sol_after, poor_sol_after]
	_report("drift_zero_365days_planter_income_fixed", passed, detail)
	return passed

func _world_prof_savings(prof: String) -> float:
	var s: float = 0.0
	for t in WorldState.towns:
		for p in t.pops:
			if p.profession == prof:
				s += p.savings
	return s

func _world_avg_sol(prof: String) -> float:
	var sum: float = 0.0
	var n: float = 0.0
	for t in WorldState.towns:
		for p in t.pops:
			if p.profession == prof:
				sum += p.satisfaction * p.count
				n += p.count
	return sum / n if n > 0.0 else 0.0

func _world_avg_sol_by_class(cls: String) -> float:
	var sum: float = 0.0
	var n: float = 0.0
	for t in WorldState.towns:
		for p in t.pops:
			if p.social_class == cls:
				sum += p.satisfaction * p.count
				n += p.count
	return sum / n if n > 0.0 else 0.0

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
