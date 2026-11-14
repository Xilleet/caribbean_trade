extends Node

## Stage-4 tests for player-driven (manual) trades. Run directly (prints
## PASS/FAIL and quits with an exit code) OR via GUT:
##   godot --headless --path <project> tests/test_manual_trade.tscn
##
## Covers the Stage-4 quality criteria:
##  - a manual buy moves real money (company -> market.fund) and real stock,
##    respects hold space and the buyer's wallet, and conserves total money;
##  - a manual sell is capped by what the ship actually carries;
##  - a buy+sell roundtrip at the same day's price returns the wallet to start.

func _ready() -> void:
	var ok := true
	ok = ok and test_manual_buy_moves_money_and_stock()
	ok = ok and test_manual_sell_capped_by_cargo()
	ok = ok and test_buy_capped_by_cargo_space()
	ok = ok and test_buy_capped_by_money()
	ok = ok and test_roundtrip_conserves_money()
	print("\n=== %s ===" % ("ALL STAGE-4 TESTS PASSED" if ok else "SOME STAGE-4 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func _fresh_ship_company_town() -> Dictionary:
	# build_world resets everything; give the player ship a clean hold and a
	# known wallet, and hand back references for the test. gibara starts with
	# sugar stock 50 at base price 50 (no daily tick has run yet, so
	# current_price == base_price — the run is deterministic).
	WorldState.build_world()
	var ship: Ship = WorldState.ships[0]
	ship.cargo.clear()
	ship.cargo_used = 0.0
	var company: Company = WorldState.get_company(ship.owner_id)
	company.money = 5000.0
	var town: Town = WorldState.get_town("gibara")
	return {"ship": ship, "company": company, "town": town}

func test_manual_buy_moves_money_and_stock() -> bool:
	var ctx: Dictionary = _fresh_ship_company_town()
	var ship: Ship = ctx["ship"]
	var company: Company = ctx["company"]
	var town: Town = ctx["town"]
	var trade := TradeSystem.new(MarketSystem.new())
	var stock_before: float = town.market.get_entry("sugar").stock
	var money_before: float = company.money
	var total_before: float = WorldState.total_money()
	var res: Dictionary = trade.manual_buy(ship, company, town, "sugar", 10.0)
	var price: float = float(res["price"])
	# Stage A2: customs tax now deducted from company.money after cost.
	# cost = 10 * avg_price; tax = cost * state.tax_rate. gibara is spain (0.05).
	var st: State = WorldState.get_state(town.state_id)
	var tax_rate: float = st.tax_rate if st != null else 0.0
	var expected_money: float = money_before - 10.0 * price * (1.0 + tax_rate)
	var passed: bool = abs(float(res["qty"]) - 10.0) < 0.001 \
		and abs(company.money - expected_money) < 0.05 \
		and abs(town.market.get_entry("sugar").stock - (stock_before - 10.0)) < 0.001 \
		and abs(ship.cargo_qty("sugar") - 10.0) < 0.001 \
		and abs(WorldState.total_money() - total_before) < 0.01
	_report("manual_buy_moves_money_and_stock", passed,
			"qty=%.2f money=%.1f->%.1f (expect %.1f) stock=%.1f->%.1f hold=%.1f drift=%.4f" %
			[float(res["qty"]), money_before, company.money, expected_money, stock_before,
			 town.market.get_entry("sugar").stock, ship.cargo_qty("sugar"),
			 WorldState.total_money() - total_before])
	return passed

func test_manual_sell_capped_by_cargo() -> bool:
	var ctx: Dictionary = _fresh_ship_company_town()
	var ship: Ship = ctx["ship"]
	var company: Company = ctx["company"]
	var town: Town = ctx["town"]
	ship.add_cargo("sugar", 5.0)   # only 5 aboard
	var trade := TradeSystem.new(MarketSystem.new())
	var res: Dictionary = trade.manual_sell(ship, company, town, "sugar", 100.0)
	var passed: bool = abs(float(res["qty"]) - 5.0) < 0.001 \
		and ship.cargo_qty("sugar") < 0.001 \
		and ship.cargo_used < 0.001
	_report("manual_sell_capped_by_cargo", passed,
			"asked=100 sold=%.2f hold_now=%.1f" % [float(res["qty"]), ship.cargo_qty("sugar")])
	return passed

func test_buy_capped_by_cargo_space() -> bool:
	var ctx: Dictionary = _fresh_ship_company_town()
	var ship: Ship = ctx["ship"]
	var company: Company = ctx["company"]
	var town: Town = ctx["town"]
	# Fill the hold leaving exactly 5 free (capacity-agnostic — the brigantine's
	# real capacity comes from ships.json, so derive it from the ship itself).
	ship.add_cargo("sugar", ship.cargo_capacity - 5.0)
	var trade := TradeSystem.new(MarketSystem.new())
	var res: Dictionary = trade.manual_buy(ship, company, town, "sugar", 10.0)
	var passed: bool = abs(float(res["qty"]) - 5.0) < 0.001 \
		and abs(ship.cargo_used - ship.cargo_capacity) < 0.001
	_report("buy_capped_by_cargo_space", passed,
			"asked=10 free=5 bought=%.2f cargo_used=%.1f/%.1f" %
			[float(res["qty"]), ship.cargo_used, ship.cargo_capacity])
	return passed

func test_buy_capped_by_money() -> bool:
	var ctx: Dictionary = _fresh_ship_company_town()
	var ship: Ship = ctx["ship"]
	var company: Company = ctx["company"]
	var town: Town = ctx["town"]
	company.money = 100.0
	# Push sugar into MILD shortage (stock 8 vs default target 10)
	# so tranche prices rise during the buy — money becomes the binding
	# constraint AND qty < flat-baseline 100/50=2 (the old expectation).
	town.market.get_entry("sugar").stock = 8.0
	var trade := TradeSystem.new(MarketSystem.new())
	var res: Dictionary = trade.manual_buy(ship, company, town, "sugar", 10.0)
	# First tranche: price = 50*exp(1.5*(10-8)/10) ≈ 67.6. Affordable: ~1.48.
	# Subsequent tranches pricier → qty < flat baseline 100/50=2. Money ~exhausted.
	var qty: float = float(res["qty"])
	var passed: bool = qty > 0.0 and qty < 2.0 and company.money < 5.0
	_report("buy_capped_by_money", passed,
			"money=100 avg_price=%.1f bought=%.3f money_left=%.2f (expect 0<qty<2, money<5)" %
			[float(res["price"]), qty, company.money])
	return passed

func test_roundtrip_conserves_money() -> bool:
	var ctx: Dictionary = _fresh_ship_company_town()
	var ship: Ship = ctx["ship"]
	var company: Company = ctx["company"]
	var town: Town = ctx["town"]
	var money_before: float = company.money
	var total_before: float = WorldState.total_money()
	# Stage A2: roundtrip loses 2*cost*tax_rate to state treasury (customs on
	# both buy and sell legs). Total_money conserved; company.money drops.
	var st: State = WorldState.get_state(town.state_id)
	var state_t_before: float = st.treasury if st != null else 0.0
	var trade := TradeSystem.new(MarketSystem.new())
	trade.manual_buy(ship, company, town, "sugar", 10.0)
	trade.manual_sell(ship, company, town, "sugar", 10.0)
	var tax_paid: float = (st.treasury if st != null else 0.0) - state_t_before
	var passed: bool = abs((company.money + tax_paid) - money_before) < 0.01 \
		and ship.cargo_qty("sugar") < 0.001 \
		and abs(WorldState.total_money() - total_before) < 0.01 \
		and tax_paid > 0.0   # customs actually collected
	_report("roundtrip_conserves_money", passed,
			"money=%.1f->%.1f tax_paid=%.2f hold=%.1f drift=%.4f" %
			[money_before, company.money, tax_paid, ship.cargo_qty("sugar"),
			 WorldState.total_money() - total_before])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
