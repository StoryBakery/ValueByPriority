--!native
--[=[
	@class ValueByPriority

	**ValueByPriority**(이하 **vbp**) 모듈은 우선순위를 기반으로 여러 `Node`의 값을 순차적으로 적용하여 최종 결과값을 결정하는 시스템을 제공합니다.  

	게임 내 다양한 상황(예: 카메라 제어, 속성 최종 결정, 애니메이션 합성 등)에서, 여러 요소가 공존하여 “최종 결정값”이 필요한 경우 유용하게 활용할 수 있습니다.
]=]

local RunService = game:GetService("RunService")

local BufferBuilder = require("./roblox_packages/BufferBuilder")
local BufferReader = require("./roblox_packages/BufferReader")
local LinearInterpolation = require("./roblox_packages/LinearInterpolation")
local Promise = require("./roblox_packages/promise")
local Signal = require("./roblox_packages/Signal")
local TableUtil = require("./roblox_packages/TableUtil")

local Package = script

local Remotes = Package.Remotes
local syncFromServerEvent = Remotes.SyncFromServerEvent
local desyncFromServerEvent = Remotes.DesyncFromServerEvent

local DefaultNodeFunctions = require("@self/DefaultNodeFunctions")

local IS_SERVER = RunService:IsServer()
local EMPTY_FUNC = function() end

local ValueByPriority = {}
ValueByPriority.__index = ValueByPriority
ValueByPriority.__type = "ValueByPriority"

local Node = {}
Node.__index = Node
Node.__type = "Node"

export type VbpId = string
export type NodeId = number
export type Reliability = "Reliable" | "Unreliable"
type TypeInfo = {
	Name: string,
	TypeId: number,
	Serialize: (buf: buffer, offset: number, value: any) -> (),
	Deserialize: (buf: buffer, offset: number) -> any,
	TypeCheck: (value: any) -> boolean,
} & any

export type NodeFunction = DefaultNodeFunctions.DefaultNodeFunction | ModuleScript

local nodeFuncitonIdsByName = {}
ValueByPriority.NodeFunctionIdsByName = nodeFuncitonIdsByName
do
	local i = 0
	for k, func in DefaultNodeFunctions do
		nodeFuncitonIdsByName[k] = i
		i += 1
	end
end

export type RealNodeFunction = (
	lastResult: any,
	nodeValue: any,
	nodeCustomData: { [any]: any }
) -> any

--[=[
	Node 를 생성할 때 사용되는 파라미터입니다.
]=]
export type NodeParams<Value = any> = {
	--- 노드의 값
	Value: Value,
	--- 노드의 우선순위
	Priority: number,
	--- 노드의 연산 함수
	NodeFunction: NodeFunction?,
	--- 노드의 커스텀 데이터
	CustomData: { [string]: any }?,

	--- 노드가 복제되지 않도록 설정합니다.
	NotReplicated: boolean?,

	_bakedNodeId: NodeId?,
}

export type Node<Value = any> = setmetatable<
	{
		--- `Destroy()`가 호출되어 파괴된 상태인지 여부.
		IsDestroyed: boolean,
		--- Vbp가 파괴될 때 한 번 호출되는 신호입니다.
		Destroying: Signal.Signal<>,

		--- `Node`가 적용될 때 사용하는 연산 함수를 나타냅니다.
		NodeFunction: NodeFunction,
		--- 이 `Node`가 포함되어 있는 `ValueByPriority` 객체입니다.
		ValueByPriority: ValueByPriority,

		_vbpId: VbpId,
		_nodeId: NodeId,

		--- `ValueByPriority` 가 서버와 동기화중이며, 서버에서 클라이언트로 복제할 때, 해당 노드가 클라이언트로 복제될지 안될지 여부입니다.
		NotReplicated: boolean,

		--- 노드가 적용하려는 주된 값입니다.
		Value: Value,
		--- `Node`의 `Value`가 `:SetValue`로 인해 갱신될 때마다 `(newValue)`를 전달하며 발생하는 시그널입니다.
		ValueChanged: Signal.ChangedSignal<Value>,
		_valueChangedTime: number,

		GetValue: (self: any) -> Value,
		SetValue: (self: any, value: Value) -> (),

		CustomDataChanged: Signal.SignalBase<(key: string, newValue: any) -> (), string, any>,

		--- `Node`의 우선순위 값. 값이 낮을수록 최종 결과값에 ‘나중에’ 적용되는 노드입니다.
		Priority: number,
		--- 노드의 `Priority`가 `:SetPriority`로 인해 변경될 때마다 `(newPriority)`를 전달하며 발생하는 시그널입니다.
		PriorityChanged: Signal.ChangedSignal<number>,
		--- 서버/클라이언트에서 클라이언트/서버로 노드의 값 변경을 어떤 식으로 보내는지 입니다.
		Reliability: Reliability,
		--- `SetReliability`로 `Reliability`가 변경될 때마다 발동되는 시그널입니다.
		ReliabilityChanged: Signal.ChangedSignal<Reliability>,

		--- 노드가 생성된 시점을 나타냅니다.
		CreatedTime: number,
		_affectingLowestNodeIndex: boolean,
		_isAffectingVbp: boolean,
		_realNodeFunction: RealNodeFunction,
	},
	typeof(Node)
