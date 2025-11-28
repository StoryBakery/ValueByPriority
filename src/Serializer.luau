

local BufferBuilder = require("../roblox_packages/BufferBuilder")
local BufferReader = require("../roblox_packages/BufferReader")
local TypeInfos = require("../roblox_packages/TypeInfos")
local ReplicatedInstanceId = require("../roblox_packages/ReplicatedInstanceId")
local TableUtil = require("../roblox_packages/TableUtil")
local Signal = require("../roblox_packages/Signal")
local Maid = require("../roblox_packages/Maid")

local ValueByPriority = require("./")
local ValueByPriorityObserver = require("./Observer")

local ValueByPrioritySerializer = {}

local NIL_IDENTIFIER = ValueByPriorityObserver.NIL_IDENTIFIER

--[[
	Enum 은 따로 분리합니다.
	자주 쓰이는 타입이 아니며, Enum의 모든 Id 를 1바이트 안에 담을 수 없기 때문.
	그래서 Enum 타입인지 읽고, Enum 이면 추가적인 바이트를 한 번 더 일게 합니다.
]]
local ENUM_TYPE_INFO_ID
local typeIdsByName, typeNamesById = {}, {} do
	local nextTypeInfoId = 0
	for typeName, typeInfo in TypeInfos.GetTypeInfosByName() do
		if typeInfo.IsEnum then
			continue
		end
		typeIdsByName[typeName] = nextTypeInfoId
		typeNamesById[nextTypeInfoId] = typeName
		nextTypeInfoId += 1
	end

	-- 모든 Enum TypeInfo 의 Id 는 가장 마지막 Id 로 해서
	-- 클라이언트 - 서버가 Enum 타입 아이디인지 알 수 있게 해줍니다.
	ENUM_TYPE_INFO_ID = nextTypeInfoId
	for typeName, typeInfo in TypeInfos.GetTypeInfosByName() do
		if typeInfo.IsEnum then
			typeIdsByName[typeName] = ENUM_TYPE_INFO_ID
		end
	end
end

local enumTypeIdsByName, enumTypeNamesById = {}, {} do
	local id = 0
	for typeName, typeInfo in TypeInfos.GetTypeInfosByName() do
		if not typeInfo.IsEnum then
			continue
		end
		enumTypeIdsByName[typeName] = id
		enumTypeNamesById[id] = typeName
		id += 1
	end
end

local nodeFunctionNamesById = {}
for name, id in ValueByPriority.NodeFunctionIdsByName do
	nodeFunctionNamesById[id] = name
end

local function mapNilIdentifierToNil(value)
	return if value == NIL_IDENTIFIER
		then nil
		else value
end

export type SerializeParams = {
	ExcludesTypeId: boolean?,
}


--#1 Functions
--#region BuildInitialInfo
export type BuildInitalInfoParams = {} & SerializeParams

function ValueByPrioritySerializer.BuildInitialInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	vbp: ValueByPriority.ValueByPriority,
	params: BuildInitalInfoParams?
)
	local params = params or {}
	
		bufBuilder:WriteBoolBit(vbp.IsDestroyed)
	if vbp.IsDestroyed then
		return
	end

	local replicatableNodes = vbp:_getReplicatableNodes()
	local nodeCount = #replicatableNodes
	local hasNodes = 0 < nodeCount
	bufBuilder:WriteBoolBit(hasNodes)

	--#tag 타입 정보
	local typeInfo = vbp.TypeInfo
	local hasVbpTypeInfo = typeInfo ~= nil
	local typeName = if hasVbpTypeInfo
		then typeInfo.Name
		else typeof(vbp.DefaultValue)

	if not hasVbpTypeInfo then
		typeInfo = TypeInfos.GetTypeInfoByTypeName(typeName)
	end

	-- 타입 Id 기록
	if not params.ExcludesTypeId then
		bufBuilder:WriteBoolBit(hasVbpTypeInfo)
		ValueByPrioritySerializer._buildTypeInfo(bufBuilder, typeInfo)
	end

		bufBuilder:WriteType(typeInfo, vbp:GetDefaultValue())

		if hasNodes then
		bufBuilder:WriteU16(nodeCount) -- 노드 개수 (2 bytes)

		for i = 1, nodeCount do
			local node = replicatableNodes[i]
			ValueByPrioritySerializer._buildInitialNodeInfo(
				bufBuilder,
				node,
				typeInfo,
				hasVbpTypeInfo,
				params.ExcludesTypeId
			)
		end
	end
end

function ValueByPrioritySerializer._buildInitialNodeInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	node: ValueByPriority.Node,
	typeInfo: TypeInfos.TypeInfo,
	hasVbpTypeInfo: boolean,
	excludesTypeId: boolean?
)
	-- Core
	bufBuilder:WriteU16(node._nodeId)
	bufBuilder:WriteF64(node.Priority)
	
	ValueByPrioritySerializer._buildNodeFunctionInfo(
		bufBuilder, node.NodeFunction
	)
	
	ValueByPrioritySerializer._buildInitialNodeValueInfo(
		bufBuilder,
		node,
		hasVbpTypeInfo,
		typeInfo,
		excludesTypeId
	)
	
	ValueByPrioritySerializer._buildInitialNodeCustomDataInfo(
		bufBuilder, node
	)
