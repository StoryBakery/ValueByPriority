local TableUtil = require("../roblox_packages/TableUtil")

local Enums = {
	Priority = {
		Absolute = 100_000_000,
		ModelInheritance = 50_000, --Time Scale/World Scale
		ScaleInheritance = 40_000,
		ClientDefault = -100_000_000,
	},
}

TableUtil.deepFreeze(Enums)

return Enums
