var script_class = "tool"

# Roof Builder for Patterns — standalone mod entry point.
# All the logic lives in roof_patterns.gd.

var RoofPatternsScript
var roof_patterns


func start() -> void:
	RoofPatternsScript = ResourceLoader.load(Global.Root + "scripts/roof_patterns.gd", "GDScript", true)
	if RoofPatternsScript == null:
		print("[BetterRoofPatterns] roof_patterns.gd not found, mod disabled.")
		return
	roof_patterns = RoofPatternsScript.new()
	roof_patterns._g = Global
	roof_patterns.initialize()


func update(delta) -> void:
	if roof_patterns != null:
		roof_patterns.update(delta)
