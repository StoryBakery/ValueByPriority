local RunService = game:GetService("RunService")


local BufferBuilder = require("../roblox_packages/BufferBuilder")
local BufferReader = require("../roblox_packages/BufferReader")
local TypeInfos = require("../roblox_packages/TypeInfos")
local ReplicatedInstanceId = require("../roblox_packages/ReplicatedInstanceId")
local TableUtil = require("../roblox_packages/TableUtil")
local Signal = require("../roblox_packages/Signal")
local Maid = require("../roblox_packages/Maid")

local NIL_IDENTIFIER = {}

local ValueByPriority = require(script.Parent)

local ValueByPriorityObserver = {}
ValueByPriorityObserver.__index = ValueByPriorityObserver
ValueByPriorityObserver.__type = "ValueByPriorityObserver"

ValueByPriorityObserver.NIL_IDENTIFIER = NIL_IDENTIFIER

--#region Types


export type RecordStepEvent = Signal.Signal | RBXScriptSignal
export type VbpChangeInfo = {
	IsDestroyed: boolean?,
	DefaultValue: any?,
	IsDefaultValueReliable: boolean?,
	ReliableNodeChangeInfosById: {
		[number]: ReliableNodeChangeInfo?
	}?,
	UnreliableNodeChangeInfosById: {
		[number]: UnreliableNodeChangeInfo?
	}?
}
export type ReliableNodeChangeInfo = {
	IsDestroyed: boolean?,
	IsAdded: boolean?,
	Priority: number?,
	Value: any?,
	NodeFunction: ValueByPriority.NodeFunction?,
	CustomData: {[string]: any}?,
}
export type UnreliableNodeChangeInfo = {
	Value: any?,
	NodeFunction: ValueByPriority.NodeFunction?,
	CustomData: {[string]: any}?,
}

export type ValueByPriorityObserverParams = {
	RecordStepEvent: RecordStepEvent?,
}

export type ValueByPriorityObserver = setmetatable<{
	Maid: Maid.Maid,
	IsDestroyed: boolean,
	ValueByPriority: ValueByPriority.ValueByPriority,
	RecordStepEvent: RecordStepEvent,
	ChangeRecorded: Signal.Signal<VbpChangeInfo>,

	_changeInfo: VbpChangeInfo,
	_isReadyToRecord: boolean,
}, typeof(ValueByPriorityObserver)>

--#region Constructors
--[[
	ValueByPriority 객체의 변경 사항을 감지하고 주기적으로 
	ChangeRecorded 시그널을 발생시키는 Observer 객체를 생성합니다.
	
	서버 - 클라이언트 복제를 위한 객체입니다.
	NotReplicated 인 노드는 기록하지 않습니다.
]]
function ValueByPriorityObserver.fromValueByPriority(
	vbp: ValueByPriority.ValueByPriority,
	params: ValueByPriorityObserverParams?
): ValueByPriorityObserver
	local params = params or {}

	local self = setmetatable({}, ValueByPriorityObserver)
	self.IsDestroyed = false
	self.Maid = Maid.new()
	self.ValueByPriority = vbp
	self.RecordStepEvent = params.RecordStepEvent or RunService.Heartbeat
	self.ChangeRecorded = Signal.new()
	self.Maid:GiveTask(self.ChangeRecorded)

	self._changeInfo = {}
	self._isReadyToRecord = false

	self:_connectVbpListeners()

	return self
end


--#tag Listen Vbp 
function ValueByPriorityObserver:_connectVbpListeners()
	local vbp = self.ValueByPriority
	
	self.Maid:GiveTask(vbp.DefaultValueChanged:ConnectUnyielding(function(newValue) 
		self:_recordDefaultValueChange(vbp, newValue) 
	end))
	
	self.Maid:GiveTask(vbp.Destroying:ConnectUnyielding(function()
		self:_onVbpDestroying() 
	end))
	
	self.Maid:GiveTask(vbp.NodeAdded:ConnectUnyielding(function(node)
		if node.NotReplicated then
			return
		end
		
		self:_connectNodeListeners(node)
	end))
	
	for nodeId, node in self.ValueByPriority.NodesById do
		if node.NotReplicated then
			continue
		end
		
		self:_connectNodeListeners(node)
	end
