--!native
--[=[
	@class ValueByPriority
]=]

local RunService = game:GetService("RunService")

local BufferBuilder = require("./roblox_packages/BufferBuilder")
local BufferReader = require("./roblox_packages/BufferReader")
local LinearInterpolation = require("./roblox_packages/LinearInterpolation")
local Promise = require("./roblox_packages/Promise")
local Signal = require("./roblox_packages/Signal")
local TableUtil = require("./roblox_packages/TableUtil")

local Package = 

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

export type NodeParams<Value = any> = {
	Value: Value,
	Priority: number,
	NodeFunction: NodeFunction?,
	CustomData: { [string]: any }?,

	NotReplicated: boolean?,

	_bakedNodeId: NodeId?,
}

export type Node<Value = any> = setmetatable<{
	IsDestroyed: boolean,
	Destroying: Signal.Signal<>,

	NodeFunction: NodeFunction,
	ValueByPriority: ValueByPriority,

	_vbpId: VbpId,
	_nodeId: NodeId,

	NotReplicated: boolean,

	Value: Value,
	ValueChanged: Signal.ChangedSignal<Value>,
	_valueChangedTime: number,

	GetValue: (self: any) -> Value,
	SetValue: (self: any, value: Value) -> (),

	CustomDataChanged: Signal.SignalBase<(key: string, newValue: any) -> (), string, any>,

	Priority: number,
	PriorityChanged: Signal.ChangedSignal<number>,
	Reliability: Reliability,
	ReliabilityChanged: Signal.ChangedSignal<Reliability>,

	CreatedTime: number,
	_affectingLowestNodeIndex: boolean,
	_isAffectingVbp: boolean,
	_realNodeFunction: RealNodeFunction,
}, typeof(Node)>

export type UpdateBehavior = "Immediate" | "Deferred"

export type ValueByPriority<Value = any> = setmetatable<{
	IsDestroyed: boolean,
	Destroying: Signal.Signal<>,

	Changed: Signal.ChangedSignal<Value>,
	DefaultValueChanged: Signal.ChangedSignal<Value>,

	Name: string?,
	Id: VbpId?,

	UpdateBehavior: UpdateBehavior,

	AddNode: (self: any, params: NodeParams<Value>) -> Node,
	Nodes: { Node },
	NodesById: { [NodeId]: Node },
	NodeAdded: Signal.AddedSignal<Node>,
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
}, typeof(ValueByPriority)>

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