end

--#tag NodeFunction
function ValueByPrioritySerializer._buildNodeFunctionInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	nodeFunction: ValueByPriority.NodeFunction
)
	local nodeFunctionType = typeof(nodeFunction)
	if nodeFunctionType == "string" then
		bufBuilder:WriteU8(0) -- 기본 NodeFunction 문자열일 경우
		local funcId = ValueByPriority.NodeFunctionIdsByName[nodeFunction]
		bufBuilder:WriteU8(funcId)
	elseif nodeFunctionType == "Instance" then
		bufBuilder:WriteU8(1) -- 커스텀 NodeFunction 모듈 스크립트일 경우
		-- ModuleScript 인스턴스 Id 기록
		local repId = ReplicatedInstanceId.FindOrAssignId(nodeFunction :: any)
		bufBuilder:WriteU32(repId)
	else
		error(`Invalid NodeFunction "{nodeFunction}", "{nodeFunctionType}"`)
	end
end

--#tag Value
function ValueByPrioritySerializer._buildInitialNodeValueInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	node: ValueByPriority.Node,
	hasDefinedVbpTypeInfo: boolean,
	vbpTypeInfo: TypeInfos.TypeInfo,
	excludesTypeId: boolean?
)
	-- vbp 타입 우선, 없으면 값의 타입 사용
	local nodeValueTypeInfo 
	if hasDefinedVbpTypeInfo then 
		nodeValueTypeInfo = vbpTypeInfo
	else 
		nodeValueTypeInfo = TypeInfos.GetTypeInfoByValueType(node.Value)
	end
	
	--[[
		NodeFunction 이 Set 이고 Vbp 에 TypeInfo 가 정의되어있다면,
		Set 인 노드들의 Value도 해당 TypeInfo 에 맞게 설정됩니다.
		Set 인 노드들은 자주 사용되기에, 따로 타입 아이디를 넣지 않아도 됩니다.
		대신 NodeFunction 이 Set 이 아닌 경우, 노드의 Value는 Vbp TypeInfo와 다를 수 있으니
		값 저장시, 값의 타입 아이디도 저장해야합니다.
		
		WeightedSet 도 마찬가지지만, WeightedSet 에는 CustomData 가 있으니 Set 과 달리 예외.
	]]
	if not excludesTypeId and (not hasDefinedVbpTypeInfo or node.NodeFunction ~= "Set") then
		ValueByPrioritySerializer._buildTypeInfo(bufBuilder, nodeValueTypeInfo)
	end
	
	bufBuilder:WriteType(nodeValueTypeInfo, node.Value) 
end

--#tag CustomData
function ValueByPrioritySerializer._buildInitialNodeCustomDataInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	node: ValueByPriority.Node
)
	local hasCustomData = node.CustomData and next(node.CustomData) ~= nil
	bufBuilder:WriteBool(hasCustomData)
	if hasCustomData then
		ValueByPrioritySerializer._buildNodeCustomData(bufBuilder, node.CustomData)
	end
end

--#region ApplyInitialInfo
export type ApplyInitialInfoParams = {} & SerializeParams

function ValueByPrioritySerializer.ApplyInitialInfo(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	params: ApplyInitialInfoParams?
)
	local params = params or {}

		local isDestroyed = bufReader:ReadBoolBit()
	if isDestroyed then
		vbp:Destroy()
		return
	end
	local hasNodes = bufReader:ReadBoolBit()

	--#tag 타입
	local vbpTypeInfo = vbp.TypeInfo
	local hasDefinedVbpTypeInfo = false
	if not params.ExcludesTypeId then
		hasDefinedVbpTypeInfo = bufReader:ReadBoolBit()
		if hasDefinedVbpTypeInfo then
			vbpTypeInfo = ValueByPrioritySerializer._readTypeInfo(bufReader)
		end
	end
	
	if not vbpTypeInfo then
		local defaultTypeName = typeof(vbp.DefaultValue)
		vbpTypeInfo = TypeInfos.GetTypeInfoByTypeName(defaultTypeName)
	end

		local defaultValue = bufReader:ReadType(vbpTypeInfo)
	vbp:SetDefaultValue(defaultValue)

		if hasNodes then
		local nodeCount = bufReader:ReadU16()

		for _ = 1, nodeCount do
			ValueByPrioritySerializer._applyInitialNodeInfo(
				bufReader,
				vbp,
				vbpTypeInfo,
				hasDefinedVbpTypeInfo,
				params.ExcludesTypeId
			)
		end
	end
end

