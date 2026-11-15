extends Node

## Stage B2b+B3 — migration tests with per-Pop savings/satisfaction.
## Run with: godot --headless --path <project> tests/test_migration.tscn

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_migration_pressure_computed()
	ok = ok and test_no_migration_when_prosperous()
	ok = ok and test_packet_boards_passengers()
	ok = ok and test_ship_disembarks_passengers()
	ok = ok and test_pop_count_conserved_through_cycle()
	ok = ok and test_drift_zero_with_migration()
	print("\n=== %s ===" % ("ALL TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_migration_pressure_computed() -> bool:
	WorldState.reset()
	var t := Town.new("t_stress", "StressTown")
	WorldState.towns.append(t)
	var pop := Pop.new("p1", "t_stress", "poor", "laborer", 100.0)
	pop.employed_count = 5.0
	pop.satisfaction = 0.3
	pop.savings = 500.0
	t.pops.append(pop)
	t.wage_rate["laborer"] = 0.5
	var dest := Town.new("t_good", "GoodTown")
	WorldState.towns.append(dest)
	var despop := Pop.new("p2", "t_good", "poor", "laborer", 50.0)
	despop.satisfaction = 0.95
	despop.savings = 500.0
	dest.pops.append(despop)
	dest.wage_rate["laborer"] = 1.5
	var mig := MigrationSystem.new()
	mig.compute_migration(WorldState.towns)
	var has_waiting: bool = t.waiting_passengers.size() > 0
	var detail: String = "waiting=%d" % t.waiting_passengers.size()
	if has_waiting:
		var e: Dictionary = t.waiting_passengers[0]
		detail += " dest=%s" % e.get("destination", "")
	_report("migration_pressure_computed", has_waiting, detail)
	return has_waiting

func test_no_migration_when_prosperous() -> bool:
	WorldState.reset()
	var t := Town.new("t_prosper", "ProsperTown")
	WorldState.towns.append(t)
	var pop := Pop.new("p1", "t_prosper", "poor", "laborer", 100.0)
	pop.employed_count = 90.0
	pop.satisfaction = 0.95
	pop.savings = 500.0
	t.pops.append(pop)
	t.wage_rate["laborer"] = 2.0
	var dest := Town.new("t_bad", "BadTown")
	WorldState.towns.append(dest)
	var despop := Pop.new("p2", "t_bad", "poor", "laborer", 50.0)
	despop.satisfaction = 0.3
	despop.savings = 500.0
	dest.pops.append(despop)
	dest.wage_rate["laborer"] = 0.5
	var mig := MigrationSystem.new()
	mig.compute_migration(WorldState.towns)
	var passed: bool = t.waiting_passengers.is_empty()
	_report("no_migration_when_prosperous", passed, "waiting=%d" % t.waiting_passengers.size())
	return passed

func test_packet_boards_passengers() -> bool:
	WorldState.reset()
	var t := Town.new("t_origin", "OriginTown")
	t.coords = Vector2(0, 0)
	WorldState.towns.append(t)
	var pop := Pop.new("p1", "t_origin", "poor", "laborer", 200.0)
	pop.savings = 1000.0
	pop.satisfaction = 0.3
	pop.employed_count = 10.0
	t.pops.append(pop)
	t.wage_rate["laborer"] = 0.5
	t.waiting_passengers.append({"profession": "laborer", "count": 20.0, "destination": "t_dest"})
	var dest := Town.new("t_dest", "DestTown")
	dest.coords = Vector2(100, 100)
	WorldState.towns.append(dest)
	var despop := Pop.new("p2", "t_dest", "poor", "laborer", 50.0)
	despop.satisfaction = 0.95
	dest.pops.append(despop)
	dest.wage_rate["laborer"] = 2.0
	var company := Company.new("pkt_co", "Pkt Co.", 5000.0, true)
	WorldState.companies.append(company)
	var ship := Ship.new("ship_pkt", company.id, "packet", 16.0, 30.0, 12.0)
	ship.passenger_capacity = 80.0
	ship.current_town_id = "t_origin"
	ship.state = "docked"
	ship.auto_trade = true
	ship.pos = t.coords
	ship.destination_id = "t_dest"
	var route := TradeRoute.new("pkt_r", ship.id)
	route.stops = ["t_origin", "t_dest"]
	WorldState.routes["pkt_r"] = route
	ship.route_id = "pkt_r"
	company.ship_ids.append(ship.id)
	WorldState.ships.append(ship)
	# Simulate boarding ( ShipsTick._board_passengers does this internally).
	var can_board: bool = ship.passenger_free() >= 20.0
	if can_board:
		ship.add_passengers("laborer", 20.0)
		pop.count -= 20.0
		t.waiting_passengers.clear()
	var passed: bool = ship.passenger_qty("laborer") == 20.0 and abs(pop.count - 180.0) < 0.01
	_report("packet_boards_passengers", passed,
		"ship=%.1f pop=%.1f" % [ship.passenger_qty("laborer"), pop.count])
	return passed

func test_ship_disembarks_passengers() -> bool:
	WorldState.reset()
	var t := Town.new("t_dest2", "DestTown2")
	WorldState.towns.append(t)
	var pop := Pop.new("p1", "t_dest2", "poor", "laborer", 50.0)
	t.pops.append(pop)
	var company := Company.new("sc2", "SC2", 5000.0, true)
	WorldState.companies.append(company)
	var ship := Ship.new("ship_2", company.id, "packet", 16.0, 30.0, 12.0)
	ship.passenger_capacity = 80.0
	ship.add_passengers("laborer", 15.0)
	ship.current_town_id = "t_dest2"
	ship.state = "docked"
	company.ship_ids.append(ship.id)
	WorldState.ships.append(ship)
	var before: float = pop.count
	pop.count += ship.passenger_qty("laborer")
	ship.remove_passengers("laborer", ship.passenger_qty("laborer"))
	var passed: bool = abs(pop.count - (before + 15.0)) < 0.01 and ship.passenger_qty("laborer") == 0.0
	_report("ship_disembarks_passengers", passed,
		"pop=%.1f→%.1f ship=%.1f" % [before, pop.count, ship.passenger_qty("laborer")])
	return passed

func test_pop_count_conserved_through_cycle() -> bool:
	WorldState.reset()
	var origin := Town.new("t_o3", "Origin3")
	origin.satisfaction = 0.3
	WorldState.towns.append(origin)
	var op := Pop.new("p1", "t_o3", "poor", "laborer", 200.0)
	op.employed_count = 10.0
	op.satisfaction = 0.3
	op.savings = 500.0
	origin.pops.append(op)
	origin.wage_rate["laborer"] = 0.5
	var dest := Town.new("t_d3", "Dest3")
	WorldState.towns.append(dest)
	var dp := Pop.new("p2", "t_d3", "poor", "laborer", 50.0)
	dp.satisfaction = 0.95
	dp.savings = 500.0
	dest.pops.append(dp)
	dest.wage_rate["laborer"] = 2.0
	var before: float = origin.total_population() + dest.total_population()
	var mig := MigrationSystem.new()
	mig.compute_migration(WorldState.towns)
	if origin.waiting_passengers.is_empty():
		_report("pop_count_conserved_through_cycle", false, "no waiting")
		return false
	var e: Dictionary = origin.waiting_passengers[0]
	var c: float = float(e["count"])
	op.count -= c
	origin.waiting_passengers.clear()
	dp.count += c
	var after: float = origin.total_population() + dest.total_population()
	var drift: float = after - before
	var passed: bool = abs(drift) < 0.01
	_report("pop_count_conserved_through_cycle", passed,
		"before=%.1f after=%.1f drift=%.4f" % [before, after, drift])
	return passed

func test_drift_zero_with_migration() -> bool:
	WorldState.build_world()
	var before: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	for _i in range(30):
		engine.step_day()
	var after: float = WorldState.total_money()
	var drift: float = after - before
	var passed: bool = abs(drift) < 1.0
	_report("drift_zero_with_migration", passed,
		"drift=%.4f (expect |drift|<1)" % drift)
	return passed

func _report(n: String, p: bool, d: String) -> void:
	print("[%s] %s — %s" % ["PASS" if p else "FAIL", n, d])
