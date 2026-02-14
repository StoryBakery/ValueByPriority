--[[
	Vbp를 찾을 수 없는 경우, 이 VBP에 대한 나머지 데이터를 건너뛰어야 합니다.
	임시 Vbp 를 만들어 스킵합니다.
]]

local BufferReader = require("../roblox_packages/BufferReader")
local Maid = require("../roblox_packages/Maid")
local ValueByPriority = require("./")
local ValueByPrioritySerializer = require("./Serializer")

local Remotes = script.Parent.Remotes
local ApplyInitialVbpEvent = Remotes.ApplyInitialVbpEvent
local SyncFromServerEvent = Remotes.SyncFromServerEvent
local UnreliableSyncFromServerEvent = Remotes.UnreliableSyncFromServerEvent

--[[
	서버로부터 받은 VBP 초기화 데이터를 처리합니다.
	VbpId를 기반으로 로컬 ValueByPriority 인스턴스를 찾거나 생성하고,
	수신된 데이터로 초기 상태를 설정합니다.
]]
local function findVbpAndApplyInitialInfoFromReader(reader: BufferReader.BufferReader)
	local vbpIdLength = reader:ReadU16()
	local vbpId = reader:ReadString(vbpIdLength)

	local vbp = ValueByPriority.FindById(vbpId)
	local isFailedToFind = vbp == nil

	if isFailedToFind then
		warn(`Received inital info for a non-existent ValueByPriority with Id "{vbpId}" on client.`)
		vbp = ValueByPriority.new({})
	end

	ValueByPrioritySerializer.ApplyInitialInfo(reader, vbp, {
		ExcludesTypeId = false,
	})

	if isFailedToFind then
		vbp:Destroy()
	end
end

local function onApplyInitialVbpEvent(buf)
	local reader = BufferReader.fromBuffer(buf)
	local infoCount = reader:ReadU16()

	for i = 1, infoCount do
		findVbpAndApplyInitialInfoFromReader(reader)
	end
end

ApplyInitialVbpEvent.OnClientEvent:Connect(onApplyInitialVbpEvent)

local function findVbpAndApplyChangeFromReaderWithChangeType(
	reader: BufferReader.BufferReader,
	changeType: string,
	serializedTime: number
)
	local vbpIdLength = reader:ReadU16()
	local vbpId = reader:ReadString(vbpIdLength)

	local vbp = ValueByPriority.FindById(vbpId)

	local params = {
		ExcludesTypeId = false,
		SerializedTime = serializedTime,
	}

	if vbp and not vbp.IsDestroyed then
		ValueByPrioritySerializer.ApplyVbpChangeInfo(reader, vbp, params)
	elseif vbp and vbp.IsDestroyed then
		warn(`Received {changeType} changes for a destroyed ValueByPriority "{vbp}" on client. \z
			Changes were applied by serializer.`)
		ValueByPrioritySerializer.ApplyVbpChangeInfo(reader, vbp, params)
	else
		warn(
			`Received {changeType} changes for a non-existent ValueByPriority with Id "{vbpId}" on client. \z
			Skipping this Vbp's changes.`
		)
		local tempVbpForSkipping = ValueByPriority.new({})
		ValueByPrioritySerializer.ApplyVbpChangeInfo(reader, tempVbpForSkipping, params)
		tempVbpForSkipping:Destroy()
	end
end

local function onReceiveReliableChanges(buf: buffer)
	local reader = BufferReader.fromBuffer(buf)
	local vbpCount = reader:ReadU16() -- 변경된 VBP 개수
	local serializedTime = reader:ReadF64()

	for _ = 1, vbpCount do
		findVbpAndApplyChangeFromReaderWithChangeType(reader, "reliable", serializedTime)
	end
end

SyncFromServerEvent.OnClientEvent:Connect(onReceiveReliableChanges)

local function onReceiveUnreliableChanges(buf: buffer)
	local reader = BufferReader.fromBuffer(buf)
	local vbpCount = reader:ReadU16()
	local serializedTime = reader:ReadF64()

	for i = 1, vbpCount do
		findVbpAndApplyChangeFromReaderWithChangeType(reader, "unreliable", serializedTime)
	end
end

UnreliableSyncFromServerEvent.OnClientEvent:Connect(onReceiveUnreliableChanges)
