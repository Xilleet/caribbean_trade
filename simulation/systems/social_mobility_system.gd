class_name SocialMobilitySystem
extends RefCounted

## Stage B4 — social mobility (promotion / demotion between professions and
## strata). Victoria 3-inspired: a Pop group whose members are prosperous
## (high SoL + accumulated savings + a job opening for the target role) sees
## a small fraction promote each week; a Pop group that is destitute (low SoL
## + savings exhausted) sees a fraction demote. This is the channel by which
## laborers become artisans, artisans become small planters, failed artisans
## fall back to laborer, etc. — the colonial social ladder.
##
## Three conservation/identity rules (from the B4 design):
##   1. No money creation/destruction — savings and count are transferred
##      STRICTLY PROPORTIONALLY. The transitioning fraction takes its per-capita
##      share of both count and savings; source loses rate×, target gains
##      rate×. [param WorldState.total_money] drift = 0 by construction.
##   2. Preserve population history — [param Pop.count] never disappears;
##      it moves to the target Pop. The source Pop keeps its profession (it is
##      the residual group); only the transitioning fraction changes role.
##   3. No infinite switching — [param Pop.mobility_cooldown] (4 weeks). When a
##      Pop is the source of a transition it goes on cooldown and cannot be a
##      source again for 4 weeks, so a group can't promote and demote back in
##      the same month.
##
## Eligibility:
##   Promotion — SoL > 0.8 AND per-capita savings > 12× the weekly consumption
##     basket cost (a capital buffer to set up the new role) AND, if the target
##     profession is hired by industries in this town, unmet demand for it
##     (a shortage — otherwise we'd mint unemployed specialists, the "сотни
##     рабочих становятся ремесленниками без мастерских" problem). Capital /
##     self-employed targets (merchant, planter, financier, official,
##     small_planter, servant, sailor — no industry hires them) are gated by
##     the savings threshold alone.
##   Demotion — SoL < 0.3 AND per-capita savings < 1× the weekly basket cost
##     (capital exhausted). The Pop held on as long as it could afford to.
##
## Rates are weekly: 0.2% promotion (~10%/yr), 0.5% demotion (~23%/yr) —
## demotion is faster than promotion (downward mobility is easier than upward).

# Fraction of a source Pop's count that transitions per week.
const PROMOTION_RATE: float = 0.002   # 0.2%/week → ~10%/year
const DEMOTION_RATE: float = 0.005    # 0.5%/week → ~23%/year

# Weeks a source Pop is ineligible after a transition (rule 3: no infinite
# switching). Set when a transition fires; decremented at the start of each
# weekly call. Eligible again once it reaches 0 — a 4-week gap between
# consecutive transitions of the same Pop.
const MOBILITY_COOLDOWN_WEEKS: int = 4

# SoL gates. SoL = Pop.living_standard (== Pop.satisfaction in this model —
# ConsumptionSystem sets them equal).
const SOL_PROMOTION_MIN: float = 0.8
const SOL_DEMOTION_MAX: float = 0.3

# Relative savings thresholds, in weeks of per-capita consumption at current
# market prices. Promotion needs a 12-week capital buffer; demotion fires
# when under 1 week of consumption is left (capital exhausted).
const PROMOTION_SAVINGS_WEEKS: float = 12.0
const DEMOTION_SAVINGS_WEEKS: float = 1.0

# Skip transitions smaller than this many people — avoids microscopic
# transfers from tiny Pops (consistent with MigrationSystem's 0.5 threshold).
const MIN_TRANSITION_COUNT: float = 0.5

# Diagnostic counter: total transitions fired by this system instance since
# construction. Incremented in [method _do_transition]. Useful for balancing —
# if this stays 0 over a long run, the SoL/savings thresholds are too strict
# for the current economy and mobility is dormant. Not part of any
# conservation invariant (count/savings are unaffected by reading it).
var transitions_total: int = 0
var promotions_total: int = 0   # diagnostic: promotions fired
var demotions_total: int = 0    # diagnostic: demotions fired

# Profession → stratum. A transition updates BOTH profession and stratum
# together (rule from B4: promotion/demotion меняет profession И stratum).
const PROF_STRATUM := {
	"laborer": "poor", "sailor": "poor", "servant": "poor",
	"artisan": "middle", "smith": "middle", "merchant": "middle", "small_planter": "middle",
	"planter": "rich", "official": "rich", "financier": "rich",
}

