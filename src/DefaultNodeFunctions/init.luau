--!native

local Signal = require("../../roblox_packages/Signal")
local TableUtil = require("../../roblox_packages/TableUtil")
local LinearInterpolation = require("../../roblox_packages/LinearInterpolation")

local DefaultNodeFunctions = {}

export type DefaultNodeFunction = keyof<typeof(DefaultNodeFunctions)>


--#region Set
function DefaultNodeFunctions.Set(_, value)
	return value
end

function DefaultNodeFunctions.SetOrPassOnNil(lastValue, value)
	return if value == nil 
		then lastValue
		else value
end

function DefaultNodeFunctions.WeightedSet(_, value, customData, vbp, node)
	local valueAndWeightPairs = {}
	local priority = node.Priority
	
	-- WeightedSet 은 무조건적으로 _affectingLowestNodeIndex 가 1인 노드
	-- 아래 노드들이 WeightedSet 인 노드들이고 Priority 가 같다면
	-- 그 노드들의 값을 모두 합산하여, 그 값을 반환합니다
	for i = vbp._affectingLowestNodeIndex, 1, -1 do
		local otherNode = vbp.Nodes[i]
		if 
			otherNode.Priority == priority 
			and otherNode.NodeFunction == "WeightedSet"
		then
			table.insert(valueAndWeightPairs, {otherNode.Value, otherNode.CustomData.Weight})
		else
			break
		end
	end
	
	local linearInterpolation = LinearInterpolation.GetFunctionFromValueType(value)
	
	local newValue = valueAndWeightPairs[1][1]
	local accumulatedWeight = valueAndWeightPairs[1][2]
	
	for i = 2, #valueAndWeightPairs do
		local pair = valueAndWeightPairs[i]
		local value, weight = pair[1], pair[2]
		
		-- 이전까지의 결과와 현재 값을 가중치에 따라 보간합니다.
		local alpha = weight / (accumulatedWeight + weight)
		newValue = linearInterpolation(value, alpha)
		accumulatedWeight += weight
	end
	
	return newValue
end

--#region Operations
function DefaultNodeFunctions.Add(lastValue, value)
	return lastValue + value
end

--#tag ReverseAdd
function DefaultNodeFunctions.ReverseAdd(lastValue, value)
	return value + lastValue
end

function DefaultNodeFunctions.Subtract(lastValue, value)
	return lastValue - value
end

--#tag ReverseSubtract
function DefaultNodeFunctions.ReverseSubtract(lastValue, value)
	return value - lastValue
end

function DefaultNodeFunctions.Multiply(lastValue, value)
	return lastValue * value
end

--#tag ReverseMultiply
function DefaultNodeFunctions.ReverseMultiply(lastValue, value)
	return value * lastValue
end

function DefaultNodeFunctions.Divide(lastValue, value)
	return lastValue / value
end

--#tag ReverseDividie
function DefaultNodeFunctions.ReverseDivide(lastValue, value)
	return value / lastValue
end

function DefaultNodeFunctions.Power(lastValue, value)
	return lastValue ^ value
end

--#tag ReversePower
function DefaultNodeFunctions.ReversePower(lastValue, value)
	return value ^ lastValue
end

function DefaultNodeFunctions.Lerp(lastValue, value, customData)
	return LinearInterpolation.byType(lastValue, value, customData.Alpha)
end

local Scale = require(script.Scale)
DefaultNodeFunctions.Scale = Scale.byType


--#region Logic
function DefaultNodeFunctions.And(lastValue, value)
	return lastValue and value
end

function DefaultNodeFunctions.Or(lastValue, value)
	return lastValue or value
end

function DefaultNodeFunctions.ReverseAnd(lastValue, value)
	return value and lastValue
end

function DefaultNodeFunctions.ReverseOr(lastValue, value)
	return value or lastValue
end

--#region Comparsion
DefaultNodeFunctions.Min = require(script.Min).byType

DefaultNodeFunctions.Max = require(script.Max).byType


--#region CFrame
function DefaultNodeFunctions.SetCFrameRotation(lastValue: CFrame, value: CFrame): CFrame
	return value + lastValue.Position
end

function DefaultNodeFunctions.SetCFramePosition(lastValue: CFrame, value: Vector3): CFrame
	return lastValue.Rotation + value
end

function DefaultNodeFunctions.MultiplyToRotation(lastValue: CFrame, value: CFrame): CFrame
	return lastValue.Rotation * value + lastValue.Position
end

function DefaultNodeFunctions.ReverseMultiplyToRotation(lastValue: CFrame, value: CFrame): CFrame
	return value * lastValue.Rotation + lastValue.Position
end

return DefaultNodeFunctions