function ValueByPrioritySerializer._readTypeInfo(
	bufReader: BufferReader.BufferReader
): TypeInfos.TypeInfo
	local typeId = bufReader:ReadU8()
	local typeInfo: TypeInfos.TypeInfo

	if typeId == ENUM_TYPE_INFO_ID then
		-- Enum 타입 Id 추가 읽기
		local enumTypeId = bufReader:ReadU8()
		local enumTypeName = enumTypeNamesById[enumTypeId]
		if not enumTypeName then 
			error(`Invalid Enum Type Id received: {enumTypeId}`)
		end
		typeInfo = TypeInfos.GetTypeInfoByTypeName(enumTypeName)
	else
		-- 일반 타입 Id 사용
		local typeName = typeNamesById[typeId]
		if not typeName then
			error(`Invalid Type Id received: {typeId}`)
		end
		typeInfo = TypeInfos.GetTypeInfoByTypeName(typeName)
	end

	if not typeInfo then 
		error(`Failed to get TypeInfo from Id logic.`) 
	end
	return typeInfo
end

function ValueByPrioritySerializer._applyInitialNodeInfo(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	vbpTypeInfo: TypeInfos.TypeInfo?,
	hasDefinedVbpTypeInfo: boolean,
	excludesTypeId: boolean?
)
	local nodeId = bufReader:ReadU16()
	local priority = bufReader:ReadF64()
	
	local nodeFunction = ValueByPrioritySerializer._readNodeFunctionInfo(bufReader)
	local nodeValue = ValueByPrioritySerializer._readInitialNodeValueInfo(
		bufReader,
		nodeFunction,
		hasDefinedVbpTypeInfo,
		vbpTypeInfo,
		excludesTypeId
	)
	local customData = ValueByPrioritySerializer._readInitialNodeCustomDataInfo(bufReader)

	-- 읽은 정보로 노드 추가
	vbp:AddNode({
		Value = nodeValue,
		Priority = priority,
		NodeFunction = nodeFunction,
		CustomData = customData,
		_bakedNodeId = nodeId,
	})
end

function ValueByPrioritySerializer._readNodeFunctionInfo(
	bufReader: BufferReader.BufferReader
): ValueByPriority.NodeFunction
	local funcTypeFlag = bufReader:ReadU8()

	if funcTypeFlag == 0 then -- 기본 NodeFunction 문자열
		local funcId = bufReader:ReadU8()
		local funcName = nodeFunctionNamesById[funcId]
		if not funcName then error(`Invalid NodeFunction Id received: {funcId}`) end
		return funcName
	elseif funcTypeFlag == 1 then -- 커스텀 NodeFunction 모듈 스크립트
		local repId = bufReader:ReadU32()
		-- Id로부터 ModuleScript 인스턴스 찾기
		local moduleScript = ReplicatedInstanceId.WaitForInstanceFromId(repId, 1)
		if not moduleScript then
			error(`NodeFunction ModuleScript with Id {repId} not found yet.`)
		end
		
		return moduleScript
	else
		error(`Invalid NodeFunction type flag received: {funcTypeFlag}`)
	end
end

function ValueByPrioritySerializer._readInitialNodeValueInfo(
	bufReader: BufferReader.BufferReader,
	nodeFunction: string | ModuleScript, -- NodeFunction이 Set인지 확인
	hasDefinedVbpTypeInfo: boolean,
	vbpTypeInfo: TypeInfos.TypeInfo?,
	excludesTypeId: boolean?
): any
	local nodeValueTypeInfo: TypeInfos.TypeInfo? = nil

	local needsExplicitType = false
	if not excludesTypeId then
		local isSetNodeFunction = typeof(nodeFunction) == "string" and nodeFunction == "Set"
		if not hasDefinedVbpTypeInfo or not isSetNodeFunction then
			needsExplicitType = true
		end
	end

	if needsExplicitType then
		-- 노드 값의 타입 정보를 읽음
		nodeValueTypeInfo = ValueByPrioritySerializer._readTypeInfo(bufReader)
	elseif hasDefinedVbpTypeInfo then
		-- VBP에 정의된 타입을 사용
		nodeValueTypeInfo = vbpTypeInfo
	else
		-- VBP 타입도 없고, 명시적 타입 정보도 없는 경우 (오류 상황)
		error(`Cannot determine NodeValue type.`)
	end

	if not nodeValueTypeInfo then 
		error(`Failed to determine NodeValue TypeInfo.`) 
	end
	
	local nodeValue = bufReader:ReadType(nodeValueTypeInfo)
	return nodeValue
end

function ValueByPrioritySerializer._readInitialNodeCustomDataInfo(
	bufReader: BufferReader.BufferReader
): { [string]: any }?
	local hasCustomData = bufReader:ReadBoolBit()
	if not hasCustomData then
		return nil
	end

	local customData = {}
	local count = bufReader:ReadU8()

	for _ = 1, count do
		-- Key 역직렬화
		local keyLength = bufReader:ReadU8()
		local key = bufReader:ReadString(keyLength)

		-- Value 역직렬화 (타입 정보 읽고 -> 값 읽기)
		local valueTypeInfo = ValueByPrioritySerializer._readTypeInfo(bufReader)
		local value = bufReader:ReadType(valueTypeInfo)

		customData[key] = value
	end

	return customData
