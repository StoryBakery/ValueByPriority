---
title: Node
sidebar_position: 2
---

## 개요

`Node`는 `ValueByPriority` 내에서 각각의 값을 계산할 때 활용되는 **노드** 객체입니다.  
각 `Node`는 우선순위(Priority), 노드 함수(NodeFunction) 등의 설정에 따라 `ValueByPriority`의 결과값에 기여하며, 우선순위가 높을수록(값이 낮을수록) 최종 계산 순서상 뒤에서(나중에) 적용됩니다.

예를 들어, 우선순위가 가장 낮은 노드(우선순위 값이 가장 큰 노드)는 기본값(또는 더 낮은 우선순위 노드의 결과)에 먼저 연산을 적용하고, 그보다 우선순위가 더 높은 노드는 그 결과값에 다시 연산을 적용하여 최종값을 갱신하는 식으로 작동합니다.

노드는 대체로 다음과 같은 시나리오에서 활용됩니다:

- 여러 요소(장비, 버프, 환경 요소 등)가 동시에 캐릭터의 특정 스탯(체력, 이동 속도 등)을 변경하고자 할 때.
    
- 여러 우선순위 규칙(가장 마지막에 적용되는 큰 우선순위, “Set” 노드가 등장하면 이후 노드는 무시 등)을 적용하여 최종 결과를 결정하고자 할 때.

새로운 노드를 추가하려면 `ValueByPriority:AddNode(NodeParams)`를 호출합니다.  
`NodeFunction`은 선택 사항이며 기본값은 `"Set"`입니다.

```lua
local newNode = someVbp:AddNode({
	Value = 16,
	Priority = 10,
	NodeFunction = "Lerp",
	CustomData = {
		alpha = .5,
	},
})

-- 메타테이블 기능을 활용하면 다음과 같이 호출할 수 있습니다.
-- 그러나 자주 추천되진 않습니다.
local newNode = someVbp {
	Value = 16,
	Priority = 10,
	NodeFunction = "Lerp",
	CustomData = {
		alpha = .5
	},
}
```

## 사용

### 감지

노드는 값을 결정하는 용도 뿐만이 아니라 중간 값의 감지 용도로도 사용 가능합니다

```lua
local detectionNode = vbp:AddNode({
	Value = nil,
	NodeFunction = script.FireOnValueIsFire,
	Priority = 100,
	CustomData = {
		FireValueDetectedBeforePriority100Event = bindableEvent,
	},
})
```

```lua
-- in Detect ModuleScript

return function(lastRes, value, customData)
	if lastRes == "Fire" then
		customData.FireValueDetectedBeforePriority100Event:Fire()
	end
	return lastRes
end
```

<Alert severity="warning">
감지 노드의 이전 노드가 업데이트돼도 감지를 무시할 수 있습니다
중간 노드의 `NodeFunction`이 `Set`일 경우 그 이전 노드들을 계산하지 않는 내부 최적화를 비활성화하지 않았다면 
감지 노드도 무시될 수 있습니다.
감지 노드가 무시되지 않길 원한다면 꼭 Vbp의 최적화를 비활성화하셔야합니다
</Alert>


### 여러 단계에 걸친 노드

Vbp 에 특정 객체가 어떤 Priority를 가지고 그에 대한 노드를 생성해 Vbp 에 영향을 끼치는 경우가 많습니다

예시로 들자면 카메라 컨트롤러 A 가 카메라 CFrame Vbp 에 노드를 두고, 해당 노드의 Priority는 컨트롤러의 Priority와 연결됩니다
```lua
function CameraController:_createCameraCFrameNode()
	local node = CameraCFrameVbp:AddNode({
		Value = CFrame.identity,
		NodeFunction = "Multiply",
		Priority = self.Priority,
	})
	
	self.PriorityChanged:Connect(function()
		node:SetPriority(self.Priority)
	end)
	
	-- ...
end
```

이렇게 설계하면 Controller가 여러개이면 각 Controller의 우선 순위에 따라 여러 동작을 할 수 있고
한 컨트롤러가 통일된 Priority를 가질 수 있어, 여러 Vbp에 여러 노드를 생성할 때 Priority를 통일할 수 있습니다

