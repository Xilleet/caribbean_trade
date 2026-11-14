extends Node

## Deterministic game clock. Day 0 = Jan 1, 1660. A week is 7 days. The week
## tick fires whenever [param day] becomes a multiple of 7. No real-time
## coupling here — [SimulationEngine] drives [method advance_day] from the
## fixed tick loop, so two runs with the same seed reproduce exactly.

const DAYS_PER_WEEK: int = 7
const START_YEAR: int = 1660

var day: int = 0
var week: int = 0

func reset() -> void:
	day = 0
	week = 0

func advance_day() -> void:
	day += 1

func advance_week() -> void:
	week += 1

func day_of_week() -> int:
	return day % DAYS_PER_WEEK  # 0 == start of a new week

func date_string() -> String:
	var y := START_YEAR + int(day / 365)
	var doy := day % 365
	return "Day %d  (1660+ %d years, DOY %d)" % [day, int(day / 365), doy]