end

--#region BuildVbpChangeInfo
export type BuildVbpChangeInfoParams = {
	VbpTypeInfo: TypeInfos.TypeInfo?,
} & SerializeParams

function ValueByPrioritySerializer.BuildVbpChangeInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	changeInfo: ValueByPriorityObserver.VbpChangeInfo,
	params: BuildVbpChangeInfoParams?
)
	local params = params or {}
	
	-- 비트 마스크
	local isDestroyed = changeInfo.IsDestroyed == true
	local isDefaultValueChanged = changeInfo.DefaultValue ~= nil
	local hasReliableChanges = 
		changeInfo.ReliableNodeChangeInfosById and next(changeInfo.ReliableNodeChangeInfosById) ~= nil
	local hasUnreliableChanges =
		changeInfo.UnreliableNodeChangeInfosById and next(changeInfo.UnreliableNodeChangeInfosById) ~= nil
	
	bufBuilder:WriteBoolBit(isDestroyed)
	bufBuilder:WriteBoolBit(isDefaultValueChanged)
	bufBuilder:WriteBoolBit(hasReliableChanges)
	bufBuilder:WriteBoolBit(hasUnreliableChanges)

	-- DefaultValue 변경 사항을 기록합니다
	if isDefaultValueChanged then
		local value = mapNilIdentifierToNil(changeInfo.DefaultValue)

		local typeInfoForSerialization = 
			params.VbpTypeInfo
			or TypeInfos.GetTypeInfoByValueType(value)
		
		if params.VbpTypeInfo and not params.ExcludesTypeId then
			-- VbpTypeInfo 가 있다면 그것을 우선 사용하고, Exclude 가 아닐때만 ID 기록
			ValueByPrioritySerializer._buildTypeInfo(bufBuilder, typeInfoForSerialization)
		end
		bufBuilder:WriteType(typeInfoForSerialization, value)
	end
	
	if hasReliableChanges then
		ValueByPrioritySerializer._buildReliableChangeInfos(
			bufBuilder, changeInfo.ReliableNodeChangeInfosById :: any, params
		)
	end
	
	if hasUnreliableChanges then
		ValueByPrioritySerializer._buildUnreliableChangeInfos(
			bufBuilder, changeInfo.UnreliableNodeChangeInfosById :: any, params
		)
	end
end

function ValueByPrioritySerializer._buildReliableChangeInfos(
	bufBuilder: BufferBuilder.BufferBuilder,
	reliableNodeInfos: { [number]: ValueByPriorityObserver.ReliableNodeChangeInfo },
	params: BuildVbpChangeInfoParams
)
	local reliableNodeCount = TableUtil.count(reliableNodeInfos)
	bufBuilder:WriteU16(reliableNodeCount) -- 변경된 Reliable 노드 개수를 먼저 기록합니다.

	for nodeId, nodeChangeInfo in reliableNodeInfos do
		bufBuilder:WriteU16(nodeId)
		ValueByPrioritySerializer._buildReliableNodeChangeInfo(
			bufBuilder,
			nodeChangeInfo,
			params
		)
	end
end

function ValueByPrioritySerializer._buildReliableNodeChangeInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	nodeChangeInfo: ValueByPriorityObserver.ReliableNodeChangeInfo,
	params: BuildVbpChangeInfoParams
)

	local isDestroyed = nodeChangeInfo.IsDestroyed == true
	local isAdded = nodeChangeInfo.IsAdded == true
	local isPriorityChanged = nodeChangeInfo.Priority ~= nil
	local isValueChanged = nodeChangeInfo.Value ~= nil
	local isCustomDataChanged = nodeChangeInfo.CustomData and next(nodeChangeInfo.CustomData) ~= nil

	-- 비트 마스크
	bufBuilder:WriteBoolBit(isDestroyed)
	bufBuilder:WriteBoolBit(isAdded)
	bufBuilder:WriteBoolBit(isPriorityChanged)
	bufBuilder:WriteBoolBit(isValueChanged)
	bufBuilder:WriteBoolBit(isCustomDataChanged)

	if isDestroyed then
		-- 노드가 파괴된 경우, 추가 정보는 의미가 없으므로 기록하지 않습니다
		return
		
	elseif isAdded then
		ValueByPrioritySerializer._buildNodeChangeInfoOnAdded(
			bufBuilder,
			nodeChangeInfo,
			params
		)
	else
		ValueByPrioritySerializer._buildNodeChangeInfoOnChanged(
			bufBuilder,
			nodeChangeInfo,
			isPriorityChanged,
			isValueChanged,
			isCustomDataChanged,
			params
		)
	end
end

