local RunService = game:GetService("RunService")

local BufferBuilder = require("../roblox_packages/BufferBuilder")
local BufferReader = require("../roblox_packages/BufferReader")
local Maid = require("../roblox_packages/Maid")
local ReplicatedInstanceId = require("../roblox_packages/ReplicatedInstanceId")
local Signal = require("../roblox_packages/Signal")
local TableUtil = require("../roblox_packages/TableUtil")
local TypeInfos = require("../roblox_packages/TypeInfos")

local NIL_IDENTIFIER = {}

local ValueByPriority = require("./")

--[=[
	@class ValueByPriorityObserver

	`ValueByPriorityObserver`는 `Classes.ValueByPriority` 객체의 변경 사항(기본값, 노드 추가/제거/변경 등)을 감지하고, `Classes.ValueByPriorityObserver.RecordStepEvent` 주기에 맞춰 변경된 정보들을 모아 `Classes.ValueByPriorityObserver.ChangeRecorded` 시그널을 발생시키는 객체입니다.

	주로 서버에서 `Classes.ValueByPriority` 객체의 상태를 클라이언트로 복제하기 위한 목적으로 사용됩니다. `Classes.ValueByPriority.NotReplicated` 속성이 `true`로 설정된 노드는 기록 및 전송 대상에서 제외됩니다.
]=]
local ValueByPriorityObserver = {}
ValueByPriorityObserver.__index = ValueByPriorityObserver
ValueByPriorityObserver.__type = "ValueByPriorityObserver"

--[=[
	내부적으로 `nil` 값을 구별하기 위해 사용되는 특별한 빈 테이블 식별자입니다. 

	Luau 테이블의 특성상 키에 `nil` 값을 할당하면 해당 키-값 쌍이 테이블에서 제거됩니다.
	이 때문에 변경 정보(`changeInfo`)를 기록할 때, 어떤 값(예: 노드의 `Value` 또는 `CustomData`의 특정 키 값)이 실제로 `nil`로 변경되었음을 명확히 나타내기 위해 이 `NIL_IDENTIFIER`를 대신 저장합니다. 
]=]
ValueByPriorityObserver.NIL_IDENTIFIER = NIL_IDENTIFIER

--[=[
	변경 사항 기록 및 `ChangeRecorded` 시그널 발생 주기를 결정하는 이벤트입니다. 기본값은 `RunService.Heartbeat`입니다.
]=]
export type RecordStepEvent = Signal.Signal | RBXScriptSignal

--[=[
	@interface
	`ChangeRecorded` 시그널을 통해 전달되는 변경 정보의 구조체입니다. 
	`ValueByPriority` 객체 전체 또는 개별 노드의 변경 사항을 포함합니다.

	`Classes.ValueByPrioritySerializer` 가 `Classes.ValueByPriorityObserver.VbpChangeInfo` 를 받고 직렬화합니다.
]=]
export type VbpChangeInfo = {
	IsDestroyed: boolean?,
	DefaultValue: any?,
	IsDefaultValueReliable: boolean?,
	ReliableNodeChangeInfosById: {
		[number]: ReliableNodeChangeInfo?,
	}?,
	UnreliableNodeChangeInfosById: {
		[number]: UnreliableNodeChangeInfo?,
	}?,
}

--[=[
	@interface
	신뢰성 있는(`Reliable`) 노드의 변경 정보를 담는 구조체입니다. 
	노드 추가/제거, 우선순위, 값, 커스텀 데이터 변경 등을 포함합니다.
]=]
export type ReliableNodeChangeInfo = {
	IsDestroyed: boolean?,
	IsAdded: boolean?,
	Priority: number?,
	Value: any?,
	NodeFunction: ValueByPriority.NodeFunction?,
	CustomData: { [string]: any }?,
}

