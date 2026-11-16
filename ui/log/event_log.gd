extends Control

## Stage UI-1 EventLog — the "— Log —" section: last LOG_LINES messages.
##
## Extracted from game_ui.gd (the _log_label + _log_lines + _on_message logic).
## Subscribes directly to EventBus.message and keeps a ring buffer of the last
## LOG_LINES entries, formatted as "[dN] text" exactly like the old UI. This
## is a pure view on EventBus + SimulationClock.day — it reads no economic
## state, mutates nothing, so determinism and money conservation are
## unaffected.
##
## Self-contained: game_ui does not need to wire it or refresh it. Decoupling
## the log was a Stage UI-1 goal — it is the cleanest of the panels because it
## has no inputs and no controller dependency.

const LOG_LINES: int = 14

@onready var _title_label: Label = %LogTitle
@onready var _log_label: Label = %LogLabel
var _lines: Array[String] = []

func _ready() -> void:
	var f := UITheme.load_font()
	_title_label.add_theme_font_override("font", f)
	_title_label.add_theme_font_size_override("font_size", 15)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	_log_label.add_theme_font_override("font", f)
	_log_label.add_theme_font_size_override("font_size", 12)
	_log_label.add_theme_color_override("font_color", Color(0.65, 0.8, 0.65))
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EventBus.message.connect(_on_message)

func _on_message(text: String) -> void:
	_lines.append("[d%d] %s" % [SimulationClock.day, text])
	while _lines.size() > LOG_LINES:
		_lines.pop_front()
	_log_label.text = "\n".join(PackedStringArray(_lines))