--#tag Added
function ValueByPrioritySerializer._buildNodeChangeInfoOnAdded(
	bufBuilder: BufferBuilder.BufferBuilder,
	nodeChangeInfo: ValueByPriorityObserver.ReliableNodeChangeInfo,
	params: BuildVbpChangeInfoParams
)
	-- 새로 추가된 노드는 모든 초기 상태 정보를 포함해야 합니다.
	bufBuilder:WriteF64(nodeChangeInfo.Priority)

	local nodeFunc = nodeChangeInfo.NodeFunction
	local isSetNodeFunction = nodeFunc == "Set"
	ValueByPrioritySerializer._buildNodeFunctionInfo(
		bufBuilder, 
		nodeChangeInfo.NodeFunction :: any
	)

	local value = mapNilIdentifierToNil(nodeChangeInfo.Value)
	local typeInfoForSerialization
	local needsTypeId = true

	if params.VbpTypeInfo and isSetNodeFunction then
		typeInfoForSerialization = params.VbpTypeInfo
		needsTypeId = not params.ExcludesTypeId
	else
		typeInfoForSerialization = TypeInfos.GetTypeInfoByTypeName(typeof(value))
	end

	if needsTypeId then
		ValueByPrioritySerializer._buildTypeInfo(bufBuilder, typeInfoForSerialization)
	end
	bufBuilder:WriteType(typeInfoForSerialization, value)

	ValueByPrioritySerializer._buildNodeCustomDataOnAdded(bufBuilder, nodeChangeInfo.CustomData)
end

function ValueByPrioritySerializer._buildNodeCustomDataOnAdded(
	bufBuilder: BufferBuilder.BufferBuilder,
	customData: { [string]: any }?
)
	local hasCustomData = customData and next(customData) ~= nil
	bufBuilder:WriteBoolBit(hasCustomData)

	if hasCustomData then
		ValueByPrioritySerializer._buildNodeCustomData(bufBuilder, customData :: any)
	end
end



--#tag Change
function ValueByPrioritySerializer._buildNodeChangeInfoOnChanged(
	bufBuilder: BufferBuilder.BufferBuilder,
	nodeChangeInfo: ValueByPriorityObserver.ReliableNodeChangeInfo,
	isPriorityChanged: boolean,
	isValueChanged: boolean,
	isCustomDataChanged: boolean,
	params: BuildVbpChangeInfoParams
)
	-- 기존 노드가 업데이트된 경우, 변경된 필드의 정보만 기록합니다.
	
	if isValueChanged then
		--[[
			대부분의 경우엔 NodeFunction 은 필요하지 않습니다, 
			왜냐하면 추가할 때 NodeFunction 이 서로 다른 컨텍스트에서 동기화 될 것이고
			이후 바뀌지도 않으니 문제없으나,
			처리 오류나 지연 등으로, 노드가 추가되지 않았거나 지워졌다면
			받는 컨텍스트에선 NodeFunction 이 무엇인지 알 수 없습니다,
			그리고 Set NodeFunction에는 TypeId를 쓰지 않아도 될 때가 있는데,
			Set 이라서 타입 아이디가 없는 상태인지 알 수 없기에, 정확하게 읽을 수 없고, 길이가 얼만지 알지 못하게됩니다.
			그래서 이를 방지하기 위해 비트마스크에 NodeFunction 이 Set 인지도 확인하는 비트를 추가합니다.
		]]
		local isSetNodeFunction = nodeChangeInfo.NodeFunction == "Set"
		bufBuilder:WriteBoolBit(isSetNodeFunction)
		
		ValueByPrioritySerializer._buildNodeValue(
			bufBuilder,
			nodeChangeInfo.Value,
			nodeChangeInfo.NodeFunction :: any,
			params
		)
	end

	if isCustomDataChanged then
		ValueByPrioritySerializer._buildNodeCustomData(bufBuilder, nodeChangeInfo.CustomData :: any)
	end
	
	if isPriorityChanged then
		bufBuilder:WriteF64(nodeChangeInfo.Priority)
	end
end



function ValueByPrioritySerializer._buildUnreliableChangeInfos(
	bufBuilder: BufferBuilder.BufferBuilder,
	unreliableNodeInfosById: { [number]: ValueByPriorityObserver.UnreliableNodeChangeInfo },
	params: BuildVbpChangeInfoParams
)
	local unreliableNodeCount = TableUtil.count(unreliableNodeInfosById)
	bufBuilder:WriteU16(unreliableNodeCount)

	for nodeId, nodeChangeInfo in unreliableNodeInfosById do
		bufBuilder:WriteU16(nodeId)
		ValueByPrioritySerializer._buildUnreliableNodeChangeInfo(
			bufBuilder,
			nodeChangeInfo,
			params
		)
	end
end

