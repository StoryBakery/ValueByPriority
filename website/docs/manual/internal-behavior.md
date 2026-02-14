---
title: 내부 동작
sidebar_position: 20
---

# 내부 동작

이 섹션에서는 `ValueByPriority` 의 내부 구현을 설명합니다.

<Alert severity="Warning">
내부 코드가 지속적으로 업데이트되므로, 이 내용은 최신 버전과 다를 수 있습니다.  
이해를 돕기 위한 자료이며, 현재 사용 중인 버전과 다를 가능성이 있습니다.
</Alert>

## Deferred 를 이용한 최적화

1. **DefaultValue**로 시작.
2. **우선순위가 낮은 노드부터** 높은 노드 순으로 순회.
3. 각 노드의 `NodeFunction(lastValue, nodeValue, nodeCustomData)`를 호출.
4. 결과를 갱신.
5. 모든 노드를 처리 후 최종 결과값을 **Changed** 시그널로 방출.

기본적으로 변경 즉시 갱신하지 않고, `task.defer()`로 한번에 묶어서 업데이트(Deferred)합니다.  
`UpdateBehavior`가 `"Immediate"`라면 노드나 DefaultValue 변경 시 바로 결과를 갱신합니다.

만약 한 프레임 안에 여러 번 노드를 추가·제거·수정하는 경우, `"Deferred"` 모드가 큰 이점을 제공합니다.  
모든 변경이 끝난 뒤에 단 한 번만 최종 결과 계산이 이루어지므로, **성능 부담을 줄이고** 과도한 변경 시그널 방출을 방지할 수 있습니다.

```lua
local vbp = ValueByPriority.new({
	UpdateBehavior = "Deferred",
	Default = 0,
})

vbp.Changed:Connect(function(newValue)
	print("최종값:", newValue)
end)

local node1 = vbp:AddNode({
	Value = 10, 
	Priority = 5,
})
local node2 = vbp:AddNode({
	Value = 5,
	Priority = 4,
})
local node3 = vbp:AddNode({
	Value = 0, 
	Priority = 1, 
	NodeFunction = "Set",
})

-- 여기까지 여러 노드를 추가했지만, 결과 계산은 스케줄 다음 Invocation point 한 번만 일어납니다.
```

그러므로 즉시 즉시 노드를 추가하고, 노드의 값을 변경해서, Vbp 의 값을 얻으려면
`UpdateBehavior` 를 `Immediate` 로 설정해야합니다.

그렇지 않은 대부분의 Vbp 들은 즉시 업데이트되지 않으니, Changed 와 같은 시그널에 의존해야합니다.
