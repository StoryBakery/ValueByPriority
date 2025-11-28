local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BufferBuilder = require("../roblox_packages/BufferBuilder")
local BufferReader = require("../roblox_packages/BufferReader")
local Maid = require("../roblox_packages/Maid")
local Signal = require("../roblox_packages/Signal")
local TableUtil = require("../roblox_packages/TableUtil")
local AuroraClock = require("../roblox_packages/AuroraClock")

local ValueByPriority = require("./")
local ValueByPriorityObserver = require("./Observer")
local ValueByPrioritySerializer = require("./Serializer")

local Remotes = script.Parent.Remotes
local SyncFromServerEvent = Remotes.SyncFromServerEvent
local DesyncFromServerEvent = Remotes.DesyncFromServerEvent
local UnreliableSyncFromServerEvent = Remotes.UnreliableSyncFromServerEvent
local ApplyInitialVbpEvent = Remotes.ApplyInitialVbpEvent

type ObserverContext = {
	Observer: ValueByPriorityObserver.ValueByPriorityObserver,
	Maid: Maid.Maid,
}

local observerContextsByPlayerAndVbpId: {
	[Player]: { [string]: ObserverContext },
} = {}

local queuedReliableChangeInfoByPlayerAndVbpId: { [Player]: { [string]: ValueByPriorityObserver.VbpChangeInfo } } = {}
local queuedUnreliableChangeInfosByPlayerAndVbpId: { [Player]: { [string]: ValueByPriorityObserver.VbpChangeInfo } } =
	{}

-- 변경 사항이 있는 플레이어 추적용 Set
local playerWithPendingChangesSet: { [Player]: boolean } = {}

--[[
	각 플레이어의 VBP 동기화 상태를 독립적으로 관리하기 위해 Observer 컨텍스트를 조회하거나 새로 생성합니다.
]]
local function getObserverContextsByVbpIdFromPlayer(player: Player): { [string]: ObserverContext }
	if not observerContextsByPlayerAndVbpId[player] then
		observerContextsByPlayerAndVbpId[player] = {}
	end
	return observerContextsByPlayerAndVbpId[player]
end

--[[
	특정 플레이어의 특정 VBP ID에 대한 Observer 컨텍스트 및 관련 리소스를 정리합니다.
	더 이상 동기화가 필요하지 않은 VBP에 대한 메모리 누수를 방지하기 위함입니다.
]]
local function cleanupObserverContext(player: Player, vbpId: string)
	local observerContextsByVbpId = observerContextsByPlayerAndVbpId[player] -- 해당 플레이어의 VbpId별 컨텍스트 맵
	if observerContextsByVbpId and observerContextsByVbpId[vbpId] then
		observerContextsByVbpId[vbpId].Maid:Destroy()
		observerContextsByVbpId[vbpId] = nil
	end

	if queuedReliableChangeInfoByPlayerAndVbpId[player] then
		queuedReliableChangeInfoByPlayerAndVbpId[player][vbpId] = nil
	end
	if queuedUnreliableChangeInfosByPlayerAndVbpId[player] then
		queuedUnreliableChangeInfosByPlayerAndVbpId[player][vbpId] = nil
	end
end

local function cleanupObserverContextsByPlayer(player: Player)
	playerWithPendingChangesSet[player] = nil
	if queuedReliableChangeInfoByPlayerAndVbpId[player] then
		queuedReliableChangeInfoByPlayerAndVbpId[player] = nil
	end
	if queuedUnreliableChangeInfosByPlayerAndVbpId[player] then
		queuedUnreliableChangeInfosByPlayerAndVbpId[player] = nil
	end

	local contextsByVbpId = observerContextsByPlayerAndVbpId[player]
	if contextsByVbpId then
		for vbpIdForCleanup, _ in contextsByVbpId do
			cleanupObserverContext(player, vbpIdForCleanup)
		end
		observerContextsByPlayerAndVbpId[player] = nil
	end
end

--#region Change Process
--[[
	매 Heartbeat마다 큐에 쌓인 모든 플레이어의 VBP 변경 사항들을 일괄적으로 직렬화하고 전송합니다.
	이를 통해 RemoteEvent 호출 빈도를 줄여 네트워크 부하를 최적화합니다.
]]