function ValueByPrioritySerializer._buildUnreliableNodeChangeInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	nodeChangeInfo: ValueByPriorityObserver.UnreliableNodeChangeInfo,
	params: BuildVbpChangeInfoParams
)
	local isValueChanged = nodeChangeInfo.Value ~= nil
	local isCustomDataChanged = nodeChangeInfo.CustomData ~= nil

	bufBuilder:WriteBoolBit(isValueChanged)
	bufBuilder:WriteBoolBit(isCustomDataChanged)

	if isValueChanged then
		ValueByPrioritySerializer._buildNodeValue(
			bufBuilder, 
			mapNilIdentifierToNil(nodeChangeInfo.Value), 
			nodeChangeInfo.NodeFunction :: any, 
			params
		)
	end
	
	if isCustomDataChanged then
		ValueByPrioritySerializer._buildNodeCustomData(
			bufBuilder, 
			nodeChangeInfo.CustomData :: any
		)
	end
end


--#region ApplyVbpChangeInfo
export type ApplyVbpChangeInfoParams = {
	VbpTypeInfo: TypeInfos.TypeInfo?,
	SerializedTime: number?,
} & SerializeParams

function ValueByPrioritySerializer.ApplyVbpChangeInfo(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	params: ApplyVbpChangeInfoParams?
)
	local params = params or {}

	-- 비트 마스크
	local isDestroyed = bufReader:ReadBoolBit()
	local isDefaultValueChanged = bufReader:ReadBoolBit()
	local hasReliableChanges = bufReader:ReadBoolBit()
	local hasUnreliableChanges = bufReader:ReadBoolBit()

	if isDestroyed then
		-- 파괴 신호를 보내면 즉시 객체를 파괴하고 종료합니다.
		vbp:Destroy()
		return
	end

	-- DefaultValue 변경 사항을 적용합니다.
	if isDefaultValueChanged then
		local typeInfoToRead
		if params.VbpTypeInfo and not params.ExcludesTypeId then
			-- 타입 ID가 기록되었을 것으로 예상되므로 읽습니다.
			typeInfoToRead = ValueByPrioritySerializer._readTypeInfo(bufReader)
			-- 읽은 타입과 VbpTypeInfo가 다르면 잠재적 오류지만, 일단 진행합니다.
			 assert(typeInfoToRead == params.VbpTypeInfo, "Mismatch VbpTypeInfo")
		else
			-- 타입 ID가 기록되지 않았으므로 VbpTypeInfo 또는 현재 값 타입을 사용합니다.
			typeInfoToRead = params.VbpTypeInfo or TypeInfos.GetTypeInfoByTypeName(typeof(vbp:GetDefaultValue()))
		end
		local value = bufReader:ReadType(typeInfoToRead)
		vbp:SetDefaultValue(value)
	end

	-- Reliable 변경 사항들을 적용합니다. (노드 추가/삭제/변경)
	if hasReliableChanges then
		ValueByPrioritySerializer._applyReliableChangeInfos(bufReader, vbp, params)
	end

	-- Unreliable 변경 사항들을 적용합니다. (주로 값 업데이트)
	if hasUnreliableChanges then
		ValueByPrioritySerializer._applyUnreliableChangeInfos(bufReader, vbp, params)
	end
end

function ValueByPrioritySerializer._applyReliableChangeInfos(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	params: ApplyVbpChangeInfoParams
)
	local reliableNodeCount = bufReader:ReadU16()
	for _ = 1, reliableNodeCount do
		local nodeId = bufReader:ReadU16()
		ValueByPrioritySerializer._applyReliableNodeChangeInfo(
			bufReader,
			vbp,
			nodeId,
			params
		)
	end
end

function ValueByPrioritySerializer._applyReliableNodeChangeInfo(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	nodeId: number,
	params: ApplyVbpChangeInfoParams
)
	local node = vbp.NodesById[nodeId]

	-- 변경 플래그 읽기
	local isDestroyed = bufReader:ReadBoolBit()
	local isAdded = bufReader:ReadBoolBit()
	local isPriorityChanged = bufReader:ReadBoolBit()
	local isValueChanged = bufReader:ReadBoolBit()
	local isCustomDataChanged = bufReader:ReadBoolBit()

	if isDestroyed then
		if node then 
			node:Destroy() 
		end
		-- 노드가 파괴된 경우, 추가 데이터가 없어야하며, 그렇기에 읽지 않습니다.
		return
	end

	if isAdded then
		ValueByPrioritySerializer._applyNodeChangeInfoOnAdded(bufReader, vbp, nodeId, params)
	elseif node then -- Node Update
		ValueByPrioritySerializer._applyNodeChangeInfoOnChanged(
			bufReader,
			node,
			isPriorityChanged,
			isValueChanged,
			isCustomDataChanged,
			params
		)
	else
		--[[
			노드 동기화가 안된 경우
			업데이트할 노드가 없는 경우, 기록된 데이터를 읽고 무시합니다.
		]]
		warn(`존재하지 않거나 파괴된 노드 Id {nodeId}의 업데이트 시도. 변경사항을 건너뜁니다.`)
		ValueByPrioritySerializer._skipNodeChangeInfoOnChanged(
			bufReader,
			isPriorityChanged,
			isValueChanged,
			isCustomDataChanged,
			params
		)
	end