>

export type UpdateBehavior = "Immediate" | "Deferred"

export type ValueByPriority<Value = any> = setmetatable<
	{
		--- `Destroy()`가 호출되어 파괴된 상태인지 여부.
		IsDestroyed: boolean,
		--- Vbp가 파괴될 때 한 번 호출되는 신호입니다.
		Destroying: Signal.Signal<>,

		--- 최종 결과값이 변했을 때, 새로운 값을 전달하며 발생하는 신호입니다.
		Changed: Signal.ChangedSignal<Value>,
		--- `DefaultValue`가 변경되었을 때 발생하는 신호입니다.
		DefaultValueChanged: Signal.ChangedSignal<Value>,

		--- 디버깅용 문자열. 설정하지 않으면 Id를 표시합니다.
		Name: string?,
		--- Vbp의 전역 식별자. 이벤트 통신 등을 위해 전송 가능한 형태로 구성되어야 합니다.
		Id: VbpId?,

		--- `"Deferred"` 또는 `"Immediate"` 중 하나. Vbp의 업데이트 시점을 제어합니다.
		UpdateBehavior: UpdateBehavior,

		AddNode: (self: any, params: NodeParams<Value>) -> Node,
		--- 현재 이 Vbp에 등록된 모든 노드들의 배열입니다. 우선순위 낮은 순 → 높은 순으로 정렬됩니다.
		Nodes: { Node },
		--- Id 키 - 노드 값을 가지는 테이블입니다.
		NodesById: { [NodeId]: Node },
		--- `Node` 가 생성될 때 발동되는 시그널.
		NodeAdded: Signal.AddedSignal<Node>,
		--- `Node` 가 제거될 때 발동되는 시그널.
		NodeRemoved: Signal.RemovedSignal<Node>,

		_defaultValueChangedTime: number,

		_affectingLowestNodeIndex: number,

		_linkedPlayerSet: { [Player]: true },
		_linkedPlayerCount: number,

		_isUpdating: boolean,

		GetValue: (self: any) -> Value,
		SetDefaultValue: (self: any, value: Value) -> (),
		GetDefaultValue: (self: any) -> Value,

		DefaultValueReliability: Reliability,
		DefaultValueReliabilityChanged: Signal.ChangedSignal<Reliability>,
	},
	typeof(ValueByPriority)
>

type BaseValueByPriorityParams = {
	SyncFromServer: boolean?,
	UpdateBehavior: UpdateBehavior?,
	Replicatable: boolean?,
}

export type NewValueByPriorityParams<Value = any> = {
	Default: Value?,
	Id: VbpId?,
	Name: string?,
	TypeInfo: TypeInfo?,
} & BaseValueByPriorityParams

export type FindValueByPriorityParams = {} & BaseValueByPriorityParams

export type WaitValueByPriorityParams = {
	Timeout: number?,
} & BaseValueByPriorityParams

local vbpsById = {} :: { [VbpId]: ValueByPriority }
local waitingForVbpSignalsById = {} :: { [VbpId]: Signal.AddedSignal<ValueByPriority> }

local updatedVbpSet = {} :: { [ValueByPriority]: true }
local freeThreads: { thread } = {}

