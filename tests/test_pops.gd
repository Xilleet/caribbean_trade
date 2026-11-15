extends Node

## Stage B1 (combined) — POPs data model tests. Run with:
##   godot --headless --path <project> tests/test_pops.tscn
##
## Verifies the POPs data model:
##  - build_world creates 10 Pop groups per town (3 poor + 4 middle + 3 rich)
##  - poor/middle/rich getters return sum Pop.count by stratum
##  - set_class_count distributes proportionally across existing Pops
##  - set_class_count creates a default Pop if stratum is empty
##  - total_population / labor_force compute correctly from pops array
##  - population growth scales all Pops in a stratum (not just the first)
##  - profession distribution matches the specified ratios

func _ready() -> void:
	WorldState.reset()
	var ok := true
	ok = ok and test_pops_created_with_10_types_per_town()
	ok = ok and test_poor_middle_rich_aggregate_from_pops()
	ok = ok and test_set_class_count_distributes_proportionally()
	ok = ok and test_set_class_count_creates_default_if_empty()
	ok = ok and test_total_population_sums_pops()
	ok = ok and test_labor_force_excludes_rich()
	ok = ok and test_population_growth_scales_all_pops_in_stratum()
	ok = ok and test_profession_distribution_correct()
	print("\n=== %s ===" % ("ALL TESTS PASSED" if ok else "SOME TESTS FAILED"))
	get_tree().quit(0 if ok else 1)

## build_world → each town has 10 Pops (3 poor + 4 middle + 3 rich).
func test_pops_created_with_10_types_per_town() -> bool:
	WorldState.build_world()
	var passed: bool = true
	var detail: String = ""
	for t in WorldState.towns:
		if t.pops.size() != 10:
			passed = false
			detail = "%s has %d Pops (expect 10)" % [t.id, t.pops.size()]
			break
		# Count by stratum
		var poor_count: int = 0
		var middle_count: int = 0
		var rich_count: int = 0
		for p in t.pops:
			if p.social_class == "poor":
				poor_count += 1
			elif p.social_class == "middle":
				middle_count += 1
			elif p.social_class == "rich":
				rich_count += 1
		if poor_count != 3 or middle_count != 4 or rich_count != 3:
			passed = false
			detail = "%s strata: poor=%d middle=%d rich=%d (expect 3/4/3)" % [t.id, poor_count, middle_count, rich_count]
			break
	if detail == "":
		detail = "all %d towns have 10 Pops (3 poor + 4 middle + 3 rich)" % WorldState.towns.size()
	_report("pops_created_with_10_types_per_town", passed, detail)
	return passed

## t.poor/middle/rich getters return sum Pop.count by stratum.
func test_poor_middle_rich_aggregate_from_pops() -> bool:
	WorldState.reset()
	var t := Town.new("t_agg", "AggTown")
	WorldState.towns.append(t)
	# Manually create Pops with known counts
	t.pops.append(Pop.new("p1", "t_agg", "poor", "laborer", 300.0))
	t.pops.append(Pop.new("p2", "t_agg", "poor", "sailor", 100.0))
	t.pops.append(Pop.new("p3", "t_agg", "poor", "servant", 100.0))
	t.pops.append(Pop.new("p4", "t_agg", "middle", "artisan", 80.0))
	t.pops.append(Pop.new("p5", "t_agg", "middle", "smith", 30.0))
	t.pops.append(Pop.new("p6", "t_agg", "rich", "planter", 25.0))
	t.pops.append(Pop.new("p7", "t_agg", "rich", "official", 15.0))
	var poor_sum: float = t.poor   # 300 + 100 + 100 = 500
	var middle_sum: float = t.middle  # 80 + 30 = 110
	var rich_sum: float = t.rich   # 25 + 15 = 40
	var passed: bool = abs(poor_sum - 500.0) < 0.01 and abs(middle_sum - 110.0) < 0.01 and abs(rich_sum - 40.0) < 0.01
	_report("poor_middle_rich_aggregate_from_pops", passed,
		"poor=%.1f middle=%.1f rich=%.1f (expect 500/110/40)" % [poor_sum, middle_sum, rich_sum])
	return passed

