--!native
local Scale = {}

type ScaleFunc<T> = (value: T, scale: number)->(T)

function Scale.byType<T>(value: T, scale: number): T
	local t = typeof(value)
	local func = Scale[t]
	if func then
		return func(value, scale)
	else
		error("No interpolation function found for type: "..t)
	end
end

local function scaleWithMultiply(value, scale)
	return value * scale
end

Scale.number = scaleWithMultiply :: ScaleFunc<number>
Scale.Vector3 = scaleWithMultiply :: ScaleFunc<Vector3>
Scale.Vector2 = scaleWithMultiply :: ScaleFunc<Vector2>

Scale.NumberRange = function(value: NumberRange, scale: number): NumberRange
	return NumberRange.new(value.Min * scale, value.Max * scale)
end

Scale.NumberSequence = function(value: NumberSequence, scale: number): NumberSequence
	local keypoints = value.Keypoints
	local newKeypoints = table.create(#keypoints)
	for i, keypoint in ipairs(keypoints) do
		newKeypoints[i] = NumberSequenceKeypoint.new(
			keypoint.Time, 
			keypoint.Value * scale,
			keypoint.Envelope * scale
		)
	end
	return NumberSequence.new(newKeypoints)
end

Scale.CFrame = function(value: CFrame, scale: number): CFrame
	return value.Rotation + value.Position * scale
end

return Scale