end



--#tag Record Changes
--[[
	각 _record... 함수는 self._changeInfo 를 수정하고 
	self:_readyToRecordChange() 호출.
]]

--#tag Default Value
function ValueByPriorityObserver:_recordDefaultValueChange(vbp, newValue)
	self._changeInfo.DefaultValue = newValue
	self._changeInfo.IsDefaultValueReliable = vbp.DefaultValueReliability == "Reliable"
	self:_readyToRecordChange()
end

--#tag Node Record
-- 개별 노드의 변경 이벤트 리스너 연결.
function ValueByPriorityObserver:_connectNodeListeners(node: ValueByPriority.Node)
	self:_recordOnNodeAdded(node)

	local nodeMaid = Maid.new()
	
	nodeMaid:GiveTask(node.PriorityChanged:ConnectUnyielding(function(newPriority)
		self:_recordNodePriorityChange(node, newPriority) 
	end))
	nodeMaid:GiveTask(node.ValueChanged:ConnectUnyielding(function(newValue)
		self:_recordNodeValueChange(node, newValue) 
	end))
	nodeMaid:GiveTask(node.CustomDataChanged:ConnectUnyielding(function(key, value)
		self:_recordNodeCustomDataChange(node, key, value) 
	end))
	nodeMaid:GiveTask(node.Destroying:ConnectUnyielding(function()
		nodeMaid:Destroy()
		self:_recordOnNodeRemoved(node)
	end))
	
	self.Maid:GiveTask(nodeMaid)
end

function ValueByPriorityObserver:_findOrCreateReliableNodeChangeInfosById(): {[number]: ReliableNodeChangeInfo}
	local reliableNodeChangeInfosById = self._changeInfo.ReliableNodeChangeInfosById
	if reliableNodeChangeInfosById then
		return reliableNodeChangeInfosById
	end
	reliableNodeChangeInfosById = {}
	self._changeInfo.ReliableNodeChangeInfosById = reliableNodeChangeInfosById
	return reliableNodeChangeInfosById
end

function ValueByPriorityObserver:_findOrCreateReliableNodeChangeInfo(
	nodeId: number
): ReliableNodeChangeInfo
	local nodeChangeInfo = self:_findOrCreateReliableNodeChangeInfosById()[nodeId]
	if nodeChangeInfo == nil then
		nodeChangeInfo = {}
		self:_findOrCreateReliableNodeChangeInfosById()[nodeId] = nodeChangeInfo
	end
	return nodeChangeInfo
end

function ValueByPriorityObserver:_findOrCreateUnreliableNodeChangeInfosById(): {[number]: UnreliableNodeChangeInfo}
	local unreliableNodeChangeInfosById = self._changeInfo.UnreliableNodeChangeInfosById
	if unreliableNodeChangeInfosById then
		return unreliableNodeChangeInfosById
	end
	unreliableNodeChangeInfosById = {}
	self._changeInfo.UnreliableNodeChangeInfosById = unreliableNodeChangeInfosById
	return unreliableNodeChangeInfosById
end

function ValueByPriorityObserver:_findOrCreateUnreliableNodeChangeInfo(
	nodeId: number
): UnreliableNodeChangeInfo
	local nodeChangeInfo = self:_findOrCreateUnreliableNodeChangeInfosById()[nodeId]
	if nodeChangeInfo == nil then
		nodeChangeInfo = {}
		self:_findOrCreateUnreliableNodeChangeInfosById()[nodeId] = nodeChangeInfo
	end
	return nodeChangeInfo
end

--#tag Added
function ValueByPriorityObserver:_recordOnNodeAdded(node)
	local changeInfo = self:_findOrCreateReliableNodeChangeInfo(node._nodeId)
	
	changeInfo.IsAdded = true
	changeInfo.Priority = node.Priority
	changeInfo.NodeFunction = node.NodeFunction
	changeInfo.Value = node:GetValue()
	changeInfo.CustomData = table.clone(node.CustomData)
	
	self:_readyToRecordChange()
