---
title: ValueByPriority
sidebar_position: 1
---

## 개요

**ValueByPriority**(이하 **vbp**) 모듈은 우선순위를 기반으로 여러 `Classes.Node`의 값을 순차적으로 적용하여 최종 결과값을 결정하는 시스템을 제공합니다.  

게임 내 다양한 상황(예: 카메라 제어, 속성 최종 결정, 애니메이션 합성 등)에서, 여러 요소가 공존하여 “최종 결정값”이 필요한 경우 유용하게 활용할 수 있습니다.

## 노드별-결과-값

다음과 같은 `Classes.ValueByPriority` 구조를 고려해봅시다.

```lua
ValueByPriority
|- DefaultValue = Vector3.new(1, 5, 150)
|- Nodes
| |- Node1: {
       Priority = 0,
       Value = 100,
       NodeFunction = "Divide",
     }
| |- Node2: {
       Priority = 10,
       Value = Vector3.new(10, 150, 150),
       NodeFunction = "Set",
     }
| |- Node3: {
       Priority = 11,
       Value = 100,
       NodeFunction = "Divide",
     }
| |- Node4: {
       Priority = 160,
       CreatedTime = 0,
       Value = Vector3.new(0.3, 4.5, 0.5),
       NodeFunction = "Lerp",
       CustomData = {
         Alpha = .5,
       }
     }
| |- Node5: {
       Priority = 160,
       CreatedTime = 1,
       Value = workspace.Part,
       NodeFunction = script.fromPartRotation,
       CustomData = {
         InverseRotation = true,
       }
     }
```

초기에는 `ValueByPriority`가 `DefaultValue`, 즉 `Vector3.new(1, 5, 150)`에서 시작합니다.

```lua
result = self:GetDefaultValue()
```

각 노드는 결과 값을 수정합니다. 예를 들어:

```lua
Node1:
Priority = 0,
Value = 100,
NodeFunction = "Divide"

result = result / Node1.Value
```

이 경우, `Classes.ValueByPriority` 값은 `Vector3.new(1/100, 5/100, 150/100)`으로 변경됩니다. 이후의 노드들도 같은 방식으로 영향을 줍니다.

### 상세-예시-케이스
```lua
Node2:
Priority = 10,
Value = Vector3.new(10, 150, 150),
NodeFunction = "Set",

result = Node2.Value
= Vector3.new(10, 150, 150)
```

`Classes.ValueByPriority.NodeFunction`이 `"Set"`이면 낮은 우선순위의 노드와 `Classes.Node.DefaultValue`를 무시합니다.

```lua
Node3: 
Priority = 11,
Value = 100,
NodeFunction = "Divide"

result = result / Node3.Value
= Vector3.new(10/100, 150/100, 150/100)
= Vector3.new(0.1, 1.5, 1.5)
```

```lua
Node4:
Priority = 160,
CreatedTime = 0,
Value = Vector3.new(0.3, 4.5, 0.5),
NodeFunction = "Lerp",
CustomData = { Alpha = .5 }

result = lerp(result, Node4.Value, CustomData.Alpha)
= result + (Node4.Value - result) * CustomData.Alpha
= Vector3.new(0.1, 1.5, 1.5) + Vector3.new(0.2, 3, -1) * 0.5
= Vector3.new(0.2, 3, 1)
```

```lua
Node5:
Priority = 160,
CreatedTime = 1,
Value = workspace.Part,
NodeFunction = script.fromPartRotation,
CustomData = { InverseRotation = true }

-- fromPartRotation 모듈:
return function(lastValue, nodeValue, customData)
  local partRotation = part.CFrame.Rotation
  return if customData and customData.InverseRotation
  	then partRotation:Inverse() * lastValue
  	else partRotation * lastValue
end

-- ValueByPriority에서:
result = require(NodeFunction)(result, Node5.Value, CustomData)
= Node5.Value.CFrame.Rotation:Inverse() * result
```


<Alert severity="Warning">
우선순위 값에 부동소수(float) 사용 지양
`Priority`는 정수 또는 부동소수로 설정할 수 있지만, 부동소수를 사용할 경우 처리 과정이 복잡해질 수 있습니다. 가능한  정수를 사용하는 것이 좋습니다.
</Alert>

<Alert severity="Note">
실제 시스템의 동작은 내부 최적화로 인해 다르게 작동할 수도 있습니다.
</Alert>