하지만 만약 한 Vbp에 여러 node를 갖게 하고 싶다면 어떻게 할까요?
```lua
task.delay(math.random(), function()
	local node1 = CameraCFrameVbp:AddNode({
		Value = CFrame.new(0, 10, 0) * CFrame.Angles(math.pi, -math.pi*1.5, 0),
		NodeFunction = "Multiply",
		Priority = self.Priority,
	})
	
	self.PriorityChanged:Connect(function()
		node1:SetPriority(self.Priority)
	end)
end)

task.delay(math.random(), function()
	local node2 = CameraCFrameVbp:AddNode({
		Value = CFrame.new(0, 10, 0) * CFrame.Angles(0, math.pi/4, -math.pi/2),
		NodeFunction = "Multiply",
		Priority = self.Priority,
	})
	
	self.PriorityChanged:Connect(function()
		node1:SetPriority(self.Priority)
	end)
end)
```

이렇게 시간 순서를 맞추지 않고 노드를 생성하면 어떤 노드가 먼저 적용될지 알 수 없습니다
행렬 (CFrame) 의 곱셈처럼 순서가 바뀌면 결과가 바뀌는 NodeFunction 들의 경우 순서가 중요하기에, 원하는 Node에 우선 순위를 높여야합니다

하지만 노드들은 Controller의 우선순위를 받고, 여러 컨트롤러가 있을 경우를 상정해야하기에 Priority 를 다르게 할 수 없습니다

이럴 때는 컨트롤러에 새로운 ValueByPriority 를 만들고, 해당 ValueByPriority에 노드들을 생성합니다.

기존에 영향을 줘야할 Vbp에는 새로운 Vbp 의 값을 받는 노드를 생성해서 전달해줍니다

```lua
local controllerCameraCFrameVbp = ValueByPriority.new(vbpParams)
self.Destroying:Connect(function()
	controllerCameraCFrameVbp:Destroy()
end)

local node1 = controllerCameraCFrameVbp:AddNode({
	Value = CFrame.new(0, 10, 0) * CFrame.Angles(math.pi, -math.pi*1.5, 0),
	NodeFunction = "Multiply",
	Priority = 1,
})
local node2 = controllerCameraCFrameVbp:AddNode({
	Value = CFrame.new(0, 10, 0) * CFrame.Angles(0, math.pi/4, -math.pi/2),
	NodeFunction = "Multiply",
	Priority = 0,
})

local nodeToCameraCFrameVbp = CameraCFrameVbp:AddNode({
	Value = controllerCameraCFrameVbp:GetValue()
	Nodefunction = "Multiply",
	Priority = self.Priority,
})
controllerCameraCFrameVbp.Changed:Connect(function(new)
	nodeToCameraCFrameVbp:SetValue(new)
end)
})
self.PriorityChanged:Connect(function()
	node:SetPriority(self.Priority)
end)
```

이렇게하면 한 컨트롤러 내에서도 다른 컨트롤러와의 우선 순위를 지킬 수 있고, 순서에 맞게 여러 노드를 가질 수 있습니다.

> [!Warning] 실수 Priority Offset은 최대한 피하세요
> 
> 아주 작은 실수값을 주면 되지 않냐고 생각할 수 있지만
> 가독성이 떨어지며, 똑같은 우선순위의 컨트롤러가 있다면 서로 중복돼서 예상치 못한 결과를 가져올 수 있습니다.
> 
> ```lua
> local node1 = controllerCameraCFrameVbp:AddNode({
> 	Value = CFrame.new(0, 10, 0) * CFrame.Angles(math.pi, -math.pi*1.5, 0),
> 	NodeFunction = "Multiply",
> 	Priority = self.Priority + 0.01,
> })
> self.PriorityChanged:Connect(function()
> 	node1:SetPriority(self.Priority + 0.01)
> end)
> 
> local node2 = controllerCameraCFrameVbp:AddNode({
> 	Value = CFrame.new(0, 10, 0) * CFrame.Angles(0, math.pi/4, -math.pi/2),
> 	NodeFunction = "Multiply",
> 	Priority = self.Priority,
> })
> self.PriorityChanged:Connect(function()
> 	node2:SetPriority(self.Priority)
> end)
> ```



# Constructors

## new

```lua
(ValueByPriority: ValueByPriority, params: NodeParams) -> Node
```

`ValueByPriority`에 새 노드를 생성하여 추가합니다. 생성된 `Node`는 지정된 우선순위, 노드 함수 등을 사용해 `ValueByPriority`의 최종값 계산에 참여하게 됩니다.

```lua
local vbp = ValueByPriority.new({
    Default = 10
})

local node = Node.new(vbp, {
    Value = 20,
    Priority = 50,
    NodeFunction = "Add",  -- DefaultNodeFunctions.Add
})
```

주로 `:AddNode(params)` 또는 `vbp(params)` (호출 연산자)로도 노드 생성이 가능합니다.

