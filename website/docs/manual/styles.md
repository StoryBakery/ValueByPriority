---
title: 스타일
sidebar_position: 10
---

# 스타일

스타일은 개인마다 다를 수 있지만, 도큐먼트에서 통일된 관습을 제공하면 큰 고민 없이 최적의 플로우를 알 수 있습니다.

### 노드 생성

```lua
local node = vbp:AddNode({
	Value = 2,
	NodeFunction = "Multiply", -- 만약 NodeFunction 이 "Set" 이면 생략하기
	Priority = 1000,
})
```

Params 의 키 순서는 다음대로 합니다

1. Value (노드의 값이 제일 중요)
2. NodeFunction (노드가 무엇인지 알아야함)
3. Priority (우선 순위는 그다음)
4. CustomData 
5. 그 외 마이너한 키들...