# Promotion paths: source profession → ordered list of target professions.
# The first eligible target fires (a source transitions at most once per
# week). Order matters only when several targets are simultaneously eligible
# — e.g. laborer can become artisan OR small_planter; artisan (industry-
# hired, demand-checked) is the canonical colonial path so it goes first.
# Land-based targets (small_planter, planter) are gated on available land
# (TODO G1) and stay dormant until a land system exists.
const PROMOTION_MAP := {
	"laborer": ["artisan", "small_planter"],
	"sailor": ["merchant"],
	"servant": ["artisan"],
	"artisan": ["small_planter"],
	"smith": ["small_planter"],
	"merchant": ["financier"],
	"small_planter": ["planter"],
}

# Demotion paths: source profession → single target profession. Pops already
# at the poor floor (laborer, sailor, servant) have no demotion target.
# Note: official → laborer (loss of post = unemployed laborer, NOT merchant —
# a dismissed colonial official doesn't become a trader). Demotion changes
# stratum: middle→poor (artisan→laborer), rich→middle (financier→merchant),
# rich→poor (official→laborer, planter→small_planter is rich→middle).
const DEMOTION_MAP := {
	"artisan": "laborer",
	"smith": "laborer",
	"merchant": "sailor",
	"small_planter": "laborer",
	"planter": "small_planter",
	"financier": "merchant",
	"official": "laborer",
}

# Land-based professions — promotion INTO these requires available land.
# Stub returns false until G1 (land & natural resources) is implemented.
const LAND_BASED_PROFESSIONS := ["small_planter", "planter"]

## Weekly social-mobility pass for one town. For each Pop (snapshot taken
## before any transitions so newly-created target Pops aren't reprocessed):
## decrement cooldown, then — if eligible — move a small fraction of count
## and savings to the target profession's Pop (find-or-create). Source goes
## on cooldown. Called in [param WeeklyTick.run] AFTER population growth and
## BEFORE employment (so the new profession counts feed straight into hiring).
func update_social_mobility(t: Town, recipes: Dictionary) -> void:
	# Rule 3: tick down every Pop's cooldown first.
	for p in t.pops:
		if p.mobility_cooldown > 0:
			p.mobility_cooldown -= 1
	# Snapshot sources: we may append a new target Pop mid-loop (find-or-
	# create) and must not iterate it as a source this pass.
	var sources: Array = t.pops.duplicate()
	for p in sources:
		if p.count <= 0.0:
			continue
		if p.mobility_cooldown > 0:
			continue   # on cooldown — can't transition this week
		var sol: float = p.living_standard
		if sol > SOL_PROMOTION_MIN:
			_try_promote(t, p, recipes)
		elif sol < SOL_DEMOTION_MAX:
			_try_demote(t, p, recipes)
		# else: stable SoL band — no transition

## Promotion: walk the source's promotion targets in priority order, fire the
## first one that satisfies SoL (already checked by caller) + savings buffer +
## demand (if the target is industry-hired) + land (if land-based).
func _try_promote(t: Town, source: Pop, recipes: Dictionary) -> void:
	var targets: Array = PROMOTION_MAP.get(source.profession, [])
	if targets.is_empty():
		return   # already at the top of a promotion chain
	if not _savings_buffer_ok(t, source, PROMOTION_SAVINGS_WEEKS):
		return   # not enough capital to set up the new role
	for target_prof in targets:
		var tp: String = String(target_prof)
		if LAND_BASED_PROFESSIONS.has(tp) and not _has_available_land(t):
			continue   # dormant until G1 (land & resources)
		if not _promotion_demand_satisfied(t, tp, recipes):
			continue   # industry-hired target with no shortage → no promotion
		if _do_transition(t, source, tp, PROMOTION_RATE):
			promotions_total += 1
		return   # one transition per source per week

## Demotion: single target. Fires if SoL (checked by caller) + savings
## exhausted. The target profession is the floor role for this stratum.
func _try_demote(t: Town, source: Pop, _recipes: Dictionary) -> void:
	var tp: String = String(DEMOTION_MAP.get(source.profession, ""))
	if tp == "":
		return   # poor floor — nowhere to demote to
	# Demotion fires when savings are EXHAUSTED (under 1 week of consumption).
	# SoL < 0.3 alone (with savings still holding capital) means the Pop is
	# struggling but holding onto its workshop/tools — it doesn't abandon
	# them until capital is gone.
	if not _savings_depleted(t, source):
		return
	if _do_transition(t, source, tp, DEMOTION_RATE):
		demotions_total += 1