```lua
local node2 = vbp:AddNode({
    Value = 5,
    Priority = 100,
    NodeFunction = "Multiply",
})

-- 호출 연산자를 통한 생성
local node3 = vbp {
    Value = 7,
    Priority = 30,
    NodeFunction = "Set",
}
```

### NodeParams

```lua
{
    Value: any,
    Priority: number,
    NodeFunction: NodeFunction?,
    CustomData: { [any]: any }?,
    NotReplicated: boolean?,
}
```


### Priority
`number`

우선순위가 높을수록 나중에 적용됩니다.

> [!Tip] **동일한 우선순위를 가진 노드**  
> 같은 우선순위를 가지는 경우, 가장 최근에 생성된 노드가 높은 우선순위를 가집니다.
> 
> ```lua
> Nodes[1] = {
> 	Priority = 100,
> 	CreatedTime = 1000,
> }
> Nodes[2] = {
> 	Priority = 100,
> 	CreatedTime = 1002,
> }
> ```

`ValueByPriority`는 `Enum.Priority`를 제공하여 쉽게 관리할 수 있습니다.

### NodeFunction
`string`

`NodeFunction`은 선택 사항이며 기본값은 `"Set"`입니다.


**지원하는 `NodeFunction` 유형**:
- **Set**: `result = NodeValue`
- **Add**: `result = LastValue + NodeValue`
- **Subtract**: `result = LastValue - NodeValue`
- **Multiply**: `result = LastValue * NodeValue`
- **ReverseMultiply**: `result = NodeValue * LastValue`
- **Divide**: `result = LastValue / NodeValue`
- **Power**: `result = LastValue ^ NodeValue`
- **Lerp**: `result = LastValue + (NodeValue - LastValue) * CustomData.Alpha`
그 외는 [[NodeFunctions]] 를 참고해주세요.

#### 사용자 정의 `NodeFunction`

사용자 정의 노드를 사용하려면 모듈을 만들어야 합니다.

```lua
-- CustomNodeFunction 모듈:
return function(
	lastValue: any, 
	value: any, 
	customData: {[string]:any}?, 
	vbp: ValueByPriority.ValueByPriority,
	node: ValueByPriority.Node, 
	nodeIndex: number
)
	local result
	-- 결과 값 계산 코드
	return result
end

-- Parent Script에서:
local node = valueByPriority:AddNode({
	Priority = 1,
	Value = 1,
	NodeFunction = script.CustomNodeFunction
})
```

> [!Warning] **Lua 함수는 직접 사용할 수 없음**  
> 병렬 계산과 클라이언트-서버 통신을 위해 Lua 함수는 직접 사용할 수 없습니다.  
> `NodeFunction`은 반드시 모듈 스크립트로 정의해야 합니다.

주로 `lastValue` 와 `value` 를 쓰며, 복잡한 커스텀 `NodeFunction` 의 경우 `CustomData` 까지 쓰고,
`vbp`, `node`, `nodeIndex` 는 거의 사용하지 않습니다.

# Properties

아래는 `Node` 객체가 가지는 주요 속성입니다.

### IsDestroyed

`boolean`

노드가 이미 파괴(`:Destroy()`)되었는지 여부.  
`true`인 경우, 더 이상 `Node`를 통해 `ValueByPriority` 결과값에 영향을 주지 않습니다.

### Destroying

`Signal<>()`

`Node`가 파괴될 때(`:Destroy()` 시) 한 번만 발동되는 시그널입니다.  
연결된 콜백은 노드 소멸 직전에 호출됩니다.

### ValueByPriority

`ValueByPriority`

이 `Node`가 포함되어 있는 `ValueByPriority` 객체입니다.

### Value

`any`

노드가 적용하려는 주된 값입니다.  
(예: 10, Vector3 값, Color3 값 등)

### ValueChanged
`Signal.ChangedSignal<any>`

`Node`의 `Value`가 `:SetValue`로 인해 갱신될 때마다 `(newValue)`를 전달하며 발생하는 시그널입니다.

### Priority
`number`

`Node`의 우선순위 값.  
**값이 낮을수록 최종 결과값에 ‘나중에’ 적용되는 노드**입니다.  
다른 노드와 `Priority`가 같을 경우, `CreatedTime`(생성 시점)이 빠른 쪽이 먼저(더 우선순위가 낮은 것으로) 계산됩니다.

### PriorityChanged
`Signal.ChangedSignal<number>`

노드의 `Priority`가 `:SetPriority`로 인해 변경될 때마다 `(newPriority)`를 전달하며 발생하는 시그널입니다.

### NodeFunction
`string | ModuleScript`