--[=[
	@interface
	신뢰성 없는(`Unreliable`) 노드의 변경 정보를 담는 구조체입니다. 
	값과 커스텀 데이터 변경만 포함합니다.

	`Unreliable` 노드의 값이나 커스텀 데이터는 변경될 때 `UnreliableRemoteEvent` 에 보내지만,
	`Priority`, 생성 정보, 제거 정보는 노드가 `Unreliable` 해도, 필수적인 정보기에 `Reliable` 하게 보내야 합니다.

	`NodeFunction` 의 경우, 생성 시에만 필요한 정보이긴 하나, (생성 이후 바꿀 수 없기 때문)
	`Value` 가 바뀔 때 같이 기록합니다.
]=]
export type UnreliableNodeChangeInfo = {
	Value: any?,
	NodeFunction: ValueByPriority.NodeFunction?,
	CustomData: { [string]: any }?,
}

export type ValueByPriorityObserverParams = {
	RecordStepEvent: RecordStepEvent?,
}

export type ValueByPriorityObserver = setmetatable<
	{
		--- 내부적으로 사용되는 [[Maid]] 객체입니다. Observer가 파괴될 때 연결된 이벤트 리스너 등을 정리하는 데 사용됩니다.
		Maid: Maid.Maid,
		--- Observer 객체가 파괴되었는지 여부를 나타냅니다. 파괴된 후에는 더 이상 변경 사항을 기록하거나 시그널을 발생시키지 않습니다.
		IsDestroyed: boolean,
		--- 이 Observer가 감시하고 있는 대상 `ValueByPriority` 객체입니다.
		ValueByPriority: ValueByPriority.ValueByPriority,
		--- 변경 사항을 기록하고 `ChangeRecorded` 시그널을 발생시키는 주기가 되는 이벤트입니다. 생성자 `params`를 통해 설정할 수 있으며, 기본값은 `RunService.Heartbeat`입니다.
		RecordStepEvent: RecordStepEvent,
		--[=[
			`RecordStepEvent` 주기에 맞춰 감지된 변경 사항(`VbpChangeInfo`)을 전달하는 시그널입니다. 
			이 시그널을 통해 서버-클라이언트 간 데이터 동기화 로직 등을 구현할 수 있습니다.
		]=]
		ChangeRecorded: Signal.Signal<VbpChangeInfo>,

		_changeInfo: VbpChangeInfo,
		_isReadyToRecord: boolean,
	},
	typeof(ValueByPriorityObserver)
>

local function readyToRecordChange(self)
	if self._isReadyToRecord then
		return
	end
	self._isReadyToRecord = true

	self.RecordStepEvent:Once(function()
		self.ChangeRecorded:Fire(self._changeInfo)
		self._changeInfo = {}
		self._isReadyToRecord = false
	end)
end

--[[
	각 record... 함수는 self._changeInfo 를 수정하고 
	readyToRecordChange(self) 호출.
]]

local function recordDefaultValueChange(self, vbp, newValue)
	self._changeInfo.DefaultValue = newValue
	self._changeInfo.IsDefaultValueReliable = vbp.DefaultValueReliability == "Reliable"
	readyToRecordChange(self)
end

local function findOrCreateReliableNodeChangeInfosById(self): {
	[number]: ReliableNodeChangeInfo,
}
	local reliableNodeChangeInfosById = self._changeInfo.ReliableNodeChangeInfosById
	if reliableNodeChangeInfosById then
		return reliableNodeChangeInfosById
	end
	reliableNodeChangeInfosById = {}
	self._changeInfo.ReliableNodeChangeInfosById = reliableNodeChangeInfosById
	return reliableNodeChangeInfosById
end

local function findOrCreateReliableNodeChangeInfo(self, nodeId: number): ReliableNodeChangeInfo
	local nodeChangeInfo = findOrCreateReliableNodeChangeInfosById(self)[nodeId]
	if nodeChangeInfo == nil then
		nodeChangeInfo = {}
		findOrCreateReliableNodeChangeInfosById(self)[nodeId] = nodeChangeInfo
	end
	return nodeChangeInfo
end