end

--#tag Added
function ValueByPrioritySerializer._applyNodeChangeInfoOnAdded(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	nodeId: number,
	params: ApplyVbpChangeInfoParams
)
	-- 추가된 노드의 전체 정보 읽기
	local priority = bufReader:ReadF64()
	local nodeFunction = ValueByPrioritySerializer._readNodeFunctionInfo(bufReader)
	local value = ValueByPrioritySerializer._readNodeValue(bufReader, nodeFunction, params)
	local customData = ValueByPrioritySerializer._readNodeCustomDataOnAdded(bufReader)

	vbp:AddNode({
		Value = value, 
		Priority = priority,
		NodeFunction = nodeFunction,
		CustomData = customData, 
		_bakedNodeId = nodeId,
	})
end

--#tag CustomData Added
function ValueByPrioritySerializer._readNodeCustomDataOnAdded(
	bufReader: BufferReader.BufferReader
): { [string]: any }?
	local hasCustomData = bufReader:ReadBoolBit()
	if not hasCustomData then
		return nil
	end
	-- 전체 데이터 역직렬화는 변경된 데이터 역직렬화와 형식이 동일합니다.
	return ValueByPrioritySerializer._readNodeCustomData(bufReader)
end


--#tag Change
function ValueByPrioritySerializer._applyNodeChangeInfoOnChanged(
	bufReader: BufferReader.BufferReader,
	node: ValueByPriority.Node,
	isPriorityChanged: boolean,
	isValueChanged: boolean,
	isCustomDataChanged: boolean,
	params: ApplyVbpChangeInfoParams
)
	if isValueChanged then
		-- isSetNodeFunction 비트는
		-- Skip 시 타입 Id 읽기 여부를 위한 비트이기에 여기엔 필요없지만, 
		-- 혹시 모르니까 비트 단위로도 커서를 맞춰줍니다
		local _isSetNodeFunction = bufReader:ReadBoolBit() 
		
		local value = ValueByPrioritySerializer._readNodeValue(bufReader, node.NodeFunction, params)
		
		if params.SerializedTime and params.SerializedTime <= node._valueChangedTime then
			return
		end
		node:SetValue(value)
	end

	if isCustomDataChanged then
		local changedData = ValueByPrioritySerializer._readNodeCustomData(bufReader, true)
		if changedData then
			for key, value in changedData do
				node:SetCustomData(key, mapNilIdentifierToNil(value))
			end
		end
	end
	
	if isPriorityChanged then
		local priority = bufReader:ReadF64()
		node:SetPriority(priority)
	end
end

--#tag Skip
--[[
	노드 동기화에 실패했거나, 노드가 제거 되었는데
	해당 노드 Id 에 대한 노드 정보가 버퍼에 있다면,
	그 정보의 길이만큼 읽어주고, 커서를 옮겨서 다음 노드를 읽어야합니다.
]]
function ValueByPrioritySerializer._skipNodeChangeInfoOnChanged(
	bufReader: BufferReader.BufferReader,
	isPriorityChanged: boolean,
	isValueChanged: boolean,
	isCustomDataChanged: boolean,
	params: ApplyVbpChangeInfoParams
)
	if isValueChanged then
		local isSetNodeFunction = bufReader:ReadBoolBit()
		local fakeNodeFunction = if isSetNodeFunction
			then "Set"
			else "Multiply"
		local value = ValueByPrioritySerializer._readNodeValue(bufReader, fakeNodeFunction, params)
	end

	if isCustomDataChanged then
		ValueByPrioritySerializer._readNodeCustomData(bufReader)
	end

	if isPriorityChanged then
		bufReader:ReadF64()
	end
end


function ValueByPrioritySerializer._applyUnreliableChangeInfos(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	params: ApplyVbpChangeInfoParams
)
	local unreliableNodeCount = bufReader:ReadU16()
	for _ = 1, unreliableNodeCount do
		local nodeId = bufReader:ReadU16()
		ValueByPrioritySerializer._applyUnreliableNodeChangeInfo(
			bufReader,
			vbp,
			nodeId,
			params
		)
	end
end

function ValueByPrioritySerializer._applyUnreliableNodeChangeInfo(
	bufReader: BufferReader.BufferReader,
	vbp: ValueByPriority.ValueByPriority,
	nodeId: number,
	params: ApplyVbpChangeInfoParams
)
	local node = vbp.NodesById[nodeId]
	
	local isValueChanged = bufReader:ReadBoolBit()
	local isCustomDataChanged = bufReader:ReadBoolBit()
	
	if isValueChanged then
		local value = ValueByPrioritySerializer._readNodeValue(bufReader, node.NodeFunction, params)
		node:SetValue(value)
	end

	if isCustomDataChanged then
		local customData = ValueByPrioritySerializer._readNodeCustomData(bufReader)
		for key, val in customData do
			node:SetCustomData(key, val)
		end
	end