## set_class_count distributes v proportionally across existing Pops of that stratum.
func test_set_class_count_distributes_proportionally() -> bool:
	WorldState.reset()
	var t := Town.new("t_dist", "DistTown")
	WorldState.towns.append(t)
	# Create 3 poor Pops with counts 300, 100, 100 (total 500, ratio 3:1:1)
	t.pops.append(Pop.new("p1", "t_dist", "poor", "laborer", 300.0))
	t.pops.append(Pop.new("p2", "t_dist", "poor", "sailor", 100.0))
	t.pops.append(Pop.new("p3", "t_dist", "poor", "servant", 100.0))
	# Set total poor to 1000 — should scale proportionally (3:1:1 → 600:200:200)
	t.set_class_count("poor", 1000.0)
	var laborer: float = t.pops[0].count
	var sailor: float = t.pops[1].count
	var servant: float = t.pops[2].count
	var total: float = t.poor
	# Ratio preserved: 600/200/200
	var passed: bool = abs(laborer - 600.0) < 0.01 and abs(sailor - 200.0) < 0.01 and abs(servant - 200.0) < 0.01 and abs(total - 1000.0) < 0.01
	_report("set_class_count_distributes_proportionally", passed,
		"laborer=%.1f sailor=%.1f servant=%.1f total=%.1f (expect 600/200/200/1000)" % [laborer, sailor, servant, total])
	return passed

## set_class_count on empty stratum creates a default Pop.
func test_set_class_count_creates_default_if_empty() -> bool:
	WorldState.reset()
	var t := Town.new("t_empty", "EmptyTown")
	WorldState.towns.append(t)
	# No Pops at all
	t.set_class_count("poor", 150.0)
	t.set_class_count("middle", 50.0)
	t.set_class_count("rich", 10.0)
	var passed: bool = t.pops.size() == 3 and abs(t.poor - 150.0) < 0.01 and abs(t.middle - 50.0) < 0.01 and abs(t.rich - 10.0) < 0.01
	# Check default professions
	var profs: Array[String] = []
	for p in t.pops:
		profs.append(p.profession)
	var detail: String = "pops=%d poor=%.1f middle=%.1f rich=%.1f profs=%s" % [t.pops.size(), t.poor, t.middle, t.rich, profs]
	_report("set_class_count_creates_default_if_empty", passed, detail)
	return passed

## t.total_population() returns sum of all Pop.count.
func test_total_population_sums_pops() -> bool:
	WorldState.reset()
	var t := Town.new("t_tot", "TotTown")
	WorldState.towns.append(t)
	t.pops.append(Pop.new("p1", "t_tot", "poor", "laborer", 200.0))
	t.pops.append(Pop.new("p2", "t_tot", "middle", "artisan", 50.0))
	t.pops.append(Pop.new("p3", "t_tot", "rich", "planter", 10.0))
	var total: float = t.total_population()
	var passed: bool = abs(total - 260.0) < 0.01
	_report("total_population_sums_pops", passed,
		"total=%.1f (expect 260)" % total)
	return passed

## t.labor_force() = (poor + middle) * 0.5, rich excluded.
func test_labor_force_excludes_rich() -> bool:
	WorldState.reset()
	var t := Town.new("t_lf", "LFTown")
	WorldState.towns.append(t)
	t.pops.append(Pop.new("p1", "t_lf", "poor", "laborer", 400.0))
	t.pops.append(Pop.new("p2", "t_lf", "middle", "artisan", 100.0))
	t.pops.append(Pop.new("p3", "t_lf", "rich", "planter", 50.0))
	var lf: float = t.labor_force()  # (400 + 100) * 0.5 = 250
	var passed: bool = abs(lf - 250.0) < 0.01
	_report("labor_force_excludes_rich", passed,
		"labor_force=%.1f (expect 250 = (400+100)*0.5, rich excluded)" % lf)
	return passed

