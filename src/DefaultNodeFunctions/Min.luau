--!native
local Min = {}

type MinFunc<T> = (a: T, b: T) -> T

function Min.byType<T>(a: T, b: T): T
	local t = typeof(a)
	local func = Min[t]
	if func then
		return func(a, b)
	else
		error("No interpolation function found for type: " .. t)
	end
end

Min.number = function(a: number, b: number)
	return math.min(a, b)
end

Min.Vector3 = function(a: Vector3, b: Vector3)
	return a:Min(b)
end

Min.Vector2 = function(a: Vector2, b: Vector2)
	return a:Min(b)
end

Min.UDim2 = function(a: UDim2, b: UDim2)
	return UDim2.new(
		math.min(a.X.Scale, b.X.Scale),
		math.min(a.X.Offset, b.X.Offset),
		math.min(a.Y.Scale, b.Y.Scale),
		math.min(a.Y.Offset, b.Y.Offset)
	)
end

Min.UDim = function(a: UDim, b: UDim)
	return UDim.new(math.min(a.Scale, b.Scale), math.min(a.Offset, b.Offset))
end

Min.Color3 = function(a: Color3, b: Color3)
	return Color3.new(math.min(a.R, b.R), math.min(a.G, b.G), math.min(a.B, b.B))
end

return Min
