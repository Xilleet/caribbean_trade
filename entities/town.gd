class_name Town
extends RefCounted

## A town = population + market + industries. The town owns three money
## accounts: [param population_money] (aggregate wallet of residents),
## [param treasury] (taxes, unused in Stage 1) and the market's [param fund]
## stored on [Market]. Industries keep their own [param money].
##
## Stage B1 (combined): population is now modelled as an array of [param Pop]
## groups (POPs model, Victoria 3-inspired). Each town has 10 Pop types:
## 3 poor stratum (laborer, sailor, servant), 4 middle (artisan, smith,
## merchant, small_planter), 3 rich (planter, official, financier).
## [param poor] / [param middle] / [param rich] are now READ-ONLY computed
## properties (sum of Pop.count by stratum). Use [param set_class_count] to
## update — it distributes proportionally across existing Pops of that
## stratum, or creates a default Pop if none exist.

var id: String
var name: String
var coords: Vector2 = Vector2.ZERO
var population_money: float = 0.0
var market: Market
var industries: Array[Industry] = []
var treasury: float = 0.0
var development: float = 1.0
var satisfaction: float = 1.0
var external_balance: float = 0.0  # net money flow to/from the wider Caribbean
var port_capacity: float = 100.0
var state_id: String = ""        # Stage A2: which colonial power owns this town

# Stage B1: POPs array — source of truth for population. Each town has
# 10 Pop groups (3 poor + 4 middle + 3 rich) created in WorldState.build_world.
# poor/middle/rich below are computed getters over this array.
var pops: Array[Pop] = []

# Read-only computed properties: sum of Pop.count by stratum.
# These replace the old scalar fields. Existing readers (ConsumptionSystem,
# main.gd UI, tests) work unchanged. Writers must use set_class_count().
var poor: float:
	get:
		var s: float = 0.0
		for p in pops:
			if p.social_class == "poor":
				s += p.count
		return s

var middle: float:
	get:
		var s: float = 0.0
		for p in pops:
			if p.social_class == "middle":
				s += p.count
		return s

var rich: float:
	get:
		var s: float = 0.0
		for p in pops:
			if p.social_class == "rich":
				s += p.count
		return s

func _init(p_id: String, p_name: String) -> void:
	id = p_id
	name = p_name
	market = Market.new()

## Set the total count for a social stratum ("poor" / "middle" / "rich").
## If Pops of that stratum exist, distribute v proportionally (preserving
## the ratio between professions). If none exist, create a default Pop
## (profession = "laborer" for poor, "artisan" for middle, "elite" for rich)
## with count = v. Used by PopulationSystem.update_population and tests.
func set_class_count(cls: String, v: float) -> void:
	v = max(0.0, v)
	var current_total: float = 0.0
	for p in pops:
		if p.social_class == cls:
			current_total += p.count
	if current_total > 0.0:
		var factor: float = v / current_total
		for p in pops:
			if p.social_class == cls:
				p.count *= factor
	else:
		# No Pops of this stratum — create a default one.
		var default_prof: String = "laborer" if cls == "poor" else ("artisan" if cls == "middle" else "elite")
		var p := Pop.new("%s_pop_%s_0" % [id, cls], id, cls, default_prof, v)
		pops.append(p)

func total_population() -> float:
	var s: float = 0.0
	for p in pops:
		s += p.count
	return s

func labor_force() -> float:
	# Labor force = poor + middle (excludes rich), at 50% participation.
	return (poor + middle) * 0.5