local function findOrCreateUnreliableNodeChangeInfosById(self): {
	[number]: UnreliableNodeChangeInfo,
}
	local unreliableNodeChangeInfosById = self._changeInfo.UnreliableNodeChangeInfosById
	if unreliableNodeChangeInfosById then
		return unreliableNodeChangeInfosById
	end
	unreliableNodeChangeInfosById = {}
	self._changeInfo.UnreliableNodeChangeInfosById = unreliableNodeChangeInfosById
	return unreliableNodeChangeInfosById
end

local function findOrCreateUnreliableNodeChangeInfo(self, nodeId: number): UnreliableNodeChangeInfo
	local nodeChangeInfo = findOrCreateUnreliableNodeChangeInfosById(self)[nodeId]
	if nodeChangeInfo == nil then
		nodeChangeInfo = {}
		findOrCreateUnreliableNodeChangeInfosById(self)[nodeId] = nodeChangeInfo
	end
	return nodeChangeInfo
end

local function recordOnNodeAdded(self, node)
	local changeInfo = findOrCreateReliableNodeChangeInfo(self, node._nodeId)

	changeInfo.IsAdded = true
	changeInfo.Priority = node.Priority
	changeInfo.NodeFunction = node.NodeFunction
	changeInfo.Value = node:GetValue()
	changeInfo.CustomData = table.clone(node.CustomData)

	readyToRecordChange(self)
end

local function recordOnNodeRemoved(self, node: ValueByPriority.Node)
	local changeInfo = findOrCreateReliableNodeChangeInfo(self, node._nodeId)
	changeInfo.IsDestroyed = true

	if self._changeInfo.UnreliableNodeChangeInfosById then
		self._changeInfo.UnreliableNodeChangeInfosById[node._nodeId] = nil
	end

	readyToRecordChange(self)
end

local function recordNodePriorityChange(self, node: ValueByPriority.Node, priority: number)
	local changeInfo = findOrCreateReliableNodeChangeInfo(self, node._nodeId)
	changeInfo.Priority = priority

	readyToRecordChange(self)
end

local function recordNodeValueChange(self, node: ValueByPriority.Node, value: any)
	local changeInfo = if node.Reliability == "Reliable"
		then findOrCreateReliableNodeChangeInfo(self, node._nodeId)
		else findOrCreateUnreliableNodeChangeInfo(self, node._nodeId)

	changeInfo.Value = if value == nil then NIL_IDENTIFIER else value

	--[[
		Serializer 에서 NodeFunction 에 따라, 
		값이 바뀔 때 TypeId 등을 첨부하지 않아도 될 수 있으므로, 
		즉 추가 최적화를 할 수 있으므로 
		변경된 기록은 아니지만, 따로 기록을 해둡니다.
		Unreliable 이어도 마찬가지.
	]]
	changeInfo.NodeFunction = node.NodeFunction

	readyToRecordChange(self)
end

local function recordNodeCustomDataChange(self, node: ValueByPriority.Node, key: string, value: any)
	local changeInfo = if node.Reliability == "Reliable"
		then findOrCreateReliableNodeChangeInfo(self, node._nodeId)
		else findOrCreateUnreliableNodeChangeInfo(self, node._nodeId)

	local customData = changeInfo.CustomData
	if customData == nil then
		customData = {}
		changeInfo.CustomData = customData
	end

	customData[key] = if value == nil then NIL_IDENTIFIER else value

	readyToRecordChange(self)
end

local function onVbpDestroying(self)
	self._changeInfo = {
		IsDestroyed = true,
	}

	readyToRecordChange(self)
	self:Destroy()
end