end

--#tag Destroy
function ValueByPriorityObserver:_recordOnNodeRemoved(node: ValueByPriority.Node)
	local changeInfo = self:_findOrCreateReliableNodeChangeInfo(node._nodeId)
	changeInfo.IsDestroyed = true
	
	if self._changeInfo.UnreliableNodeChangeInfosById then
		self._changeInfo.UnreliableNodeChangeInfosById[node._nodeId] = nil
	end
	
	self:_readyToRecordChange()
end

--#tag Priority
function ValueByPriorityObserver:_recordNodePriorityChange(
	node: ValueByPriority.Node, 
	priority: number
)
	local changeInfo = self:_findOrCreateReliableNodeChangeInfo(node._nodeId)
	changeInfo.Priority = priority
	
	self:_readyToRecordChange()
end

--#tag Value
function ValueByPriorityObserver:_recordNodeValueChange(
	node: ValueByPriority.Node, 
	value: any
)
	local changeInfo = if node.Reliability == "Reliable"
		then self:_findOrCreateReliableNodeChangeInfo(node._nodeId)
		else self:_findOrCreateUnreliableNodeChangeInfo(node._nodeId)
	
	changeInfo.Value = if value == nil
		then NIL_IDENTIFIER
		else value
	
	--[[
		Serializer 에서 NodeFunction 에 따라, 
		값이 바뀔 때 TypeId 등을 첨부하지 않아도 될 수 있으므로, 
		즉 추가 최적화를 할 수 있으므로 
		변경된 기록은 아니지만, 따로 기록을 해둡니다.
		Unreliable 이어도 마찬가지.
	]]
	changeInfo.NodeFunction = node.NodeFunction
	
	self:_readyToRecordChange()
end

--#tag CustomData
function ValueByPriorityObserver:_recordNodeCustomDataChange(
	node: ValueByPriority.Node,
	key: string, 
	value: any
)
	local changeInfo = if node.Reliability == "Reliable"
		then self:_findOrCreateReliableNodeChangeInfo(node._nodeId)
		else self:_findOrCreateUnreliableNodeChangeInfo(node._nodeId)

	local customData = changeInfo.CustomData
	if customData == nil then
		customData = {}
		changeInfo.CustomData = customData
	end
	
	customData[key] = if value == nil
		then NIL_IDENTIFIER
		else value
	
	self:_readyToRecordChange()
end

--#tag Destroying
function ValueByPriorityObserver:_onVbpDestroying()

	self._changeInfo = { 
		IsDestroyed = true 
	}

	self:_readyToRecordChange()
	self:Destroy()
end

--#tag 기록 전송
function ValueByPriorityObserver:_readyToRecordChange()
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


--#region Methods
-- Observer 객체 정리
function ValueByPriorityObserver:Destroy()
	if self.IsDestroyed then 
		return 
	end
	self.IsDestroyed = true

	self.Maid:Destroy()

end

--#region Functions

--#region SeparateChangeInfoIntoReliableAndUnreliable
function ValueByPriorityObserver.SeparateChangeInfoIntoReliableAndUnreliable(
	changeInfo: VbpChangeInfo
): (VbpChangeInfo?, VbpChangeInfo?)
	
	local reliableChangeInfo = {} :: VbpChangeInfo?
	reliableChangeInfo.IsDestroyed = changeInfo.IsDestroyed
	reliableChangeInfo.ReliableNodeChangeInfosById = changeInfo.ReliableNodeChangeInfosById
	
	local unreliableChangeInfo = {} 
	if changeInfo.UnreliableNodeChangeInfosById then
		unreliableChangeInfo.UnreliableNodeChangeInfosById = changeInfo.UnreliableNodeChangeInfosById
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
		reliableChangeInfo = nil
	end
	
	return reliableChangeInfo, unreliableChangeInfo
end

return ValueByPriorityObserver
