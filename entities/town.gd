class_name Town
extends RefCounted

## A town = population + market + industries. The town owns money accounts:
## [param treasury] (taxes) and the market's [param fund] on [Market].
## Industries keep their own [param money]. Population wealth is now
## per-Pop ([param Pop.savings]) — [param population_money] is a read-only
## computed getter (sum of Pop.savings).
##
## Stage B1: population as array of Pop groups (10 per town).
## Stage B2: profession-based hiring + wage_rate.
## Stage B2b: migration via ships (waiting_passengers).
## Stage B3: per-Pop savings, per-Pop satisfaction/SoL, ticket cost.

var id: String
var name: String
var coords: Vector2 = Vector2.ZERO
var market: Market
var industries: Array[Industry] = []
var treasury: float = 0.0
var development: float = 1.0
var external_balance: float = 0.0
var port_capacity: float = 100.0
var state_id: String = ""

# Stage B2b: migration queue.
var waiting_passengers: Array = []

# Stage B2: per-profession wage rate.
var wage_rate: Dictionary = {}

# Stage B1: POPs array — source of truth for population + wealth.
var pops: Array[Pop] = []

# Stage B3: population_money is now a read-only computed getter
# (sum of Pop.savings). All writes must go through add_to_pop /
# add_to_all_pops / spend_from_pop / distribute_population_money.
var population_money: float:
	get:
		var s: float = 0.0
		for p in pops:
			s += p.savings
		return s

# Stage B3: satisfaction is now a read-only computed getter
# (population-weighted average of Pop.satisfaction). Set by
# ConsumptionSystem per-Pop (Pop.satisfaction = SoL), not per-town.
var satisfaction: float:
	get:
		var tpop: float = total_population()
		if tpop <= 0.0:
			return 1.0
		var s: float = 0.0
		for p in pops:
			s += p.satisfaction * p.count
		return s / tpop

# Read-only computed: sum of Pop.count by stratum.
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

## Set the total count for a social stratum. Distributes proportionally
## across existing Pops of that stratum, or creates a default Pop.
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
		var default_prof: String = "laborer" if cls == "poor" else ("artisan" if cls == "middle" else "elite")
		var p := Pop.new("%s_pop_%s_0" % [id, cls], id, cls, default_prof, v)
		pops.append(p)

## Stage B3: distribute initial population_money across Pops by stratum.
## Poor get 20%, middle 30%, rich 50% (per-capita skewed to rich —
## historically accurate for Caribbean 16-17th century).
func distribute_population_money(total: float) -> void:
	# Group Pops by stratum and sum counts.
	var poor_count: float = 0.0
	var middle_count: float = 0.0
	var rich_count: float = 0.0
	for p in pops:
		match p.social_class:
			"poor": poor_count += p.count
			"middle": middle_count += p.count
			"rich": rich_count += p.count
	# Distribute: poor 20%, middle 30%, rich 50% of total.
	var poor_share: float = total * 0.20
	var middle_share: float = total * 0.30
	var rich_share: float = total * 0.50
	# Within each stratum, distribute proportionally by count.
	for p in pops:
		match p.social_class:
			"poor":
				p.savings = poor_share * (p.count / poor_count) if poor_count > 0.0 else 0.0
			"middle":
				p.savings = middle_share * (p.count / middle_count) if middle_count > 0.0 else 0.0
			"rich":
				p.savings = rich_share * (p.count / rich_count) if rich_count > 0.0 else 0.0

## Stage B3: add money to a specific Pop by profession.
## Used by charge_wages (wages go to the Pop that works the industry).
func add_to_pop(prof: String, amount: float) -> void:
	for p in pops:
		if p.profession == prof:
			p.savings += amount
			return

## Stage B3: add money to ALL Pops proportionally by count.
## Used by dividends (town-owned industries pay to all residents)
## and ship upkeep (paid to local population).
func add_to_all_pops(amount: float) -> void:
	var tpop: float = total_population()
	if tpop <= 0.0:
		# No Pops — money goes to market.fund (stays in circulation,
		# conservation preserved). Happens in unit tests without build_world.
		market.fund += amount
		return
	for p in pops:
		p.savings += amount * (p.count / tpop)

## Stage B3: spend money from a specific Pop by profession.
## Returns actual amount spent (may be less than requested if Pop
## can't afford it). Used by consumption (each Pop buys from own savings).
func spend_from_pop(prof: String, amount: float) -> float:
	for p in pops:
		if p.profession == prof:
			var actual: float = min(amount, p.savings)
			p.savings -= actual
			return actual
	return 0.0

func total_population() -> float:
	var s: float = 0.0
	for p in pops:
		s += p.count
	return s

func labor_force() -> float:
	return (poor + middle) * 0.5

## Stage B2: total workforce available for a given profession.
func get_available_workers(prof: String) -> float:
	var s: float = 0.0
	for p in pops:
		if p.profession == prof:
			s += p.count
	return s
