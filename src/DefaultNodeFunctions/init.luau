--!native
--[=[
	이 문서는 ValueByPriority에서 기본적으로 제공되는 **NodeFunctions** 모듈에 대한 설명입니다.
	  
	`NodeFunction`은 기존 값(`lastValue`)과 새로 전달받은 값(`value`)을 조합하여 최종 결과값을 도출할 때 사용되는 함수입니다.  
	노드를 추가할 때 `NodeFunction`을 지정함으로써, 어떤 방식으로 기존 값과 새 값을 결합할지 결정할 수 있습니다.
]=]

local LinearInterpolation = require("../roblox_packages/LinearInterpolation")
local Signal = require("../roblox_packages/Signal")
local TableUtil = require("../roblox_packages/TableUtil")

local DefaultNodeFunctions = {}

export type DefaultNodeFunction = keyof<typeof(DefaultNodeFunctions)>

--[=[
	@group Set
	단순히 **value**로 결과값을 설정합니다.  
	`lastValue`는 무시됩니다.
]=]
function DefaultNodeFunctions.Set(_, value)
	return value
end

--[=[
	@group Set
	`value`가 `nil`인 경우에는 `lastValue`를 그대로 유지하고, 그 외에는 `value`로 설정합니다.
]=]
function DefaultNodeFunctions.SetOrPassOnNil(lastValue, value)
	return if value == nil then lastValue else value
end

--[=[
	@group Set
	아래 노드들이 WeightedSet 인 노드들이고 Priority 가 같다면
	그 노드들의 값을 모두 합산하여, Weight 에 맞게 분배된 값을 반환합니다
]=]
function DefaultNodeFunctions.WeightedSet(_, value, customData, vbp, node)
	local valueAndWeightPairs = {}
	local priority = node.Priority

	-- WeightedSet 은 무조건적으로 _affectingLowestNodeIndex 가 1인 노드
	-- 아래 노드들이 WeightedSet 인 노드들이고 Priority 가 같다면
	-- 그 노드들의 값을 모두 합산하여, 그 값을 반환합니다
	for i = vbp._affectingLowestNodeIndex, 1, -1 do
		local otherNode = vbp.Nodes[i]
		if otherNode.Priority == priority and otherNode.NodeFunction == "WeightedSet" then
			table.insert(valueAndWeightPairs, { otherNode.Value, otherNode.CustomData.Weight })
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

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.Add(lastValue, value)
	return lastValue + value
end

--[=[
	@group Operations
	
	실수·벡터 등 교환법칙이 성립하는 자료형에서는 일반 `Classes.DefaultNodeFunctions.Add` 와 동일한 결과지만,
	CFrame 이나 커스텀 `__add` 가 있는 자료형 테이블의 경우엔 결과가 달라지기에 분리되었습니다.
]=]
function DefaultNodeFunctions.ReverseAdd(lastValue, value)
	return value + lastValue
end

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.Subtract(lastValue, value)
	return lastValue - value
end

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.ReverseSubtract(lastValue, value)
	return value - lastValue
end

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.Multiply(lastValue, value)
	return lastValue * value
end

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.ReverseMultiply(lastValue, value)
	return value * lastValue
end

--[=[
	@group Operations
	
	0으로 나누는 경우는 런타임 오류가 발생할 수 있으므로 주의가 필요합니다.
]=]
function DefaultNodeFunctions.Divide(lastValue, value)
	return lastValue / value
end

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.ReverseDivide(lastValue, value)
	return value / lastValue
end

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.Power(lastValue, value)
	return lastValue ^ value
end

--[=[
	@group Operations
]=]
function DefaultNodeFunctions.ReversePower(lastValue, value)
	return value ^ lastValue
end

--[=[
	@group Operations
	`customData.Alpha` 를 이용해 두 값 사이를 선형 보간합니다.  
	벡터, Color3, UDim2 등을 보간할 수 있도록 내부적으로 [LinearInterpolation](https://github.com/StoryBakery/LinearInterpolation) 모듈을 사용합니다.
]=]
function DefaultNodeFunctions.Lerp(lastValue, value, customData)
	return LinearInterpolation.byType(lastValue, value, customData.Alpha)
end

local Scale = require(script.Scale)

--[=[
	@group Operations
	`value`(배율)만큼 `lastValue`를 스케일(확대·축소)합니다.  
	벡터, NumberRange, NumberSequence 등 다양한 타입을 지원합니다.
]=]
DefaultNodeFunctions.Scale = Scale.byType

--[=[
	@group Logic
	Lua 논리 연산의 `and`와 동일하게 처리합니다.  
]=]
function DefaultNodeFunctions.And(lastValue, value)
	return lastValue and value
end

--[=[
	@group Logic
	Lua 논리 연산의 `or`와 동일하게 처리합니다.  
]=]
function DefaultNodeFunctions.Or(lastValue, value)
	return lastValue or value
end

--[=[
	@group Logic
	순서를 반대로한 `and` 입니다. 
]=]
function DefaultNodeFunctions.ReverseAnd(lastValue, value)
	return value and lastValue
end

--[=[
	@group Logic
	순서를 반대로한 `or` 입니다.
]=]
function DefaultNodeFunctions.ReverseOr(lastValue, value)
	return value or lastValue
end

--[=[
	@group Comparsion
	`lastValue`와 `value` 중 더 **작은** 값을 반환합니다.  
	`DataType.number`, `DataType.Vector2`, `DataType.Vector3`, `DataType.UDim`, `DataType.Color3` 등에 대한 최소 연산을 지원합니다.
]=]
DefaultNodeFunctions.Min = require(script.Min).byType

--[=[
	@group Comparsion
	`lastValue`와 `value` 중 더 **큰** 값을 반환합니다.  
	`DataType.number`, `DataType.Vector2`, `DataType.Vector3`, `DataType.UDim`, `DataType.Color3` 등에 대한 최대 연산을 지원합니다.
]=]
DefaultNodeFunctions.Max = require(script.Max).byType

--[=[
	@group CFrame
	`value`의 **회전**을 사용하되, 위치(`Position`)는 `lastValue`를 유지합니다.
]=]
function DefaultNodeFunctions.SetCFrameRotation(lastValue: CFrame, value: CFrame): CFrame
	return value + lastValue.Position
end

--[=[
	@group CFrame
	`lastValue`의 **회전**을 유지하고, 위치만 `value`로 설정합니다.
]=]
function DefaultNodeFunctions.SetCFramePosition(lastValue: CFrame, value: Vector3): CFrame
	return lastValue.Rotation + value
end

--[=[
	@group CFrame
	`lastValue`의 회전(`Rotation`)에 `value` CFrame을 곱한 뒤, `lastValue`의 위치를 더합니다.
]=]
function DefaultNodeFunctions.MultiplyToRotation(lastValue: CFrame, value: CFrame): CFrame
	return lastValue.Rotation * value + lastValue.Position
end

--[=[
	@group CFrame
	`value`에 `lastValue`의 회전을 곱한 뒤, 다시 `lastValue.Position`을 더합니다.
]=]
function DefaultNodeFunctions.ReverseMultiplyToRotation(lastValue: CFrame, value: CFrame): CFrame
	return value * lastValue.Rotation + lastValue.Position
end

return DefaultNodeFunctions