end

--#region Internal Helper Functions

--#tag Value
--#tag Build
function ValueByPrioritySerializer._buildNodeValue(
	bufBuilder: BufferBuilder.BufferBuilder,
	value: any,
	nodeFunction: ValueByPriority.NodeFunction,
	params: BuildVbpChangeInfoParams
)
	local isSetNodeFunction = nodeFunction == "Set"

	local typeInfoForSerialization
	
	--[[
		NodeFunction 이 Set 이고 Vbp 에 TypeInfo 가 정의되어있다면,
		Set 인 노드들의 Value도 해당 TypeInfo 에 맞게 설정됩니다.
		Set 인 노드들은 자주 사용되기에, 따로 타입 아이디를 넣지 않아도 됩니다.
		대신 NodeFunction 이 Set 이 아닌 경우, 노드의 Value는 Vbp TypeInfo와 다를 수 있으니
		값 저장시, 값의 타입 아이디도 저장해야합니다.
	]]
	local needsTypeId = true
	if params.VbpTypeInfo and isSetNodeFunction then
		typeInfoForSerialization = params.VbpTypeInfo
		needsTypeId = not params.ExcludesTypeId
	else
		typeInfoForSerialization = TypeInfos.GetTypeInfoByValueType(value)
	end

	if needsTypeId then
		ValueByPrioritySerializer._buildTypeInfo(bufBuilder, typeInfoForSerialization)
	end

	bufBuilder:WriteType(typeInfoForSerialization, value)
end

--#tag Read
function ValueByPrioritySerializer._readNodeValue(
	bufReader: BufferReader.BufferReader,
	nodeFunction: ValueByPriority.NodeFunction?,
	params: ApplyVbpChangeInfoParams
): any
	local typeInfoToRead
	local isSetNodeFunction = nodeFunction == "Set"
	local needsTypeId = true

	if params.VbpTypeInfo and isSetNodeFunction then
		needsTypeId = not params.ExcludesTypeId
	end

	if needsTypeId then
		-- VBP 타입이 없거나 함수가 "Set"이 아니면 항상 타입 ID가 기록됨
		typeInfoToRead = ValueByPrioritySerializer._readTypeInfo(bufReader)
	else
		-- 타입 ID가 기록되지 않은 경우, params.VbpTypeInfo가 반드시 있어야 함
		assert(params.VbpTypeInfo, `VbpTypeInfo is required when TypeId is excluded for Set node.`)
		typeInfoToRead = params.VbpTypeInfo
	end

	return bufReader:ReadType(typeInfoToRead)
end

--#tag CustomData
--#tag Build
function ValueByPrioritySerializer._buildNodeCustomData(
	bufBuilder: BufferBuilder.BufferBuilder,
	customData: { [string]: any }
)
	local customDataCount = TableUtil.count(customData)
	bufBuilder:WriteU8(customDataCount)

	for key, value in customData do
		value = mapNilIdentifierToNil(value)

		bufBuilder:WriteU8(#key)
		bufBuilder:WriteString(key)

		-- CustomData 값은 VbpTypeInfo의 영향을 받지 않으므로 항상 실제 값의 타입 ID를 기록합니다.
		local typeInfo = TypeInfos.GetTypeInfoByTypeName(typeof(value))
		ValueByPrioritySerializer._buildTypeInfo(bufBuilder, typeInfo) 
		bufBuilder:WriteType(typeInfo, value)
	end
end

--#tag Read
function ValueByPrioritySerializer._readNodeCustomData(
	bufReader: BufferReader.BufferReader,
	mapsNilToNilIdentifier: boolean?
): { [string]: any }
	local changedData = {}
	local changeCount = bufReader:ReadU8()

	for _ = 1, changeCount do
		local keyLength = bufReader:ReadU8()
		local key = bufReader:ReadString(keyLength)

		-- CustomData 값은 항상 타입 ID가 기록되어 있으므로 읽습니다.
		local typeInfo = ValueByPrioritySerializer._readTypeInfo(bufReader)
		local value = bufReader:ReadType(typeInfo)

		changedData[key] = if mapsNilToNilIdentifier and value == nil
			then NIL_IDENTIFIER
			else value
	end

	return changedData
end

--#tag Type
--#tag build
function ValueByPrioritySerializer._buildTypeInfo(
	bufBuilder: BufferBuilder.BufferBuilder,
	typeInfo: TypeInfos.TypeInfo
)
	local typeId = typeIdsByName[typeInfo.Name]
	bufBuilder:WriteU8(typeId)

	-- Enum Id 추가 기록
	-- Read 할 때는 typeId == ENUM_TYPE_INFO_Id 로 Enum 타입인지 확인합니다.
	if typeInfo.IsEnum then
		local enumTypeId = enumTypeIdsByName[typeInfo.Name]
		bufBuilder:WriteU8(enumTypeId)
	end
end


return ValueByPrioritySerializer
