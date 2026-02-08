--!native
local Max = {}

type MaxFunc<T> = (a: T, b: T) -> T

function Max.byType<T>(a: T, b: T): T
	local t = typeof(a)
	local func = Max[t]
	if func then
		return func(a, b)
	else
		error("No interpolation function found for type: " .. t)
	end
end

Max.number = function(a: number, b: number)
	return math.max(a, b)
end

Max.Vector3 = function(a: Vector3, b: Vector3)
	return a:Max(b)
end

Max.Vector2 = function(a: Vector2, b: Vector2)
	return a:Max(b)
end

Max.UDim2 = function(a: UDim2, b: UDim2)
	return UDim2.new(
		math.max(a.X.Scale, b.X.Scale),
		math.max(a.X.Offset, b.X.Offset),
		math.max(a.Y.Scale, b.Y.Scale),
		math.max(a.Y.Offset, b.Y.Offset)
	)
end

Max.UDim = function(a: UDim, b: UDim)
	return UDim.new(math.max(a.Scale, b.Scale), math.max(a.Offset, b.Offset))
end

Max.Color3 = function(a: Color3, b: Color3)
	return Color3.new(math.max(a.R, b.R), math.max(a.G, b.G), math.max(a.B, b.B))
end

return Max