## update_population scales ALL Pops in a stratum, not just the first.
func test_population_growth_scales_all_pops_in_stratum() -> bool:
	WorldState.reset()
	var t := Town.new("t_grow", "GrowTown")
	WorldState.towns.append(t)
	# 3 poor Pops: 300, 100, 100
	t.pops.append(Pop.new("p1", "t_grow", "poor", "laborer", 300.0))
	t.pops.append(Pop.new("p2", "t_grow", "poor", "sailor", 100.0))
	t.pops.append(Pop.new("p3", "t_grow", "poor", "servant", 100.0))
	# Set satisfaction high → growth = 0.01
	t.satisfaction = 0.9
	var pop_sys := PopulationSystem.new()
	var laborer_before: float = t.pops[0].count
	var sailor_before: float = t.pops[1].count
	var servant_before: float = t.pops[2].count
	pop_sys.update_population(t, RandomNumberGenerator.new())
	var laborer_after: float = t.pops[0].count
	var sailor_after: float = t.pops[1].count
	var servant_after: float = t.pops[2].count
	# All three should grow by ~1% (ratio preserved)
	var laborer_growth: float = laborer_after / laborer_before
	var sailor_growth: float = sailor_after / sailor_before
	var servant_growth: float = servant_after / servant_before
	var passed: bool = abs(laborer_growth - 1.01) < 0.001 and abs(sailor_growth - 1.01) < 0.001 and abs(servant_growth - 1.01) < 0.001
	_report("population_growth_scales_all_pops_in_stratum", passed,
		"growth: laborer=%.4f sailor=%.4f servant=%.4f (expect all ~1.01)" % [laborer_growth, sailor_growth, servant_growth])
	return passed

## Profession distribution matches specified ratios (laborer 60% of poor, etc.).
func test_profession_distribution_correct() -> bool:
	WorldState.build_world()
	# Use seed 1337 (default) — perturbation is small (±20%), so ratios
	# should be close to the base values.
	var t: Town = WorldState.towns[0]
	var poor_total: float = t.poor
	var middle_total: float = t.middle
	var rich_total: float = t.rich
	# Find each profession's count
	var laborer: float = 0.0
	var sailor: float = 0.0
	var artisan: float = 0.0
	var planter: float = 0.0
	for p in t.pops:
		match p.profession:
			"laborer": laborer = p.count
			"sailor": sailor = p.count
			"artisan": artisan = p.count
			"planter": planter = p.count
	# laborer should be ~60% of poor, sailor ~20%
	# artisan ~40% of middle, planter ~50% of rich
	# Allow ±25% tolerance for seed perturbation
	var laborer_ratio: float = laborer / poor_total if poor_total > 0 else 0.0
	var sailor_ratio: float = sailor / poor_total if poor_total > 0 else 0.0
	var artisan_ratio: float = artisan / middle_total if middle_total > 0 else 0.0
	var planter_ratio: float = planter / rich_total if rich_total > 0 else 0.0
	var passed: bool = laborer_ratio > 0.40 and laborer_ratio < 0.80 and \
		sailor_ratio > 0.10 and sailor_ratio < 0.30 and \
		artisan_ratio > 0.25 and artisan_ratio < 0.55 and \
		planter_ratio > 0.30 and planter_ratio < 0.70
	_report("profession_distribution_correct", passed,
		"laborer=%.0f%% sailor=%.0f%% artisan=%.0f%% planter=%.0f%% (of stratum)" % [laborer_ratio*100, sailor_ratio*100, artisan_ratio*100, planter_ratio*100])
	return passed

func _report(name: String, passed: bool, detail: String) -> void:
	print("[%s] %s — %s" % ["PASS" if passed else "FAIL", name, detail])