local function processQueuedChangeInfosForPlayer(player: Player)
	if not player.Parent then
		cleanupObserverContextsByPlayer(player)
		return
	end

	local reliableChangeInfos = queuedReliableChangeInfoByPlayerAndVbpId[player]
	local unreliableInfos = queuedUnreliableChangeInfosByPlayerAndVbpId[player]

	-- Reliable 변경 사항 일괄 전송
	if reliableChangeInfos then
		local reliableBuilder = BufferBuilder.new()
		local vbpCount = TableUtil.count(reliableChangeInfos)
		reliableBuilder:WriteU16(vbpCount) -- 변경된 VBP 개수 기록
		reliableBuilder:WriteF64(AuroraClock.GetServerTime())

		for vbpId, changeInfo in reliableChangeInfos do
			local vbp = ValueByPriority.FindById(vbpId)
			reliableBuilder:WriteU16(#vbpId)
			reliableBuilder:WriteString(vbpId)
			ValueByPrioritySerializer.BuildVbpChangeInfo(reliableBuilder, changeInfo, {
				VbpTypeInfo = vbp.TypeInfo,
				ExcludesTypeId = false,
			})
		end
		if reliableBuilder:GetLength() > 6 then -- VBP 개수/생성 시간 외에 데이터가 있는지 확인
			SyncFromServerEvent:FireClient(player, reliableBuilder:Build())
		end
		queuedReliableChangeInfoByPlayerAndVbpId[player] = {} -- 전송 후 큐 비우기
	end

	-- Unreliable 변경 사항 일괄 전송
	if unreliableInfos then
		local unreliableBuilder = BufferBuilder.new()
		local vbpCount = TableUtil.count(unreliableInfos)
		unreliableBuilder:WriteU16(vbpCount) -- 변경된 VBP 개수 기록
		unreliableBuilder:WriteF64(AuroraClock.GetServerTime())

		for vbpId, changeInfo in unreliableInfos do
			local vbp = ValueByPriority.FindById(vbpId)
			if vbp and not vbp.IsDestroyed then -- VBP가 유효한지 확인
				unreliableBuilder:WriteU16(#vbpId)
				unreliableBuilder:WriteString(vbpId)
				ValueByPrioritySerializer.BuildVbpChangeInfo(unreliableBuilder, changeInfo, {
					VbpTypeInfo = vbp.TypeInfo,
					ExcludesTypeId = false,
				})
			end
		end
		if unreliableBuilder:GetLength() > 6 then -- VBP 개수/생성 시간 외에 데이터가 있는지 확인
			UnreliableSyncFromServerEvent:FireClient(player, unreliableBuilder:Build())
		end
		queuedUnreliableChangeInfosByPlayerAndVbpId[player] = {} -- 전송 후 큐 비우기
	end

	-- 해당 플레이어에게 더 이상 보낼 변경 사항이 없으면 목록에서 제거
	if
		(not reliableChangeInfos or not next(reliableChangeInfos))
		and (not unreliableInfos or not next(unreliableInfos))
	then
		playerWithPendingChangesSet[player] = nil
	end
end

local function processQueuedChangeInfos()
	-- 검사도 Heartbeat 로 하니까 task.defer 로 기다려줘서
	-- 일부 ChangeInfo 빼먹지 않게 합니다
	task.defer(coroutine.running())
	coroutine.yield()

	for player, _ in playerWithPendingChangesSet do
		processQueuedChangeInfosForPlayer(player)
	end

	table.clear(playerWithPendingChangesSet)
end

RunService.Heartbeat:Connect(processQueuedChangeInfos)

--#region Player Removing
--[[
	플레이어가 게임에서 나갈 경우, 해당 플레이어와 관련된 모든 동기화 정보(Observer 컨텍스트, 변경 사항 큐 등)를
	정리하여 메모리 누수를 방지합니다.
]]
local function onPlayerRemoving(player: Player)
	local observerContextsByVbpId = observerContextsByPlayerAndVbpId[player] -- 로컬 변수 이름 변경
	if observerContextsByVbpId then
		for _, observerData in observerContextsByVbpId do
			observerData.Maid:Destroy()
		end
		observerContextsByPlayerAndVbpId[player] = nil -- 전역 테이블에서 해당 플레이어 항목 제거
	end

	queuedReliableChangeInfoByPlayerAndVbpId[player] = nil
	queuedUnreliableChangeInfosByPlayerAndVbpId[player] = nil
	playerWithPendingChangesSet[player] = nil
end

Players.PlayerRemoving:Connect(onPlayerRemoving)

--#region Change Queue
--[[
	VBP 객체에서 발생한 변경 사항을 해당 플레이어의 전송 큐에 추가합니다.
	큐에 추가된 정보는 다음 Heartbeat 주기에 일괄 처리됩니다.
	Reliable 하고 Unreliable 은 각각 다른 Remote Event 에 보내야하니까
	ChangeInfo 를 Reliable 과 Unreliable 로 나누고 빌드하게 합니다
]]

local function queueVbpReliableChangeInfo(
	player: Player,
	reliableChangeInfo: ValueByPriorityObserver.VbpChangeInfo,
	vbpId: string
)
	if not queuedReliableChangeInfoByPlayerAndVbpId[player] then
		queuedReliableChangeInfoByPlayerAndVbpId[player] = {}
	end

	queuedReliableChangeInfoByPlayerAndVbpId[player][vbpId] = reliableChangeInfo
	playerWithPendingChangesSet[player] = true
end

local function queueVbpUnreliableChangeInfo(
	player: Player,
	unreliableChangeInfo: ValueByPriorityObserver.VbpChangeInfo,
	vbpId: string
)
	if not queuedUnreliableChangeInfosByPlayerAndVbpId[player] then
		queuedUnreliableChangeInfosByPlayerAndVbpId[player] = {}
	end

	queuedUnreliableChangeInfosByPlayerAndVbpId[player][vbpId] = unreliableChangeInfo
	playerWithPendingChangesSet[player] = true
end

local function queueVbpChanges(
	player: Player,
	vbp: ValueByPriority.ValueByPriority,
	changeInfo: ValueByPriorityObserver.VbpChangeInfo
)
	local vbpId = vbp.Id
	if not vbpId then
		warn(`VbpId is nil for ValueByPriority "{vbp}"`)
		return
	end

	local reliableChangeInfo, unreliableChangeInfo =
		ValueByPriorityObserver.SeparateChangeInfoIntoReliableAndUnreliable(changeInfo)

	if reliableChangeInfo then
		queueVbpReliableChangeInfo(player, reliableChangeInfo, vbpId)
	end

	if unreliableChangeInfo then
		queueVbpUnreliableChangeInfo(player, unreliableChangeInfo, vbpId)
	end
end

--#1 Request
--#region Sync
--[[
	클라이언트로부터 VBP 동기화 시작 요청을 받으면, 해당 VBP에 대한 Observer를 설정하고
	초기 상태 정보를 클라이언트로 전송합니다. 이후 변경 사항은 큐를 통해 관리됩니다.
]]

local function createObserverContext(player: Player, vbp: ValueByPriority.ValueByPriority): ObserverContext
	local observer = ValueByPriorityObserver.fromValueByPriority(vbp)

	local maid = Maid.new()
	maid:GiveTask(observer)

	maid:GiveTask(observer.ChangeRecorded:Connect(function(changeInfo)
		queueVbpChanges(player, vbp, changeInfo)
	end))

	maid:GiveTask(vbp.Destroying:Connect(function()
		cleanupObserverContext(player, vbp.Id :: string)
	end))

	return {
		Observer = observer,
		Maid = maid,
	}
end

local initialInfoBuilderContextsByPlayer = {} :: { [Player]: {
	Count: number,
	Builder: BufferBuilder.BufferBuilder,
} }
local function onRequestedSyncFromServer(player: Player, idsToSyncBuffer: buffer)
	local reader = BufferReader.fromBuffer(idsToSyncBuffer)
	local length = buffer.len(idsToSyncBuffer)

	local observerContextsByVbpId = getObserverContextsByVbpIdFromPlayer(player) -- 로컬 변수 이름 변경

	while reader:GetCursor() < length do
		local idLength = reader:ReadU16()
		local vbpId = reader:ReadString(idLength)

		if observerContextsByVbpId[vbpId] then
			warn(`Player "{player}" requested sync for already synced VbpId "{vbpId}"`)
			continue
		end

		local vbp = ValueByPriority.FindById(vbpId)
		if not vbp then
			warn(`Player "{player}" requested sync for non-existent VbpId "{vbpId}"`)
			continue
		elseif vbp.IsDestroyed then
			warn(`Player "{player}" requested sync for destroyed VbpId "{vbpId}"`)
			continue
		end

		local observerContext = createObserverContext(player, vbp)

		observerContextsByVbpId[vbpId] = observerContext

		local builderContext = initialInfoBuilderContextsByPlayer[player]
		local initialInfoBuilder

		if builderContext == nil then
			builderContext = {}
			initialInfoBuilderContextsByPlayer[player] = builderContext

			builderContext.Count = 1

			initialInfoBuilder = BufferBuilder.new()
			builderContext.Builder = initialInfoBuilder

			initialInfoBuilder:WriteU16(1) -- vbp 개수, 이후 빌드한 buffer 에서 진짜 개수로 덮습니다
		else
			builderContext.Count += 1
		end

		initialInfoBuilder:WriteU16(#vbpId)
		initialInfoBuilder:WriteString(vbpId)
		ValueByPrioritySerializer.BuildInitialInfo(initialInfoBuilder, vbp, {
			ExcludesTypeId = false,
		})
	end
end

SyncFromServerEvent.OnServerEvent:Connect(onRequestedSyncFromServer)

local function sendQueuedInitialBuffers()
	task.defer(coroutine.running())
	coroutine.yield()

	for player, builderContext in initialInfoBuilderContextsByPlayer do
		local buf = builderContext.Builder:Build()
		buffer.writeu16(buf, 0, builderContext.Count)

		ApplyInitialVbpEvent:FireClient(player, buf)
	end

	table.clear(initialInfoBuilderContextsByPlayer)
end

RunService.Heartbeat:Connect(sendQueuedInitialBuffers)

--#region Desync
--[[
	클라이언트로부터 VBP 동기화 해제 요청을 받으면, 해당 VBP에 대한 Observer 컨텍스트를 정리하여
	더 이상 해당 클라이언트에게 업데이트를 전송하지 않도록 합니다.
]]
local function onDesyncFromServer(player: Player, idsToDesyncBuffer: buffer)
	local reader = BufferReader.fromBuffer(idsToDesyncBuffer)
	while reader:GetCursor() < buffer.len(idsToDesyncBuffer) do
		local idLength = reader:ReadU16()
		local vbpId = reader:ReadString(idLength)
		cleanupObserverContext(player, vbpId)
	end
end

DesyncFromServerEvent.OnServerEvent:Connect(onDesyncFromServer)