`Node`가 적용될 때 사용하는 연산 함수를 나타냅니다.  
기본적으로 `DefaultNodeFunctions`에 `"Set", "Add", "Multiply"` 등의 문자열을 넣을 수 있으며, 모듈 스크립트(require)로 커스텀 로직을 구현할 수도 있습니다.

### CustomData
`{ [any]: any }`

노드 연산 시 필요한 추가 데이터를 저장하는 테이블입니다.  
예: 보간 계수(`alpha`), 노드별 스탯 정보, 특정 ‘배수’값 등.  
`NodeFunction`이 “Lerp”인 경우 `CustomData = { alpha = 0.5 }` 등으로 보간 계수를 넘길 수 있습니다.

[[#SetCustomData]] 로 설정합니다.

### CustomDataChanged
`Signal.SignalBase<(key: string, newValue: any)->(), string, any>`

[[#SetCustomData]] 로 노드의 `CustomData` 의 `Key` 값이 바뀌었을 때 발동하는 시그널입니다.

### Reliability
`"Reliable"|"Unreliable"`

- `"Reliable"`: 반드시 전달 (TCP 유사)
- `"Unreliable"`: 손실될 수 있음 (UDP 유사)
    
서버/클라이언트에서 클라이언트/서버로 노드의 값 변경을 어떤 식으로 보내는지 입니다.
`"Reliable"` 이면 일반적인, Reliable한 RemoteEvent 를 통해 값 변경을 보내고
`"Unreliable"` 이면 Unreliable한 RemoteEvent 를 통해 값 변경을 보냅니다.

매프레임마다 바뀌는 노드의 경우엔 `"Unreliable"` 로 하면 대역폭을 아낄 수 있습니다.

기본적으로 `"Reliable"`.

### ReliabilityChanged
`Signal.ChangedSignal<Reliability>`

`SetReliability`로 `Reliability`가 변경될 때마다 발동되는 시그널입니다.

### CreatedTime
`number`

Roblox `workspace:GetServerTimeNow()` 기준으로 노드가 생성된 시점을 나타냅니다.
우선순위가 같은 노드들은 가장 최근에 생성된 노드가 높은 우선순위를 가집니다.
이를 확인하기 위한 속성.

### NotReplicated
`boolean`

`ValueByPriority` 가 서버와 동기화중이며, 서버에서 클라이언트로 복제할 때, 
해당 노드가 클라이언트로 복제될지 안될지 여부입니다.

노드를 생성할 때 `newParams.NotReplicated = new`를 통해 설정할 수 있습니다.

### `_nodeId`
`number`

`int16` 으로 저장됩니다.
서버에서 생성하는 노드의 Id 는 $[0, 2^{15}-1]$
클라이언트에서 생성하는 노드의 Id 는 $[-2^{15}, -1]$ 입니다.

동기화 작업시 서로 중첩되는 것을 막기 위함.



# Methods

## Destroy
```lua
() -> ()
```

노드를 파괴합니다. 파괴된 노드는 `ValueByPriority`의 최종 계산에 더 이상 참여하지 않습니다.

```lua
node:Destroy()
```

## GetPriority
```lua
() -> (number)
```

노드의 현재 우선순위를 반환합니다.

## SetPriority
```lua
(priority: number) -> ()
```

노드의 우선순위를 변경합니다.  
값이 낮을수록 최종 결과에 더 ‘나중’에 적용되는 점에 유의하세요.

```lua
node:SetPriority(25)
```

## GetValue
```lua
() -> (any)
```

노드의 `Value`를 반환합니다.

## SetValue
```lua
(value: any) -> ()
```

노드의 `Value`를 변경합니다.  
변경 시 `ValueChanged` 시그널이 발동하고, 노드가 실제로 `ValueByPriority`의 결과값에 반영되고 있었다면 전체 결과도 업데이트됩니다.

```lua
node:SetValue(100)
```

## SetCustomData
```lua
(key: string, value: any) -> ()
```

`CustomData` 테이블에 특정 속성(`key`)을 추가 또는 수정합니다.  
변경 시, 노드가 `ValueByPriority` 결과값에 반영되고 있었다면 결과 업데이트가 발생할 수 있습니다.

```lua
node:SetCustomData("alpha", 0.75)
```

## SetReliability
```lua
(reliability: Reliability) -> ()
```

노드의 신뢰도 수준(`"Reliable"|"Unreliable"`)을 설정합니다.  
서버-클라이언트 동기화 시 패킷 손실 등이 중요한 값이라면 `"Reliable"`로 설정하세요.

```lua
node:SetReliability("Unreliable")
```
