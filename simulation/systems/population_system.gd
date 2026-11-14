class_name PopulationSystem
extends RefCounted

## Weekly population + employment dynamics.
##
## Satisfaction (set daily by [ConsumptionSystem]) drives growth:
##   sat > 0.8  -> +1%/week   (boom + immigration)
##   sat < 0.5  -> -2%/week    (famine + emigration)
##   otherwise  -> mild drift around neutral
##
## Employment: each industry hires/fires one worker per week based on its
## weekly profit, capped by the town's labour force. A labour shortage scales
## every industry's workers down uniformly.

func calculate_satisfaction(t: Town) -> float:
	return t.satisfaction

func update_population(t: Town, _rng: RandomNumberGenerator) -> void:
	var sat: float = t.satisfaction
	var growth: float
	if sat > 0.8:
		growth = 0.01
	elif sat < 0.5:
		growth = -0.02
	else:
		growth = (sat - 0.65) * 0.02
	t.poor = max(0.0, t.poor * (1.0 + growth))
	t.middle = max(0.0, t.middle * (1.0 + growth * 1.1))
	t.rich = max(0.0, t.rich * (1.0 + growth * 0.5))

func update_employment(t: Town, recipes: Dictionary) -> void:
	var labor_force: float = t.labor_force()
	var total_jobs: float = 0.0
	for ind in t.industries:
		var recipe: Dictionary = recipes[ind.recipe_id]
		var req: float = float(recipe.get("workers_required", 1.0))
		if ind.weekly_profit > 0.0:
			ind.workers = min(req * 1.5, ind.workers + 1.0)
		elif ind.weekly_profit < 0.0:
			ind.workers = max(req * 0.3, ind.workers - 1.0)
		total_jobs += ind.workers
	# Labour shortage: scale everyone down to the available force.
	if total_jobs > labor_force and total_jobs > 0.0:
		var s: float = labor_force / total_jobs
		for ind in t.industries:
			ind.workers *= s