local function updateImmediately(self)
	updatedVbpSet[self] = nil
	local nodes = self.Nodes
	local res = self._defaultValue

	--Calculates the lowest priority node to the highest priority node
	--among the affecting nodes
	for i = self._affectingLowestNodeIndex, #nodes, 1 do
		local node = nodes[i]
		res = node._realNodeFunction(res, node.Value, node.CustomData, self, node, i)
	end

	if res ~= self._value then
		self._value = res
		self.Changed:Fire(res)
	end
end

local updateVbpImmediately = updateImmediately

local function runCallback(callback, thread, ...)
	callback(...)
	table.insert(freeThreads, thread)
end

local function yielder()
	while true do
		runCallback(coroutine.yield())
	end
end

local function readyToUpdate(self)
	if self.UpdateBehavior == "Immediate" then
		updateImmediately(self)
		return
	end

	if updatedVbpSet[self] then
		return
	end

	updatedVbpSet[self] = true

	local thread
	if #freeThreads > 0 then
		thread = freeThreads[#freeThreads]
		freeThreads[#freeThreads] = nil
	else
		thread = coroutine.create(yielder)
		coroutine.resume(thread)
	end

	task.defer(thread, updateVbpImmediately, thread, self)
end

--[=[
	새로운 vbp 객체를 생성합니다. 기본값(`DefaultValue`)부터 설정할 수 있으며, `Id`나 `UpdateBehavior` 등을 지정할 수 있습니다.
]=]
function ValueByPriority.new<Value>(params: NewValueByPriorityParams<Value>): ValueByPriority<Value>
	local self = setmetatable({}, ValueByPriority)

	self.IsDestroyed = false
	self.Destroying = Signal.new()

	self.UpdateBehavior = params.UpdateBehavior or "Deferred"

	local default = params.Default
	self._defaultValue = default
	self._defaultValueChangedTime = 0
	self._value = default
	self.Changed = Signal.Immediate.new()

	self.DefaultValueChanged = Signal.new()

	self._isUpdating = false

	self.Name = params.Name
	self.TypeInfo = params.TypeInfo

	self.DefaultValueReliabilityChanged = Signal.new()
	self:SetDefaultValueReliability("Reliable")

	local id = params.Id

	if id then
		self.Id = id
		if vbpsById[id] then
			error(`Cannot use same Id "{id}" for ValueByPriority "{self}"`)
		end
		vbpsById[id] = self
		self.Destroying:ConnectUnyielding(function()
			vbpsById[id] = nil
		end)
	end

	self.Nodes = {}
	self.NodesById = {}
	self.NodeAdded = Signal.new()
	self.NodeRemoved = Signal.new()

	self._affectingLowestNodeIndex = 1
	if IS_SERVER then
		self._linkedPlayerSet = {}
		self._linkedPlayerCount = 0
	end

	if params.SyncFromServer then
		self:SyncFromServer()
	end

	readyToUpdate(self)

	--[[
		WaitForId 기다리는 시그널에 보내고,
		시그널은 해당 Id로 새로운 Vbp 가 할당되지 않는 한 
		더이상 사용되지 않으므로 삭제합니다.
	]]
	if id and waitingForVbpSignalsById[id] then
		local waitingForVbpSignal = waitingForVbpSignalsById[id]
		waitingForVbpSignal:Fire(self)
		waitingForVbpSignal:Destroy()
		waitingForVbpSignalsById[id] = nil
	end

	return self
end

--[=[
	주어진 `id`를 가진 ValueByPriority가 이미 존재한다면 반환합니다. 존재하지 않으면 `nil`을 반환합니다.
]=]
function ValueByPriority.FindById(id: VbpId, params: FindValueByPriorityParams?): ValueByPriority?
	return vbpsById[id]
end

--[=[
	`FindById`와 동일하게 `id`를 통해 Vbp를 찾되, 없으면 에러를 일으킵니다.
]=]
function ValueByPriority.byId<Value>(id: VbpId, params: FindValueByPriorityParams?): ValueByPriority
	return vbpsById[id] or error(`ValueByPriority with Id "{id}" not found.`)
end

--[=[
	`id`를 가진 Vbp가 없다면 새로 만들고, 있다면 해당 Vbp를 반환합니다.  
	두 번째 반환값으로 새로 생성되었는지 여부(boolean)를 제공합니다.
]=]
function ValueByPriority.findOrCreate<Value>(
	id: VbpId,
	params: NewValueByPriorityParams<Value>?
): (ValueByPriority<Value>, boolean)
	local vbp = ValueByPriority.FindById(id, params)
	if vbp then
		return vbp, false
	end

	local mergedParams =
		TableUtil.merge({ Id = id } :: { [any]: any }, (params :: { [any]: any }?) or {})

	return ValueByPriority.new(mergedParams), true
end

--[=[
	지정한 `id`를 가진 Vbp가 등장할 때까지 대기합니다.  
	`params.Timeout`이 설정되어 있으면 제한 시간 내에 등장하지 않으면 에러가 발생합니다.
]=]
function ValueByPriority.WaitForId(id: VbpId, params: WaitValueByPriorityParams?): ValueByPriority
	local vbp = ValueByPriority.FindById(id)
	if vbp then
		return vbp
	end

	local timeout = params and params.Timeout

	local signal = waitingForVbpSignalsById[id]
	if not signal then
		signal = Signal.new()
		waitingForVbpSignalsById[id] = signal
	end

	if timeout then
		local suc
		_, vbp = Promise.fromEvent(signal):timeout(timeout):await()
		return vbp
	end

	vbp = signal:Wait()

	return vbp
end

function ValueByPriority:_getReplicatableNodes(): { Node }
	local nodes = {}
	for i, v in self.Nodes do
		if v.NotReplicated then
			continue
		end
		table.insert(nodes, v)
	end
	return nodes
end

--[=[
	현재 Vbp를 파괴합니다.  
	연결된 노드들도 모두 정리하고, 내부에서 등록해둔 `KeyStore` 정보도 제거합니다.

	모든 Vbp 들은 사용이 끝나면 `:Destroy()` 를 해줘야합니다.
	그렇지 않으면 **영원히 삭제**되지 않습니다!
]=]
function ValueByPriority:Destroy()
	if self.IsDestroyed then
		return
	end

	self.IsDestroyed = true
	self.Changed:Destroy()

	self._update = EMPTY_FUNC
	self._updateImmediately = EMPTY_FUNC

	if self._isSyncedFromServer then
		self:DesyncFromServer()
	end

	for i, node in self.Nodes do
		node:Destroy()
	end

	self.Destroying:Fire()
	self.Destroying:Destroy()
end

do
	local idsToSyncBuilder = BufferBuilder.new()
	local isReadyToFire = false

	--[=[
		**클라이언트 전용** 메서드로, 서버와 동기화 여부를 설정합니다.  
		서버에서 해당 Vbp를 관리 중이라면, 값 변경 정보를 자동으로 전송받아 클라이언트 측 Vbp가 업데이트됩니다.
		서버와 클라이언트가 동일한 Id 를 공유해야하는 조건이 있습니다.
	]=]
	function ValueByPriority:SyncFromServer()
		if self._isSyncedFromServer then
			return
		end
		assert(not IS_SERVER, `Only Client can call :SyncFromServer().`)
		if self.Id == nil then
			error(`ValueByPriority "{self}" with an empty ID can't be synced.`)
		end

		self._isSyncedFromServer = true
		idsToSyncBuilder:WriteU16(#self.Id)
		idsToSyncBuilder:WriteString(self.Id)

		if not isReadyToFire then
			isReadyToFire = true
			task.wait()

			syncFromServerEvent:FireServer(idsToSyncBuilder:Build())
			idsToSyncBuilder = BufferBuilder.new()
			isReadyToFire = false
		end
	end
end
do
	local idsToDesyncBuilder = BufferBuilder.new()
	local isReadyToFire = false

	--[=[
		**클라이언트 전용** 메서드로, 서버와 동기화 여부를 설정합니다.  
		동기화중이라면, 더이상 동기화하지 않는다고 서버에 전송한 뒤, 서버 VBP 와의 동기화를 끊습니다.
	]=]
	function ValueByPriority:DesyncFromServer()
		if not self._isSyncedFromServer then
			return
		end
		assert(not IS_SERVER, `Only Client can call :DesyncFromServer().`)
		if self.Id == nil then
			error(`ValueByPriority "{self}" with an empty ID can't be synced.`)
		end

		self._isSyncedFromServer = false
		idsToDesyncBuilder:WriteU16(#self.Id)
		idsToDesyncBuilder:WriteString(self.Id)

		if not isReadyToFire then
			isReadyToFire = true
			task.wait()
			desyncFromServerEvent:FireServer(idsToDesyncBuilder:Build())
			idsToDesyncBuilder = BufferBuilder.new()
			isReadyToFire = false
		end
	end
end

function ValueByPriority:SetSerializaion(serializeFunction: (value: any) -> any)
	self._serializaion = serializeFunction
end

function ValueByPriority:SetDeserialization(deserializeFunction: (serialized: any) -> any)
	self._deserializaion = deserializeFunction
end

--[=[
	현재 최종 결과값을 반환합니다.
]=]
function ValueByPriority:GetValue()
	return self._value
end

function ValueByPriority:__tostring()
	return self.Name or self.Id
end

--[=[
	`DefaultValue`를 새 값으로 변경합니다.  
	우선순위가 가장 낮은 노드의 역할을 하는 값이므로, 이후 노드들이 없거나 모두 제거된 경우 최종 값에 직접적으로 영향을 줍니다.
]=]
function ValueByPriority:SetDefaultValue(value)
	if self._defaultValue == value then
		return
	end

	self._defaultValue = value
	self._defaultValueChangedTime = time()
	if self._affectingLowestNodeIndex == 1 then
		readyToUpdate(self)
	end

	self.DefaultValueChanged:Fire(value)
end

--[=[
	현재 설정된 `DefaultValue`를 반환합니다.
]=]
function ValueByPriority:GetDefaultValue()
	return self._defaultValue
end

function ValueByPriority:SetDefaultValueReliability(reliability: Reliability): ()
	if self.DefaultValueReliability == reliability then
		return
	end
	self.DefaultValueReliability = reliability
	self.DefaultValueReliabilityChanged:Fire(reliability)
end

--[=[
	업데이트 방식을 `"Deferred"` ↔ `"Immediate"`로 변경합니다.
]=]
function ValueByPriority:SetUpdateBehavior(updateBehavior: UpdateBehavior)
	self.UpdateBehavior = updateBehavior
end

local NODE_ID_RANDOM_GENERATOR = Random.new()

--[=[
	@class Node
	
	`Node`는 `ValueByPriority` 내에서 각각의 값을 계산할 때 활용되는 **노드** 객체입니다.  
	각 `Node`는 우선순위(Priority), 노드 함수(NodeFunction) 등의 설정에 따라 `ValueByPriority`의 결과값에 기여하며, 우선순위가 높을수록(값이 낮을수록) 최종 계산 순서상 뒤에서(나중에) 적용됩니다.
]=]

--[=[
	`ValueByPriority`에 새 노드를 생성하여 추가합니다. 생성된 `Node`는 지정된 우선순위, 노드 함수 등을 사용해 `ValueByPriority`의 최종값 계산에 참여하게 됩니다.
]=]
function Node.new(vbp: ValueByPriority, params: NodeParams): Node
	local self = setmetatable({}, Node)
	self.IsDestroyed = false
	self.Destroying = Signal.Immediate.new()

	self.ValueByPriority = vbp
	self._vbpId = vbp.Id

	local nodeId = params._bakedNodeId
	if not nodeId then
		--[[
			`NodeId는`int16` 으로 저장됩니다.
			서버에서 생성하는 노드의 Id 는 [0, 2^{15}-1]
			클라이언트에서 생성하는 노드의 Id 는 [-2^{15}, -1] 입니다.

			동기화 작업시 서로 중첩되는 것을 막기 위함.
			그래서 미리 구워진 NodeId 가 없다면 해당 범위로 랜덤하게 생성합니다.
		]]

		repeat
			nodeId = NODE_ID_RANDOM_GENERATOR:NextInteger(-2 ^ 15, -1)
		until vbp.NodesById[nodeId] == nil
		if IS_SERVER then
			nodeId += 2 ^ 15
		end
	end

	self._nodeId = nodeId
	vbp.NodesById[nodeId] = self

	local nodeFunction = params.NodeFunction or "Set"
	self.NodeFunction = nodeFunction
	self._realNodeFunction = DefaultNodeFunctions[nodeFunction] or require(nodeFunction)

	self.NotReplicated = params.NotReplicated or false

	assert((params :: any).Default == nil, `Invalid Params Key, "Default"`)
	local value = params.Value
	self.Value = value
	self.ValueChanged = Signal.new()
	self._valueChangedTime = 0

	local createdTime = time()
	self.CreatedTime = createdTime

	self.CustomData = params.CustomData or {}
	self.CustomDataChanged = Signal.new()

	self.ReliabilityChanged = Signal.new()
	self:SetReliability("Reliable")

	self.PriorityChanged = Signal.new()
	self:SetPriority(params.Priority)

	vbp.NodeAdded:Fire(self)

	if vbp.IsDestroyed then
		self:Destroy()
		return self
	end

	return self
end

--[=[
	새로운 노드를 생성하여 해당 Vbp에 추가합니다.  
	노드의 `Priority`, `NodeFunction`, `Value` 등을 설정할 수 있습니다.
]=]
function ValueByPriority:AddNode(params: NodeParams): Node
	return Node.new(self, params)
end

--[=[
	Create a node when you call ValueByPriority
	
	Example:
	```lua
	local newNode = someVbp {
		Value = 16,
		Priority = 10,
		NodeFunction = "Lerp",
		CustomData = {
			alpha = 5
		},
	}
	```
]=]
function ValueByPriority:__call(info: NodeParams): Node
	return self:AddNode(info)
end

local function isHigherThan(self, other: Node): boolean
	local selfPriority, otherPriority = self.Priority, other.Priority

	if selfPriority == otherPriority then
		return self.CreatedTime < other.CreatedTime
	else
		return selfPriority < otherPriority
	end
end

local function nodeComparison(a: Node, b: Node): boolean
	return isHigherThan(a, b)
end

local function doesBlockLowerPriorityNodes(nodeFunction: NodeFunction): boolean
	return nodeFunction == "Set" or nodeFunction == "WeightedSet"
end

local function blocksLowerPriorityNodes(self): boolean
	return doesBlockLowerPriorityNodes(self.NodeFunction)
end

local function getIndexFromNodes(self): number
	local vbp = self.ValueByPriority
	local nodes = vbp.Nodes
	local index = TableUtil.binarySearch(nodes, self, nodeComparison)

	return index
end

local function getIndexInNodes(self): number
	return TableUtil.bisectRight(self.ValueByPriority.Nodes, self, nodeComparison)
end

local function removeFromParentNodes(self): ()
	local vbp = self.ValueByPriority
	local nodes = vbp.Nodes

	local index = getIndexFromNodes(self)
	table.remove(nodes, index)

	readyToUpdate(vbp)

	-- If destroyed node affected ValueByPriority and its function is "Set",
	-- Nodes from the nearest lower priority to the lower priority "Set" node affect Vbp
	local wasAffectingVbp = self._isAffectingVbp
	if wasAffectingVbp then
		self._isAffectingVbp = false
	end

	if wasAffectingVbp and blocksLowerPriorityNodes(self) then
		local isChangedAffectingLowestNodeIndex = false

		for i = index - 1, 1, -1 do
			local lowerNode = nodes[i]
			lowerNode._isAffectingVbp = true
			if blocksLowerPriorityNodes(lowerNode) then
				vbp._affectingLowestNodeIndex = i
				isChangedAffectingLowestNodeIndex = true
				break
			end
		end

		--If there are no Set nodes among the lower nodes and all nodes affect Vbp,
		--Set _affectingLowestNodeIndex to 1 (the lowest priority node)
		if not isChangedAffectingLowestNodeIndex then
			vbp._affectingLowestNodeIndex = 1
		end
	end
end

local function insertToValueByPriority(self): ()
	local vbp = self.ValueByPriority
	local nodes = vbp.Nodes

	--Find the Index of new node
	local index = getIndexInNodes(self)
	table.insert(nodes, index, self)

	--Check if the new node affects ValueByPriority
	local nearestHigherNode = nodes[index + 1] --Nearest higher priority node
	if nearestHigherNode then
		--If nearest higher node is the affecting node and its function is not set,
		--new node is the affecting node.
		if
			nearestHigherNode._isAffectingVbp and not blocksLowerPriorityNodes(nearestHigherNode)
		then
			self._isAffectingVbp = true
			if blocksLowerPriorityNodes(self) then
				--if new node's function is "Set", lower nodes can't affect vbp.
				for i = index - 1, 1, -1 do
					local lowerNode = nodes[i]
					lowerNode._isAffectingVbp = false
				end
			end

			--Change the index after checking that new node is the lowest of the affecting nodes
			if index < vbp._affectingLowestNodeIndex then
				vbp._affectingLowestNodeIndex = index
			end

			readyToUpdate(vbp)
		end
	else
		--If no other higher priority node exists, new node is the affecting node.
		self._isAffectingVbp = true
		if blocksLowerPriorityNodes(self) then
			--if new node's function is "Set", lower nodes can't affect vbp.
			for i = index - 1, 1, -1 do
				local lowerNode = nodes[i]
				lowerNode._isAffectingVbp = false
			end
		end

		readyToUpdate(vbp)
	end
end

--[=[
	노드를 파괴합니다. 파괴된 노드는 `ValueByPriority`의 최종 계산에 더 이상 참여하지 않습니다.
]=]
function Node:Destroy(): ()
	if self.IsDestroyed then
		return
	end

	self.IsDestroyed = true
	self.Destroying:Fire()
	self.Destroying:Destroy()

	local vbp = self.ValueByPriority

	removeFromParentNodes(self)
	vbp.NodeRemoved:Fire(self)

	self.SetValue = EMPTY_FUNC
	self.SetCustomData = EMPTY_FUNC
end

--[=[
	노드의 현재 우선순위를 반환합니다.
]=]
function Node:GetPriority(): number
	return self.Priority
end

--[=[
	노드의 우선순위를 변경합니다.  
	값이 낮을수록 최종 결과에 더 ‘나중’에 적용되는 점에 유의하세요.
]=]
function Node:SetPriority(priority: number): ()
	assert(priority ~= nil, `Missing Priority`)

	if self.Priority == priority then
		return
	end

	local vbp = self.ValueByPriority
	local nodes = vbp.Nodes

	local existingPriority = self.Priority
	if existingPriority then
		if existingPriority == priority then
			return
		end
		removeFromParentNodes(self)
	end

	self.Priority = priority

	-- Find the index, insert new node into Vbp(ValueByPriority)'s Nodes array,
	-- and check whether new node affects Vbp.
	if nodes[1] then
		insertToValueByPriority(self)
	else
		--if no node exists, insert new node directly into vbp's Nodes.
		nodes[1] = self
		self._isAffectingVbp = true
		vbp._affectingLowestNodeIndex = 1
		readyToUpdate(vbp)
	end

	self.PriorityChanged:Fire(priority)
end

--[=[
	노드의 `Value`를 반환합니다.
]=]
function Node:GetValue(): any
	return self.Value
end

--[=[
	노드의 `Value`를 변경합니다.  
	변경 시 `ValueChanged` 시그널이 발동하고, 노드가 실제로 `ValueByPriority`의 결과값에 반영되고 있었다면 전체 결과도 업데이트됩니다.
]=]
function Node:SetValue(value: any): ()
	if self.Value == value then
		return
	end

	self.Value = value
	self.ValueChanged:Fire(value)
	self._valueChangedTime = time()

	if self._isAffectingVbp then
		readyToUpdate(self.ValueByPriority)
	end
end

--[=[
	`CustomData` 테이블에 특정 속성(`key`)을 추가 또는 수정합니다.  
	변경 시, 노드가 `ValueByPriority` 결과값에 반영되고 있었다면 결과 업데이트가 발생할 수 있습니다.
]=]
function Node:SetCustomData(key: string, value: any): ()
	local customData = self.CustomData
	if customData == nil then
		customData = {}
		self.CustomData = customData
	end

	local lastValue = customData[key]
	if lastValue ~= value then
		customData[key] = value
		self.CustomDataChanged:Fire(key, value)

		if self._isAffectingVbp then
			readyToUpdate(self.ValueByPriority)
		end
	end
end

--[=[
	노드의 신뢰도 수준(`"Reliable"|"Unreliable"`)을 설정합니다.  
	서버-클라이언트 동기화 시 패킷 손실 등이 중요한 값이라면 `"Reliable"`로 설정하세요.

	매프레임마다 Value, CustomData가 바뀌는 노드의 경우,
	[Unreliable](https://create.roblox.com/docs/reference/engine/classes/UnreliableRemoteEvent) 로 설정하면,
	대역폭을 아낄 수 있습니다.
]=]
function Node:SetReliability(reliability: Reliability): ()
	if self.Reliability == reliability then
		return
	end
	self.Reliability = reliability
	self.ReliabilityChanged:Fire(reliability)
end

ValueByPriority.Enums = require(Package.Enums)

return table.freeze(ValueByPriority)