## Move [param rate] fraction of [param source]'s count AND savings to the
## target profession's Pop (find-or-create with the right stratum). Both move
## by the same fraction → per-capita wealth preserved → drift = 0. Source
## goes on cooldown. Returns true if a transition actually fired (false if
## the fraction rounded to fewer than [param MIN_TRANSITION_COUNT] people,
## in which case nothing moved). No-op return keeps the caller from counting
## a microscopic transfer against the diagnostic totals.
func _do_transition(t: Town, source: Pop, target_prof: String, rate: float) -> bool:
	var delta_count: float = source.count * rate
	if delta_count < MIN_TRANSITION_COUNT:
		return false
	var delta_savings: float = source.savings * rate   # proportional: rate × (savings/count) × count
	source.count -= delta_count
	source.savings -= delta_savings
	var target: Pop = _find_or_create_pop(t, target_prof)
	target.count += delta_count
	target.savings += delta_savings
	source.mobility_cooldown = MOBILITY_COOLDOWN_WEEKS
	transitions_total += 1
	return true

## Find the Pop of [param prof] in [param t], or create one with the correct
## stratum and zero count (the transitioning fraction will populate it).
## build_world creates all 10 professions per town, so this is mostly
## defensive — but it keeps mobility robust if a profession is ever missing.
func _find_or_create_pop(t: Town, prof: String) -> Pop:
	for p in t.pops:
		if p.profession == prof:
			return p
	var target := Pop.new("%s_pop_%s" % [t.id, prof], t.id, String(PROF_STRATUM[prof]), prof, 0.0)
	t.pops.append(target)
	return target

## Per-capita weekly consumption basket cost for [param source]'s stratum, at
## current market prices. Uses the SAME baskets as ConsumptionSystem so the
## threshold tracks what Pops actually pay. Returns 0 if the market has none
## of the basket goods (degenerate — no consumption possible).
func _weekly_basket_cost_per_capita(t: Town, stratum: String) -> float:
	var basket: Dictionary = ConsumptionSystem.BASKETS.get(stratum, {})
	var cost: float = 0.0
	for good_id in basket.keys():
		var qty: float = float(basket[good_id])
		if t.market.has_good(String(good_id)):
			cost += qty * t.market.get_entry(String(good_id)).current_price
	return cost

## Promotion savings gate: per-capita savings must exceed [param weeks] × the
## weekly basket cost (a capital buffer to set up the new role). Compared
## RELATIVE to the economy (current prices), not a fixed number, so it works
## across inflation regimes.
func _savings_buffer_ok(t: Town, source: Pop, weeks: float) -> bool:
	if source.count <= 0.0:
		return false
	var basket_cost: float = _weekly_basket_cost_per_capita(t, source.social_class)
	if basket_cost <= 0.0:
		return false   # can't price the basket → don't promote (safe default)
	var per_capita_savings: float = source.savings / source.count
	return per_capita_savings > basket_cost * weeks

## Demotion savings gate: per-capita savings below 1 week of consumption →
## capital exhausted → demote. The threshold is the weekly basket cost.
func _savings_depleted(t: Town, source: Pop) -> bool:
	if source.count <= 0.0:
		return true   # empty Pop — vacuously depleted (won't transition, count≤0 guarded)
	var basket_cost: float = _weekly_basket_cost_per_capita(t, source.social_class)
	if basket_cost <= 0.0:
		return false   # can't price the basket → don't demote (safe default)
	var per_capita_savings: float = source.savings / source.count
	return per_capita_savings < basket_cost * DEMOTION_SAVINGS_WEEKS

## Promotion demand gate for the TARGET profession. If industries in this
## town require the target profession, there must be a SHORTAGE (unmet
## demand) — otherwise promoting into it just creates unemployed specialists.
## If NO industry requires the target (capital/self-employed roles like
## merchant, planter, financier, official, small_planter, servant, sailor),
## the savings threshold alone gates promotion — these Pops don't need an
## industry job, they need capital (already checked by the caller).
func _promotion_demand_satisfied(t: Town, target_prof: String, recipes: Dictionary) -> bool:
	if _has_industries_for_profession(t, target_prof, recipes):
		return t.has_unmet_demand(target_prof, recipes)
	return true

## Does any industry in [param t] require [param prof]? Distinguishes "no
## shortage" (industries exist, supply covers demand → has_unmet_demand
## returns false) from "no demand signal at all" (no industries → vacuous).
func _has_industries_for_profession(t: Town, prof: String, recipes: Dictionary) -> bool:
	for ind in t.industries:
		var recipe: Dictionary = recipes.get(ind.recipe_id, {})
		if String(recipe.get("profession_required", "laborer")) == prof:
			return true
	return false

## Land availability for land-based professions (small_planter, planter).
## STUB: returns false — there is no land/resource system yet (TODO G1:
## Town.resources with fertility, suitable_crops, etc.). Until G1 lands,
## promotions INTO land-based professions stay dormant, which is correct —
## we must not mint planters with nowhere to plant. Flip this to a real check
## once G1 is implemented.
func _has_available_land(_t: Town) -> bool:
	return false   # TODO G1: land & natural resources
