class_name Pop
extends RefCounted

## A population group (POPs model, Victoria 3-inspired).
##
## A Pop is a group of people with the same social class (stratum) and
## profession. Stage B1 (combined): data model only — professions are set
## and [param profession_required] stubs exist in [param data/recipes.json],
## but hiring logic doesn't filter by profession yet (that's B2).
##
## [param savings], [param living_standard], [param satisfaction],
## [param migration_propensity], [param employed_count] are stubs for
## B2-B7:
## - B2 (labour market) will populate [param employed_count] and per-Pop
##   [param satisfaction] (based on wage vs cost of living).
## - B3 (savings & SoL) will populate [param savings] and
##   [param living_standard] (SoL = consumption / needs).
## - B2 will compute [param migration_propensity] from satisfaction/wages.
##
## Conservation: [param count] is NOT in [param WorldState.total_money] —
## population counts never affect money conservation. [param savings] will
## be part of total_money once B3 populates it (currently always 0.0).

var id: String
var town_id: String
var social_class: String         # "poor" | "middle" | "rich" (stratum)
var profession: String           # "laborer" | "sailor" | "servant" | "artisan" | "smith" | "merchant" | "small_planter" | "planter" | "official" | "financier"
var count: float = 0.0           # number of people in this group
var savings: float = 0.0         # B3 stub: group's wallet (currently 0, town.population_money is aggregate)
var living_standard: float = 1.0 # B3 stub: 0..1 SoL (consumption / needs)
var satisfaction: float = 1.0    # B2 stub: 0..1 (per-Pop, currently mirrors town.satisfaction)
var migration_propensity: float = 0.0  # B2 stub: 0..1 (willingness to migrate)
var employed_count: float = 0.0  # B2 stub: how many in this group are employed

func _init(p_id: String, p_town_id: String, p_class: String, p_profession: String, p_count: float) -> void:
	id = p_id
	town_id = p_town_id
	social_class = p_class
	profession = p_profession
	count = p_count
