extends Node

## Stage-6 tests for world events. Run directly (prints PASS/FAIL and quits with
## an exit code):
##   godot --headless --path <project> tests/test_events.tscn
##
## Covers the Stage-6 quality criteria (concept §3.4):
##  - events are DETERMINISTIC: the same seed reproduces the same event
##    sequence (separate event_rng stream, state-triggered famine);
##  - events never create or destroy money — drift stays 0 with events on;
##  - a drought actually cuts crop output (the modifier reaches ProductionSystem);
##  - a famine is a CONSEQUENCE of the simulation — it fires when a staple's
##    stock is below the trigger ratio, not on a random roll.
##
## NOTE: in these tests no Main node runs, so the player ship keeps auto_trade =
## true (the Ship default) and auto-trades its route like an AI ship. That
## isolates the economy + events from the windowed UI control layer.

func _ready() -> void:
	var ok := true
	ok = ok and test_events_deterministic()
	ok = ok and test_events_conserve_money_60d()
	ok = ok and test_drought_cuts_crop_output()
	ok = ok and test_famine_triggered_by_shortage()
	print("\n=== %s ===" % ("ALL STAGE-6 TESTS PASSED" if ok else "SOME STAGE-6 TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

func test_events_deterministic() -> bool:
	# Two fresh runs from build_world must produce the SAME event counts. event_rng
	# is re-seeded by build_world, so the rolls match; famine is state-driven and
	# the economy is deterministic, so its triggers match too.
	WorldState.build_world()
	var e1 := SimulationEngine.new()
	e1.run_days(30)
	var a: Dictionary = e1.event_system.fired_by_type.duplicate(true)
	var a_total: int = e1.event_system.fired_total
	WorldState.build_world()
	var e2 := SimulationEngine.new()
	e2.run_days(30)
	var b: Dictionary = e2.event_system.fired_by_type.duplicate(true)
	var b_total: int = e2.event_system.fired_total
	var same: bool = a_total == b_total and _dict_eq(a, b)
	var fired: bool = a_total > 0   # ~4 weekly rolls over 30 days -> something fires
	var passed: bool = same and fired
	_report("events_deterministic", passed,
			"run1=%d run2=%d (drought=%d storm=%d famine=%d) same=%s fired=%s" %
			[a_total, b_total, int(a.get("drought", 0)), int(a.get("storm", 0)),
			 int(a.get("famine", 0)), same, fired])
	return passed

func test_events_conserve_money_60d() -> bool:
	WorldState.build_world()
	var total0: float = WorldState.total_money()
	var engine := SimulationEngine.new()
	engine.run_days(60)
	var drift: float = WorldState.total_money() - total0
	var fired: int = engine.event_system.fired_total
	# Storm extra upkeep (company -> town.population_money), famine buys (pop ->
	# market.fund) and drought (no money moved) are all conservation-safe.
	var passed: bool = abs(drift) < 1.0 and fired > 0
	_report("events_conserve_money_60d", passed,
			"drift=%.4f events_fired=%d (need |drift|<1, fired>0)" % [drift, fired])
	return passed

func test_drought_cuts_crop_output() -> bool:
	WorldState.build_world()
	# Gibara has a corn_farm (raw crop, no inputs). Day 1 has no events yet (the
	# first weekly roll is at day 7), so produced_batches is the full capacity.
	var gib: Town = WorldState.get_town("gibara")
	var corn_farm: Industry = null
	for ind in gib.industries:
		if ind.recipe_id == "corn_farm":
			corn_farm = ind
			break
	if corn_farm == null:
		_report("drought_cuts_crop_output", false, "no corn_farm in gibara")
		return false
	var engine := SimulationEngine.new()
	engine.run_days(1)                       # baseline day, no events
	var baseline: float = corn_farm.produced_batches
	# Inject a drought on Gibara (magnitude 0.5 -> harvest halved) and run one day.
	var ev := EventSystem.ActiveEvent.new()
	ev.type = "drought"
	ev.scope = "town"
	ev.target_id = "gibara"
	ev.days_left = 3
	ev.magnitude = 0.5
	WorldState.active_events.append(ev)
	engine.run_days(1)
	var under_drought: float = corn_farm.produced_batches
	var ratio: float = under_drought / baseline if baseline > 0.0 else 1.0
	var passed: bool = baseline > 0.0 and under_drought > 0.0 and ratio <= 0.7
	_report("drought_cuts_crop_output", passed,
			"baseline=%.1f drought=%.1f ratio=%.2f (need baseline>0, ratio<=0.7)" %
			[baseline, under_drought, ratio])
	return passed

func test_famine_triggered_by_shortage() -> bool:
	# A famine must fire as a CONSEQUENCE of low stock, not a roll. Force a bread
	# shortage in populated Gibara and roll one week -> a famine on (gibara,bread)
	# appears with no probability involved.
	WorldState.build_world()
	var gib: Town = WorldState.get_town("gibara")
	var bread_e: Market.Entry = gib.market.get_entry("bread")
	bread_e.stock = 0.0
	var es := EventSystem.new(WorldState.event_rng, WorldState.events_db)
	es.roll_weekly()
	var found_gib_bread: bool = false
	for ev in WorldState.active_events:
		if ev.type == "famine" and ev.target_id == "gibara" and ev.good_id == "bread":
			found_gib_bread = true
	var n_famine: int = int(es.fired_by_type.get("famine", 0))
	var passed: bool = found_gib_bread and n_famine >= 1
	_report("famine_triggered_by_shortage", passed,
			"gibara_bread_famine=%s total_famines=%d" % [found_gib_bread, n_famine])
	return passed

func _dict_eq(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a.keys():
		if int(b.get(k, -999)) != int(a[k]):
			return false
	return true

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