--- 새로운 vbp 객체를 생성합니다.
--- `DefaultValue`부터 설정할 수 있으며, `Id`나 `UpdateBehavior` 등을 지정할 수 있습니다.
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

	self:_readyToUpdate()

	--[[
		WaitForId 로 기다리는 시그널에 보내고,
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

function ValueByPriority.FindById(id: VbpId, params: FindValueByPriorityParams?): ValueByPriority?
	return vbpsById[id]
end

function ValueByPriority.byId<Value>(id: VbpId, params: FindValueByPriorityParams?): ValueByPriority
	return vbpsById[id] or error(`ValueByPriority with Id "{id}" not found.`)
end

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

do
	local updatedVbpSet = {} :: { [ValueByPriority]: true }

	function ValueByPriority:_updateImmediately()
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

	local updateVbpImmediately = ValueByPriority._updateImmediately

	local freeThreads: { thread } = {}

	local function runCallback(callback, thread, ...)
		callback(...)
		table.insert(freeThreads, thread)
	end

	local function yielder()
		while true do
			runCallback(coroutine.yield())
		end
	end

	function ValueByPriority:_readyToUpdate()
		if self.UpdateBehavior == "Immediate" then
			self:_updateImmediately()
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

function ValueByPriority:GetValue()
	return self._value
end

function ValueByPriority:__tostring()
	return self.Name or self.Id
end

function ValueByPriority:SetDefaultValue(value)
	if self._defaultValue == value then
		return
	end

	self._defaultValue = value
	self._defaultValueChangedTime = time()
	if self._affectingLowestNodeIndex == 1 then
		self:_readyToUpdate()
	end

	self.DefaultValueChanged:Fire(value)
end

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

function ValueByPriority:SetUpdateBehavior(updateBehavior: UpdateBehavior)
	self.UpdateBehavior = updateBehavior
end

local NODE_ID_RANDOM_GENERATOR = Random.new()

function Node.new(vbp: ValueByPriority, params: NodeParams): Node
	local self = setmetatable({}, Node)
	self.IsDestroyed = false
	self.Destroying = Signal.Immediate.new()

	self.ValueByPriority = vbp
	self._vbpId = vbp.Id

	local nodeId = params._bakedNodeId
	if not nodeId then
		--[[
			NodeId는 `int16` 으로 저장됩니다.
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

function Node:Destroy(): ()
	if self.IsDestroyed then
		return
	end

	self.IsDestroyed = true
	self.Destroying:Fire()
	self.Destroying:Destroy()

	local vbp = self.ValueByPriority

	self:_removeFromParentNodes()
	vbp.NodeRemoved:Fire(self)

	self.SetValue = EMPTY_FUNC
	self.SetCustomData = EMPTY_FUNC
end

function Node:_isHigherThan(other: Node): boolean
	local selfPriority, otherPriority = self.Priority, other.Priority

	if selfPriority == otherPriority then
		return self.CreatedTime < other.CreatedTime
	else
		return selfPriority < otherPriority
	end
end

local function nodeComparison(a: Node, b: Node): boolean
	return a:_isHigherThan(b)
end

local function doesBlockLowerPriorityNodes(nodeFunction: NodeFunction): boolean
	return nodeFunction == "Set" or nodeFunction == "WeightedSet"
end

function Node:_blocksLowerPriorityNodes(): boolean
	return doesBlockLowerPriorityNodes(self.NodeFunction)
end

function Node:_getIndexFromNodes(): number
	local vbp = self.ValueByPriority
	local nodes = vbp.Nodes
	local index = TableUtil.binarySearch(nodes, self, nodeComparison)

	return index
end

function Node:_removeFromParentNodes(): ()
	local vbp = self.ValueByPriority
	local nodes = vbp.Nodes

	local index = self:_getIndexFromNodes()
	table.remove(nodes, index)

	vbp:_readyToUpdate()

	-- If destroyed node affected ValueByPriority and its function is "Set",
	-- Nodes from the nearest lower priority to the lower priority "Set" node affect Vbp
	local wasAffectingVbp = self._isAffectingVbp
	if wasAffectingVbp then
		self._isAffectingVbp = false
	end

	if wasAffectingVbp and self:_blocksLowerPriorityNodes() then
		local isChangedAffectingLowestNodeIndex = false

		for i = index - 1, 1, -1 do
			local lowerNode = nodes[i]
			lowerNode._isAffectingVbp = true
			if lowerNode:_blocksLowerPriorityNodes() then
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

function Node:GetPriority(): number
	return self.Priority
end

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
		self:_removeFromParentNodes()
	end

	self.Priority = priority

	-- Find the index, insert new node into Vbp(ValueByPriority)'s Nodes array,
	-- and check whether new node affects Vbp.
	if nodes[1] then
		self:_insertToValueByPriority()
	else
		--if no node exists, insert new node directly into vbp's Nodes.
		nodes[1] = self
		self._isAffectingVbp = true
		vbp._affectingLowestNodeIndex = 1
		vbp:_readyToUpdate()
	end

	self.PriorityChanged:Fire(priority)
end

function Node:_insertToValueByPriority(): ()
	local vbp = self.ValueByPriority
	local nodes = vbp.Nodes

	--Find the Index of new node
	local index = self:_getIndexInNodes()
	table.insert(nodes, index, self)

	--Check if the new node affects ValueByPriority
	local nearestHigherNode = nodes[index + 1] --Nearest higher priority node
	if nearestHigherNode then
		--If nearest higher node is the affecting node and its function is not set,
		--new node is the affecting node.
		if
			nearestHigherNode._isAffectingVbp
			and not nearestHigherNode:_blocksLowerPriorityNodes()
		then
			self._isAffectingVbp = true
			if self:_blocksLowerPriorityNodes() then
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

			vbp:_readyToUpdate()
		end
	else
		--If no other higher priority node exists, new node is the affecting node.
		self._isAffectingVbp = true
		if self:_blocksLowerPriorityNodes() then
			--if new node's function is "Set", lower nodes can't affect vbp.
			for i = index - 1, 1, -1 do
				local lowerNode = nodes[i]
				lowerNode._isAffectingVbp = false
			end
		end

		vbp:_readyToUpdate()
	end
end

function Node:_getIndexInNodes(): number
	return TableUtil.bisectRight(self.ValueByPriority.Nodes, self, nodeComparison)
end

function Node:GetValue(): any
	return self.Value
end

function Node:SetValue(value: any): ()
	if self.Value == value then
		return
	end

	self.Value = value
	self.ValueChanged:Fire(value)
	self._valueChangedTime = time()

	if self._isAffectingVbp then
		self.ValueByPriority:_readyToUpdate()
	end
end

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
			self.ValueByPriority:_readyToUpdate()
		end
	end
end

--[=[
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
