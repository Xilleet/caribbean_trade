extends Node

## Stage-5 tests for autonomous AI trading companies. Run directly (prints
## PASS/FAIL and quits with an exit code) OR via GUT:
##   godot --headless --path <project> tests/test_ai_traders.tscn
##
## Covers the Stage-5 quality criteria the concept (§3.2, §17) demands:
##  - AI companies spawn with a ship, a route and auto_trade ON (structure);
##  - they trade through the SAME MarketSystem / TradeSystem as the player, so
##    total money is still conserved (AI never creates cash or goods);
##  - the player ship is still identifiable and controllable amid the rivals;
##  - the world actually moves — prices leave their day-0 values, proving the
##    rivals perturb the economy rather than being inert decorations.
##
## NOTE: in these tests no Main node runs, so the player ship keeps the Ship
## default auto_trade = true and auto-trades its route exactly like an AI ship.
## That is intentional — it isolates the economy from the windowed UI control
## layer, which has its own (manual) tests in test_manual_trade.gd.

func _ready() -> void:
	var ok := true
	ok = ok and test_ai_companies_spawn()
	ok = ok and test_ai_trades_and_conserves_30d()
	ok = ok and test_player_and_ai_share_market_14d()
	ok = ok and test_map_draws_all_ships()
	print("\n=== %s ===" % ("ALL STAGE-5 TESTS PASSED" if ok else "SOME STAGE-5 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_ai_companies_spawn() -> bool:
	WorldState.build_world()
	var ai_count: int = 0
	for c in WorldState.companies:
		if c.is_ai:
			ai_count += 1
	var struct_ok: bool = true
	var detail_parts := PackedStringArray()
	for c in WorldState.companies:
		if not c.is_ai:
			continue
		if c.ship_ids.size() != 1:
			struct_ok = false
			detail_parts.append("%s: ship_ids=%d" % [c.name, c.ship_ids.size()])
			continue
		var s: Ship = WorldState.get_ship(c.ship_ids[0])
		if s == null:
			struct_ok = false
			detail_parts.append("%s: ship missing" % c.name)
			continue
		var bad: bool = s.owner_id != c.id or not s.auto_trade or s.route_id == "" \
			or s.state != "docked" or s.current_town_id == ""
		if bad:
			struct_ok = false
			detail_parts.append("%s: owner=%s auto=%s route=%s state=%s home=%s" %
					[c.name, s.owner_id, s.auto_trade, s.route_id, s.state, s.current_town_id])
	var p: Ship = WorldState.get_player_ship()
	var player_ok: bool = p != null and p.owner_id == "player"
	var passed: bool = ai_count >= 3 and struct_ok and player_ok
	_report("ai_companies_spawn", passed,
			"ai_count=%d struct_ok=%s player_ok=%s %s" %
			[ai_count, struct_ok, player_ok,
			 ", ".join(detail_parts) if not struct_ok else "all ships well-formed"])
	return passed

func test_ai_trades_and_conserves_30d() -> bool:
	WorldState.build_world()
	var total_start: float = WorldState.total_money()
	# Day-0 prices: markets are freshly built, no tick has run, so current_price
	# == base_price. After 30 days the economy (production + consumption + the
	# AI/player trades) must have moved at least one of them.
	var gib_sugar_d0: float = WorldState.get_town("gibara").market.get_entry("sugar").current_price
	var pmetal_d0: float = WorldState.get_town("port_royal").market.get_entry("metal").current_price
	var engine := SimulationEngine.new()
	engine.run_days(30)
	var drift: float = WorldState.total_money() - total_start
	# At least one AI ship executed a real trade (bought or sold something).
	var any_ai_traded: bool = false
	for c in WorldState.companies:
		if not c.is_ai:
			continue
		for sid in c.ship_ids:
			var s: Ship = WorldState.get_ship(sid)
			if s != null and (s.lifetime_sell_revenue > 0.0 or s.lifetime_buy_cost > 0.0):
				any_ai_traded = true
	var gib_sugar: float = WorldState.get_town("gibara").market.get_entry("sugar").current_price
	var pmetal: float = WorldState.get_town("port_royal").market.get_entry("metal").current_price
	var price_moved: bool = abs(gib_sugar - gib_sugar_d0) > 0.01 or abs(pmetal - pmetal_d0) > 0.01
	var passed: bool = any_ai_traded and abs(drift) < 1.0 and price_moved
	_report("ai_trades_and_conserves_30d", passed,
			"drift=%.4f ai_traded=%s price_moved=%s (gib_sugar %.1f->%.1f, pmetal %.1f->%.1f)" %
			[drift, any_ai_traded, price_moved, gib_sugar_d0, gib_sugar, pmetal_d0, pmetal])
	return passed

func test_player_and_ai_share_market_14d() -> bool:
	WorldState.build_world()
	var total_start: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(14)
	var drift: float = WorldState.total_money() - total_start
	# Both the player ship AND at least one AI ship must have traded through the
	# same market — the player is one of several participants, not the only one.
	var p: Ship = WorldState.get_player_ship()
	var player_traded: bool = p != null and (p.lifetime_buy_cost > 0.0 or p.lifetime_sell_revenue > 0.0)
	var any_ai_traded: bool = false
	for c in WorldState.companies:
		if not c.is_ai:
			continue
		for sid in c.ship_ids:
			var s: Ship = WorldState.get_ship(sid)
			if s != null and (s.lifetime_sell_revenue > 0.0 or s.lifetime_buy_cost > 0.0):
				any_ai_traded = true
	var passed: bool = player_traded and any_ai_traded and abs(drift) < 1.0
	_report("player_and_ai_share_market_14d", passed,
			"player_traded=%s ai_traded=%s drift=%.4f" %
			[player_traded, any_ai_traded, drift])
	return passed

func test_map_draws_all_ships() -> bool:
	# Headless render check: instantiate the map, rebuild its grid from the
	# freshly built world, and confirm the player ship AND the AI ships all
	# appear. build_world docks everyone at a home port, so the grid should hold
	# one "B" (player) and one "A" per AI company. This covers the Stage-5 map
	# change (draw every ship, not just ships[0]) without needing a display.
	WorldState.build_world()
	var m := AsciiMap.new()
	m._rebuild()
	var grid_str: String = ""
	for row in m._grid:
		grid_str += String(row)
	var has_player: bool = grid_str.find("B") >= 0 or grid_str.find("b") >= 0
	var n_ai_glyphs: int = grid_str.count("A") + grid_str.count("a")
	var p: Ship = WorldState.get_player_ship()
	var p_docked: bool = p != null and p.state == "docked"
	var passed: bool = has_player and n_ai_glyphs >= 3 and p_docked
	_report("map_draws_all_ships", passed,
			"player_glyph=%s ai_glyphs=%d player_docked=%s" %
			[has_player, n_ai_glyphs, p_docked])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
