class_name Pop
extends RefCounted

## A population group (POPs model, Victoria 3-inspired).
##
## A Pop is a group of people with the same social class (stratum) and
## profession. Professions are set; [param data/recipes.json] carries a real
## [param profession_required] on all 16 recipes, and B2 hiring filters by
## profession (PopulationSystem Phase 2-3: group by profession, scale to
## supply).
##
## Wired fields (B2/B3 done):
## - [param employed_count] — PopulationSystem Phase 4 (sum of
##   industry.workers per Pop; reset + accumulate each week).
## - [param satisfaction] — ConsumptionSystem (= living_standard).
## - [param living_standard] — ConsumptionSystem (bought / desired).
## - [param savings] — Town distributes town.population_money to stratum
##   shares (poor 20% / middle 30% / rich 50%) per Pop.
##
## Still a stub:
## - [param migration_propensity] — B2b migration uses push/pull + unmet
##   demand, not a per-Pop propensity field yet (stays 0.0).
##
## Conservation: [param count] is NOT in [param WorldState.total_money] —
## population counts never affect money conservation. Per-Pop [param savings]
## are backed by [member Town.population_money] (which IS in total_money):
## savings is a redistribution of the aggregate, not new money, so it is NOT
## summed separately in total_money() (no double count).

var id: String
var town_id: String
var social_class: String         # "poor" | "middle" | "rich" (stratum)
var profession: String           # "laborer" | "sailor" | "servant" | "artisan" | "smith" | "merchant" | "small_planter" | "planter" | "official" | "financier"
var count: float = 0.0           # number of people in this group
var savings: float = 0.0         # B3: group's wallet (stratum share of town.population_money)
var living_standard: float = 1.0 # B3: 0..1 SoL (consumption / needs), set by ConsumptionSystem
var satisfaction: float = 1.0    # B2: 0..1 (= living_standard), set by ConsumptionSystem
var migration_propensity: float = 0.0  # STUB: 0..1 (willingness to migrate) — B2b uses push/pull, not this field
var employed_count: float = 0.0  # B2: how many in this group are employed (PopulationSystem Phase 4)
# Stage B4: weeks remaining before this Pop can be a SOURCE of a social-mobility
# transition (promotion or demotion). Set to MOBILITY_COOLDOWN_WEEKS when a
# transition fires; decremented each week by SocialMobilitySystem. A Pop with
# cooldown > 0 is skipped — this prevents the same group ping-ponging between
# two professions week after week (no infinite switching). Count/savings are
# never affected by cooldown — only the eligibility to transition.
var mobility_cooldown: int = 0

func _init(p_id: String, p_town_id: String, p_class: String, p_profession: String, p_count: float) -> void:
	id = p_id
	town_id = p_town_id
	social_class = p_class
	profession = p_profession
	count = p_count