-- 개별 노드의 변경 이벤트 리스너 연결.
local function connectNodeListeners(self, node: ValueByPriority.Node)
	recordOnNodeAdded(self, node)

	local nodeMaid = Maid.new()

	nodeMaid:GiveTask(node.PriorityChanged:ConnectUnyielding(function(newPriority)
		recordNodePriorityChange(self, node, newPriority)
	end))
	nodeMaid:GiveTask(node.ValueChanged:ConnectUnyielding(function(newValue)
		recordNodeValueChange(self, node, newValue)
	end))
	nodeMaid:GiveTask(node.CustomDataChanged:ConnectUnyielding(function(key, value)
		recordNodeCustomDataChange(self, node, key, value)
	end))
	nodeMaid:GiveTask(node.Destroying:ConnectUnyielding(function()
		nodeMaid:Destroy()
		recordOnNodeRemoved(self, node)
	end))

	self.Maid:GiveTask(nodeMaid)
end

local function connectVbpListeners(self)
	local vbp = self.ValueByPriority

	self.Maid:GiveTask(vbp.DefaultValueChanged:ConnectUnyielding(function(newValue)
		recordDefaultValueChange(self, vbp, newValue)
	end))

	self.Maid:GiveTask(vbp.Destroying:ConnectUnyielding(function()
		onVbpDestroying(self)
	end))

	self.Maid:GiveTask(vbp.NodeAdded:ConnectUnyielding(function(node)
		if node.NotReplicated then
			return
		end

		connectNodeListeners(self, node)
	end))

	for nodeId, node in self.ValueByPriority.NodesById do
		if node.NotReplicated then
			continue
		end

		connectNodeListeners(self, node)
	end
end

--[=[
	주어진 `ValueByPriority` 객체를 감시하는 새로운 `ValueByPriorityObserver` 인스턴스를 생성하고 반환합니다.

	`params` 테이블을 통해 `RecordStepEvent`를 지정할 수 있으며, 생략 시 `RunService.Heartbeat`이 기본값으로 사용됩니다.
]=]
function ValueByPriorityObserver.fromValueByPriority(
	vbp: ValueByPriority.ValueByPriority,
	params: ValueByPriorityObserverParams?
): ValueByPriorityObserver
	params = params or {}

	local self = setmetatable({}, ValueByPriorityObserver)
	self.IsDestroyed = false
	self.Maid = Maid.new()
	self.ValueByPriority = vbp
	self.RecordStepEvent = params.RecordStepEvent or RunService.Heartbeat
	self.ChangeRecorded = Signal.new()
	self.Maid:GiveTask(self.ChangeRecorded)

	self._changeInfo = {}
	self._isReadyToRecord = false

	connectVbpListeners(self)

	return self
end

--[=[
	`ValueByPriorityObserver` 객체를 파괴하고 모든 내부 리소스(이벤트 리스너, 시그널 등)를 정리합니다. `Maid` 객체를 사용하여 연결된 모든 작업을 정리합니다. 파괴된 Observer는 더 이상 사용할 수 없습니다.
]=]
function ValueByPriorityObserver:Destroy()
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true

	self.Maid:Destroy()
end

function ValueByPriorityObserver.SeparateChangeInfoIntoReliableAndUnreliable(
	changeInfo: VbpChangeInfo
): (
	VbpChangeInfo?,
	VbpChangeInfo?
)
	local reliableChangeInfo = {} :: VbpChangeInfo?
	reliableChangeInfo.IsDestroyed = changeInfo.IsDestroyed
	reliableChangeInfo.ReliableNodeChangeInfosById = changeInfo.ReliableNodeChangeInfosById

	local unreliableChangeInfo = {}
	if changeInfo.UnreliableNodeChangeInfosById then
		unreliableChangeInfo.UnreliableNodeChangeInfosById =
			changeInfo.UnreliableNodeChangeInfosById
	end

	if changeInfo.DefaultValue ~= nil then
		if changeInfo.IsDefaultValueReliable then
			reliableChangeInfo.DefaultValue = changeInfo.DefaultValue
		else
			unreliableChangeInfo.DefaultValue = changeInfo.DefaultValue
		end
	end

	if next(reliableChangeInfo) == nil then
		reliableChangeInfo = nil
	end
	if next(unreliableChangeInfo) == nil then
		unreliableChangeInfo = nil
	end

	return reliableChangeInfo, unreliableChangeInfo
end

return ValueByPriorityObserver
