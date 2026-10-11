-- WoWAI: talk to local coding agents (Claude Code, Codex, Grok) from inside WoW,
-- without reloading.
--
-- The WoW sandbox has no network and no file reads at runtime. Two doors remain open:
--
--   OUT ("pixel" mode): pending messages are drawn as a strip of colored squares in
--        a thin bottom-edge signal until the companion acknowledges them.
--        bridge.js screen-captures that signal and decodes it. Nothing touches the game.
--   IN:  load-on-demand addons read their files from disk at the moment they load.
--        The bridge writes the latest replies for every chat into a pool of pre-made
--        slot addons (WoWAI_S001..S200); we load a fresh slot from a timer.
--        Each slot is single-use per session; a /reload frees them all.
--   Fallback ("reload" mode): SavedVariables + Inbox.lua, a ReloadUI() per step.
--
-- Chats: each chat is its own agent session (like a separate terminal) with its own
-- folder, agent, history and pending message. The bridge runs them in parallel.
-- Everything here is plain addon API. No automation, no memory reading.

local ADDON_NAME = ...
local WoWAI = {}
_G.WoWAI = WoWAI
local Codec = WoWAI_Codec

local DEFAULT_CWD = "" -- empty = the bridge's configured defaultCwd
local MAX_HISTORY = 200
local MAX_CHATS = 16

local SLOT_COUNT = 200
local SLOT_PREFIX = "WoWAI_S"
local ACT_MAX = 60 -- heartbeat files per message (act/NNN/01..60.wav)
local PRESENCE_MAX = 2000 -- presence/0001..2000.wav, one flipped by the bridge every 30 s
local STRIP_TRIES = 3 -- re-show an unacknowledged message this many times before falling back
local CELL, CELLS_PER_ROW, MAX_ROWS = 1, 512, 1
local STRIP_SECONDS = 40 -- max per message; it leaves the strip as soon as the bridge acknowledges
local POLL_SCHEDULE = { 5, 10, 16, 24, 34, 46, 60, 80, 100, 130, 160, 200, 240, 300 }
local POLL_TAIL = 60
local TICK_SECONDS = 2
local CONNECT_WAIT = 15 -- seconds the Connect button waits for the bridge before giving up
local IDLE_POLL_SECONDS = 600 -- without the sound channel, spend one slot this often while idle to check the bridge
local RS, US = "\30", "\31" -- record / unit separators in the strip payload

local db
local ui = {}
-- Transport state for this UI session. outbound[id] = { chat, cwd, flags, text, sentAt, acked }
local run = { outbound = {} }

-- Shared window backdrop. Declared up here because ShowCopy (rendering section)
-- uses it too: a later `local` would be invisible there and resolve to a nil global.
local BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 24,
	insets = { left = 6, right = 6, top = 6, bottom = 6 },
}

-- The assistant bubble is labelled with the agent that wrote it (see AgentName).
local ROLE_STYLE = {
	user      = { label = "You",    color = { 0.82, 0.76, 0.62 }, bg = { 0.45, 0.34, 0.18, 0.12 } },
	assistant = { label = "Guide", color = { 1.00, 0.82, 0.25 }, bg = { 0.65, 0.46, 0.16, 0.12 } },
	system    = { label = "Notice", color = { 0.67, 0.62, 0.52 }, bg = { 0.40, 0.34, 0.24, 0.10 } },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ToHex(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- Record fields use control characters as separators, so keep them out of the wire format.
local function Wire(s)
	local value = tostring(s or "")
	return (value:gsub("[\30\31]", " "))
end

-- EditBoxes do not render UI escape sequences, so just make pipes harmless.
local function Display(s)
    local text = WoWAI.PlainText and WoWAI.PlainText(s) or tostring(s or ""):gsub("|H[^|]+|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]+:", ""):gsub("|r", ""):gsub("|A.-|a", ""):gsub("|T.-|t", "")
    return text
end

local function Trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function FmtDur(sec)
	sec = math.floor(sec or 0)
	if sec < 60 then return sec .. "s" end
	if sec < 3600 then return math.floor(sec / 60) .. "m" .. string.format("%02d", sec % 60) .. "s" end
	return math.floor(sec / 3600) .. "h" .. string.format("%02d", math.floor(sec / 60) % 60) .. "m"
end

-- Last path component of a folder, for labels.
local function FolderName(cwd)
	local name = tostring(cwd or ""):gsub("[\\/]+$", ""):match("([^\\/]+)$")
	return name or ""
end

-- The folder a chat works in: its own, or the bridge's default (the folder the
-- bridge was started from), which the bridge reports in every slot file.
local function ChatFolder(c)
	if c and c.cwd ~= "" then return c.cwd end
	return run.bridgeCwd or ""
end

-- Agents are named by id as the bridge knows them ("claude", "codex", "grok");
-- the bridge lists the ones it has, and its default, in every slot file. A chat
-- with no agent of its own runs on the bridge's default.
local AGENT_NAMES = { claude = "Claude", codex = "Codex", grok = "Grok", agy = "Antigravity", hermes = "Hermes" }

local function AgentName(id)
	id = tostring(id or "")
	if id == "" then return "AI" end
	return AGENT_NAMES[id] or (id:sub(1, 1):upper() .. id:sub(2))
end

local function ChatAgent(c)
	if c and c.agent and c.agent ~= "" then return c.agent end
	return run.bridgeAgent or ""
end

local function ChatAgentName(c)
	return AgentName(ChatAgent(c))
end

-- The name to show on a reply: the agent the bridge says wrote it, else the chat's.
local function ReplyAgentName(c, agent)
	return "Guide"
end

local function Contains(list, v)
	for _, x in ipairs(list or {}) do
		if x == v then return true end
	end
	return false
end

-- First few words of a message, as a chat title.
local function AutoTitle(text)
	local words = {}
	for w in tostring(text or ""):gmatch("%S+") do
		w = w:gsub("^[%p]+", ""):gsub("[%p]+$", "")
		if w ~= "" then
			table.insert(words, w)
			if #words >= 5 then break end
		end
	end
	local title = table.concat(words, " ")
	if #title > 24 then title = title:sub(1, 24):gsub("%s+%S*$", "") end
	if title == "" then return nil end
	return title:sub(1, 1):upper() .. title:sub(2)
end

local function NewId()
	return string.format("%x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF))
end

local function FindChat(id)
	for i, c in ipairs(db.chats) do
		if c.id == id then return c, i end
	end
end

local function ActiveChat()
	return FindChat(db.activeChat)
end

local function AddChat(name, cwd)
	if #db.chats >= MAX_CHATS then return nil end
	local current = ActiveChat()
	local c = {
		id = NewId(),
		name = name or ("Chat " .. (#db.chats + 1)),
		cwd = cwd or (current and current.cwd) or DEFAULT_CWD,
		agent = (current and current.agent) or "",
		history = {},
		unread = 0,
		created = time(),
	}
	table.insert(db.chats, c)
	return c
end

local function AnyPending()
	for _, c in ipairs(db.chats) do
		if c.pendingId then return true end
	end
	return false
end

local function InitDB()
	WoWAIDB = WoWAIDB or {}
	db = WoWAIDB
	db.settings = db.settings or {}
	local s = db.settings
	if s.autoRefresh == nil then s.autoRefresh = true end
	if s.signal == nil then s.signal = true end
	if s.context == nil then s.context = true end -- tell the agent about the character, zone, etc.
	-- How much of each reply to print in the game chat. "summary" (the agent's
	-- closing TL;DR lines) replaced "full" as the default; an install that still
	-- has the old default saved moves over once, any other choice is kept.
	if not s.echoV2 then
		s.echoV2 = true
		if s.echo == "full" then s.echo = "summary" end
	end
	s.echo = s.echo or "summary"
	s.mode = s.mode or "pixel"
	s.interval = s.interval or 20
	s.cwd = s.cwd or DEFAULT_CWD
	if not s.sideChatV1 then
        if not s.width or s.width == 780 then s.width = 560 end
        s.sideChatV1 = true
    end
    s.width = s.width or 560
    s.height = s.height or 500
    s.model = s.model or "gpt-6.1-sol"
    s.effort = s.effort or "low"
	db.lastSeq = db.lastSeq or 0
	-- Chats deleted in game that the bridge hasn't confirmed forgetting yet.
	db.forget = db.forget or {}
	-- Identifies this counter's lifetime. If the saved data is ever reset, a new
	-- session lets the bridge tell "message #1 again" from "message #1, already done".
	if not db.session then
		db.session = string.format("%x%04x%04x", time() % 0xFFFFFF, math.random(0, 0xFFFF), math.random(0, 0xFFFF))
	end
	if not db.chats then
		-- Migrate the single-chat layout into the first chat.
		db.chats = {}
		local c = {
			id = NewId(),
			name = "Chat 1",
			cwd = s.cwd,
			history = db.history or {},
			pendingId = db.pendingId,
			unread = db.unread or 0,
			draft = db.draft,
			created = time(),
		}
		table.insert(db.chats, c)
		db.activeChat = c.id
		db.history, db.pendingId, db.unread, db.draft = nil, nil, nil, nil
	end
	if #db.chats == 0 then AddChat() end
	if not FindChat(db.activeChat) then db.activeChat = db.chats[1].id end
	-- Chats from before agents had names: replies were stored with role "claude".
	for _, c in ipairs(db.chats) do
		c.agent = c.agent or ""
		for _, m in ipairs(c.history or {}) do
			if m.role == "claude" then m.role, m.agent = "assistant", m.agent or "claude" end
		end
	end
end

local function AddHistory(chat, role, text, id, denied, agent, macros)
	table.insert(chat.history, { role = role, text = text, id = id, t = time(), denied = denied, agent = agent, macros = macros })
	while #chat.history > MAX_HISTORY do
		table.remove(chat.history, 1)
	end
end

local function SlotName(i)
	return string.format("%s%03d", SLOT_PREFIX, i)
end

local function SlotNumber(id)
	return ((id - 1) % SLOT_COUNT) + 1
end

---------------------------------------------------------------------------
-- Reload plumbing (fallback path)
---------------------------------------------------------------------------

local function SafeReload()
	if InCombatLockdown() then
		WoWAI.reloadAfterCombat = true
		if ui.status then
			ui.status:SetText("In combat - will reload as soon as it ends")
		end
		return
	end
	ReloadUI()
end

-- ReloadUI() only works from a hardware event (a keypress or click), never from
-- a timer. So the automatic reload piggybacks on the player's own next keypress
-- once the interval has elapsed. The key still reaches the game normally.
local keyCatcher = CreateFrame("Frame", "WoWAIKeyCatcher", UIParent)
keyCatcher:Hide()
keyCatcher:EnableKeyboard(true)
keyCatcher:SetScript("OnKeyDown", function(self, key)
	if db and AnyPending() and db.settings.autoRefresh
		and GetTime() >= (WoWAI.nextAutoRefresh or 0)
		and not InCombatLockdown() then
		self:Hide()
		ReloadUI()
	end
end)

-- Arm the keypress reload. In pixel mode this is only used once the slot pool
-- is exhausted (a reload frees every slot) or the slots are not installed.
function WoWAI.ArmAutoRefresh()
	keyCatcher:Hide()
	if not AnyPending() or not db.settings.autoRefresh then return end
	if db.settings.mode == "pixel" and not (run.slotsExhausted or run.slotsMissing or run.pixelFailed) then return end
	-- Propagation can't be changed in combat. Never show the catcher without it,
	-- or it would eat every keypress. PLAYER_REGEN_ENABLED re-arms after combat.
	if not keyCatcher.propagates then
		if InCombatLockdown() or not keyCatcher.SetPropagateKeyboardInput then return end
		keyCatcher:SetPropagateKeyboardInput(true)
		keyCatcher.propagates = true
	end
	WoWAI.nextAutoRefresh = GetTime() + db.settings.interval
	keyCatcher:Show()
end

---------------------------------------------------------------------------
-- Pixel strip (out)
---------------------------------------------------------------------------

local strip
local cellPool = {}

local function EnsureStrip()
	if strip then return strip end
	strip = CreateFrame("Frame", "WoWAIStrip", UIParent)
	strip:SetFrameStrata("TOOLTIP")
	strip:SetFrameLevel(10000)
	-- Scale so that one UI unit is exactly one physical pixel (see Blizzard's PixelUtil).
	local physH = 1080
	if GetPhysicalScreenSize then
		local _, h = GetPhysicalScreenSize()
		physH = h or physH
	end
	if strip.SetIgnoreParentScale then strip:SetIgnoreParentScale(true) end
	strip:SetScale(768 / physH)
	strip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
	strip:SetSize(CELLS_PER_ROW * CELL, MAX_ROWS * CELL)
	strip:Hide()
	return strip
end

local function HideStrip()
	if strip then strip:Hide() end
    run.stripShown = nil
    run.pixelQueued=nil
end

local function DrawStrip(id, payload)
	local cells = Codec.Encode(id % 65536, payload)
	local s = EnsureStrip()
	local rows = math.ceil(#cells / CELLS_PER_ROW)
	local total = #cells
	for i = 1, total do
		local t = cellPool[i]
		if not t then
			t = s:CreateTexture(nil, "OVERLAY")
			t:SetSize(CELL, CELL)
			local c = (i - 1) % CELLS_PER_ROW
			local r = math.floor((i - 1) / CELLS_PER_ROW)
			t:SetPoint("TOPLEFT", s, "TOPLEFT", c * CELL, -r * CELL)
			cellPool[i] = t
		end
		local cr, cg, cb = Codec.CellColor(cells[i] or 0)
		t:SetColorTexture(cr, cg, cb, 1)
		t:Show()
	end
	for i = total + 1, #cellPool do
		cellPool[i]:Hide()
	end
	s:Show()
	run.stripShown = true
end

-- Fragment long user messages while keeping the on-screen signal to one row.
local function ShowStrip(id,payload)
    if run.pixelPayload~=payload or run.pixelId~=id then
        if run.stripShown and db.settings.copilotEnabled~=false and run.pixelParts and #run.pixelParts>1 and run.pixelPart<#run.pixelParts then run.pixelQueued={id,payload};return end
        run.pixelQueued=nil
        run.pixelPayload,run.pixelId=payload,id
        run.pixelFrame=(run.pixelFrame or 0)+1
        run.pixelNonce=run.pixelNonce or string.format("%x%04x",time(),math.random(0,65535))
        run.pixelParts={};run.pixelPart=0
        local at=1
        repeat
            local last=math.min(at+639,#payload)
            while last<#payload and payload:byte(last+1)>=128 and payload:byte(last+1)<192 do last=last-1 end
            run.pixelParts[#run.pixelParts+1]=payload:sub(at,last);at=last+1
        until at>#payload
    end
    run.pixelPart=run.pixelPart%#run.pixelParts+1
    local part=run.pixelPart
    DrawStrip(id,"__WIRE2__"..run.pixelNonce.."-"..run.pixelFrame..":"..id..":"..part..":"..#run.pixelParts..":"..run.pixelParts[part])
end
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(.2,function()
    if run.stripShown and run.pixelPayload then
        if run.pixelQueued and run.pixelPart==#run.pixelParts then local queued=run.pixelQueued;run.pixelQueued=nil;ShowStrip(queued[1],queued[2])
        else ShowStrip(run.pixelId,run.pixelPayload) end
    end
end) end

-- Record: session, chat, id, cwd, flags, name, [context,] text. Several records
-- per frame. The context field is only present when the flags carry "c", so the
-- bridge can tell it from a separator inside the text.
local function RecordFor(id, rec)
	local flags = Wire(rec.flags)
	local fields = { Wire(db.session), Wire(rec.chat), tostring(id), Wire(rec.cwd), flags, Wire(rec.name) }
	if rec.ctx ~= nil then
		fields[5] = flags == "" and "c" or (flags .. ";c")
		table.insert(fields, Wire(rec.ctx))
	end
	table.insert(fields, Wire(rec.text))
	return table.concat(fields, US)
end

-- Redraw the strip from every outbound message the bridge hasn't acknowledged.
local function RefreshStrip()
	local ids = {}
	for id, rec in pairs(run.outbound) do
		if not rec.acked then table.insert(ids, id) end
	end
	if #ids == 0 then
		HideStrip()
		return
	end
	table.sort(ids)
	-- Newest first; drop the oldest if the frame would overflow.
	local parts, size, latest = {}, 0, ids[#ids]
	for i = #ids, 1, -1 do
		local r = RecordFor(ids[i], run.outbound[ids[i]])
		if size + #r + 1 > Codec.MAX_PAYLOAD then break end
		table.insert(parts, 1, r)
		size = size + #r + 1
	end
	ShowStrip(latest, table.concat(parts, RS))
end

---------------------------------------------------------------------------
-- Signals and slots (in)
---------------------------------------------------------------------------

-- Optional cheap poll: an empty .wav won't play, a valid one will. The bridge
-- fills sig/NNN.wav when reply NNN is ready. Self-disables if it misbehaves.
local signalAvailable = type(PlaySoundFile) == "function"
local signalStats = { checks = 0, hits = 0, lastHit = nil }

local function SoundValid(path)
	if not signalAvailable or not db.settings.signal then return false end
	signalStats.checks = signalStats.checks + 1
	local ok, willPlay, handle = pcall(PlaySoundFile, path, "Master")
	if not ok then
		signalAvailable = false
		signalStats.error = tostring(willPlay)
		return false
	end
	if willPlay and handle then pcall(StopSound, handle) end
	if willPlay then
		signalStats.hits = signalStats.hits + 1
		signalStats.lastHit = GetTime()
	end
	return willPlay and true or false
end

local function CheckSignal(kind, id)
	if run.signalUnreliable then return false end
	return SoundValid(string.format("Interface\\AddOns\\WoWAI\\%s\\%03d.wav", kind, SlotNumber(id)))
end

-- Heartbeat: the bridge flips act/NNN/kk.wav for the k-th action of message NNN.
local function ActPath(id, k)
	return string.format("Interface\\AddOns\\WoWAI\\act\\%03d\\%02d.wav", SlotNumber(id), k)
end

local function StartActivity(chat, id)
	local a = { next = 1, count = 0, startedAt = GetTime() }
	-- The bridge can't have written anything yet, so a valid first file means the
	-- client cached this slot number's files from an earlier use: don't trust them.
	if SoundValid(ActPath(id, 1)) then a.unreliable = true end
	run.act = run.act or {}
	run.act[chat.id] = a
end

-- Returns true if the counter moved.
local function PollActivity(chat)
	local a = run.act and run.act[chat.id]
	if not a or a.unreliable or not chat.pendingId then return false end
	local moved = false
	for _ = 1, 3 do
		if a.next > ACT_MAX then break end
		if not SoundValid(ActPath(chat.pendingId, a.next)) then break end
		a.count = a.count + 1
		a.next = a.next + 1
		a.last = GetTime()
		moved = true
	end
	return moved
end

-- Bridge presence. Evidence the bridge is alive comes from several places:
-- presence beats, acks, slot data (which carries the bridge's clock), replies.
local function NotedBridge(at)
	at = at or GetTime()
	if not run.bridgeSeen or at > run.bridgeSeen then run.bridgeSeen = at end
	run.pixelFailed = nil
end

local function PresencePath(k)
	return string.format("Interface\\AddOns\\WoWAI\\presence\\%04d.wav", k)
end

-- Valid presence files form a prefix 1..k, so a binary search finds the head.
local function FindPresenceHead()
	local lo, hi = 0, PRESENCE_MAX
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if SoundValid(PresencePath(mid)) then lo = mid else hi = mid - 1 end
	end
	return lo
end

local function PollPresence()
	if not signalAvailable or not db.settings.signal then return end
	run.presence = run.presence or { last = FindPresenceHead() }
	local p = run.presence
	for _ = 1, 3 do
		local k = (p.last % PRESENCE_MAX) + 1
		if not SoundValid(PresencePath(k)) then break end
		p.last = k
		p.beats = (p.beats or 0) + 1
		NotedBridge()
	end
end

-- Whether the 30-second presence beats can reach us at all. When they can't
-- (self-test failed, or signal checks turned off), the only evidence of the
-- bridge is a slot read: the idle poll below and the replies themselves.
local function PresenceWorks()
	return signalAvailable and db ~= nil and db.settings.signal
end

-- Returns state ("ok" | "stale" | "down" | "unknown"), a color and a description.
-- With presence beats the bridge is heard from every 30 s, so 90 s of silence is
-- suspicious. Without them the addon only hears from it every IDLE_POLL_SECONDS,
-- so the windows have to be wider or the light could never stay green between
-- messages and every reply would be followed by a Reconnect.
function WoWAI.BridgeState()
	local seen = run.bridgeSeen
	if not seen then
		return "unknown", 0.6, 0.6, 0.6, "Bridge: not seen yet this session"
	end
	local age = GetTime() - seen
	local okFor, staleFor = 90, 300
	if not PresenceWorks() then
		okFor, staleFor = IDLE_POLL_SECONDS + 120, IDLE_POLL_SECONDS * 2 + 120
	end
	if age < okFor then
		return "ok", 0.2, 0.9, 0.3, "Bridge: connected (seen " .. FmtDur(age) .. " ago)"
	elseif age < staleFor then
		return "stale", 0.95, 0.8, 0.2, "Bridge: last seen " .. FmtDur(age) .. " ago"
	end
	return "down", 0.9, 0.25, 0.25, "Bridge: not seen for " .. FmtDur(age) .. " - is the bridge running?"
end

-- Same icons the friends list uses for online / away / busy / offline.
local STATE_ICON = {
	ok = "Interface\\FriendsFrame\\StatusIcon-Online",
	stale = "Interface\\FriendsFrame\\StatusIcon-Away",
	down = "Interface\\FriendsFrame\\StatusIcon-DnD",
	unknown = "Interface\\FriendsFrame\\StatusIcon-Offline",
}

function WoWAI.UpdateDot()
	local state, _, _, _, tip = WoWAI.BridgeState()
	if run.pixelFailed then state = "down" end
	if not signalAvailable and signalStats.selftest then
		tip = tip .. "\n(sound-file channel unavailable: " .. signalStats.selftest .. "; using slot checks only)"
	end
	for _, dot in ipairs({ ui.dot, ui.miniDot }) do
		if dot then
			dot:SetTexture(STATE_ICON[state] or STATE_ICON.unknown)
			dot.tip = tip
		end
	end
end

-- Connected = the bridge has been seen recently. In pixel mode, sending needs this;
-- until then the Connect button takes the Send button's place. The reload
-- transport has no idea whether the bridge is there, so it never gates.
function WoWAI.IsConnected()
	if not db or db.settings.mode ~= "pixel" then return true end
	return WoWAI.BridgeState() == "ok" and not run.pixelFailed
end

-- Connect button: say hello to the bridge (it acks, refreshes the slots and
-- offers a restore), ignoring SayHello's throttle so a click always does something.
function WoWAI.Connect()
	if db.settings.mode ~= "pixel" then
		SafeReload()
		return
	end
	run.lastHelloAt = nil
	run.pixelFailed = nil
	run.connectFailed = nil
	run.connectingAt = GetTime()
	WoWAI.SayHello()
end

-- One word for the connection state, so Tick can tell when it changed.
local function ConnectionKey()
	if WoWAI.IsConnected() then return "ok" end
	if run.connectingAt then return "connecting" end
	if run.connectFailed then return "failed" end
	return WoWAI.BridgeState()
end

-- Called every tick: time out a Connect attempt, and redraw when the state flips
-- (light, button, status line, placeholder) without redrawing every tick.
function WoWAI.CheckConnection()
	if run.connectingAt then
		if WoWAI.IsConnected() then
			run.connectingAt, run.connectFailed = nil, nil
			-- A message typed while disconnected goes out now, without a second click,
			-- as long as the same chat is still in front and free.
			local queued = run.sendOnConnect
			run.sendOnConnect = nil
			local c = queued and ActiveChat()
			if c and c.id == queued.chat and not c.pendingId then
				if ui.input and Trim(ui.input:GetText() or "") == queued.text then ui.input:SetText("") end
				WoWAI.Send(queued.text, queued.allow)
			end
		elseif GetTime() - run.connectingAt > CONNECT_WAIT then
			run.connectingAt, run.connectFailed = nil, true
			run.sendOnConnect = nil -- the text is still in the box
		end
	elseif run.connectFailed and WoWAI.IsConnected() then
		run.connectFailed = nil
	end
	local key = ConnectionKey()
	if key ~= run.connKey then
		run.connKey = key
		WoWAI.Render()
	end
end

-- Swap Send and Connect depending on the state; part of UpdateStatus.
function WoWAI.UpdateConnect()
	if not ui.connect or not ui.send then return end
	local connected = WoWAI.IsConnected()
	ui.send:SetShown(connected)
	ui.connect:SetShown(not connected)
	if connected then return end
	if run.connectingAt then
		ui.connect:SetText("Connecting...")
		ui.connect:Disable()
	else
		ui.connect:SetText(WoWAI.BridgeState() == "stale" and "Reconnect" or "Connect")
		ui.connect:Enable()
	end
end

-- Prove the sound-file trick actually distinguishes empty from valid files on this
-- client before trusting it for presence, heartbeats and readiness signals.
local function SelfTestSignals()
	if not signalAvailable then
		signalStats.selftest = "PlaySoundFile missing"
		return
	end
	local emptyLooksValid = SoundValid("Interface\\AddOns\\WoWAI\\ctl\\empty.wav")
	local validLooksValid = SoundValid("Interface\\AddOns\\WoWAI\\ctl\\valid.wav")
	if emptyLooksValid then
		signalAvailable = false
		signalStats.selftest = "an empty file reports as playable"
	elseif not validLooksValid then
		signalAvailable = false
		signalStats.selftest = "a valid file reports as unplayable (files not indexed? restart WoW)"
	else
		signalStats.selftest = "passed"
	end
end

local function ActivityLine(chat)
	local a = run.act and run.act[chat.id]
	local now = GetTime()
	local started = (a and a.startedAt) or run.sentAt or now
	local s = "running " .. FmtDur(now - started)
	if a and not a.unreliable then
		s = s .. " - " .. a.count .. (a.count == 1 and " action" or " actions")
		if a.last then
			local quiet = now - a.last
			s = s .. ", last " .. FmtDur(quiet) .. " ago"
			if quiet > 120 then s = s .. " (quiet for a while - stuck? /wow-ai cancel)" end
		elseif now - started > 60 then
			s = s .. ", no activity seen yet"
		end
	end
	return s
end

local function FreeSlot()
	for i = 1, SLOT_COUNT do
		local name = SlotName(i)
		if not C_AddOns.IsAddOnLoaded(name) then
			return name
		end
	end
end

local function ScheduleNextPoll()
	local idx = (run.polls or 0) + 1
	local t = POLL_SCHEDULE[idx]
	if not t then
		t = POLL_SCHEDULE[#POLL_SCHEDULE] + POLL_TAIL * (idx - #POLL_SCHEDULE)
	end
	run.nextPollAt = (run.sentAt or GetTime()) + t
end

local Finish -- defined below

-- The bridge has read this record: whatever game context rode on it is now
-- what the bridge knows, so later messages only carry it again if it changes.
local function NoteAcked(rec)
	rec.acked = true
	if rec.ctx ~= nil then run.contextSent = rec.ctx end
end

local function MarkAcked(id)
	local rec = run.outbound[id]
	if rec and not rec.acked then
		NoteAcked(rec)
		RefreshStrip()
	end
	NotedBridge()
end

-- Dispatch a list of reply records to the chats waiting for them.
local function ApplyReplies(replies)
	local matched = false
	for _, r in ipairs(replies or {}) do
		local c = FindChat(r.chat)
		if c and c.pendingId and r.id == c.pendingId then
			matched = true
			MarkAcked(r.id)
			local denied = type(r.denied) == "table" and #r.denied > 0 and r.denied or nil
			if r.status == "done" then
				Finish(c, "assistant", r.text or "", denied, r.agent, r.summary, WoWAI.CleanMacros(r.macros))
			elseif r.status == "error" then
				Finish(c, "system", "Bridge error: " .. tostring(r.text), denied)
			elseif r.status == "working" then
				c.progress = r.text
			end
		end
	end
	return matched
end

-- The bridge keeps every chat's transcript. After the client wipes our saved data,
-- it sends them back once, addressed to our new session token.
local function ImportRestore(r)
	if type(r) ~= "table" or r.token ~= db.session or db.restored then return end
	db.restored = true
	local added = 0
	local current = ActiveChat()
	for _, rc in ipairs(r.chats or {}) do
		-- Skip chats deleted here that the bridge hasn't been told about yet.
		if type(rc) == "table" and rc.id and not FindChat(rc.id) and not db.forget[rc.id] and #db.chats < MAX_CHATS then
			local chat = {
				id = rc.id,
				name = (rc.name and rc.name ~= "") and rc.name or ("Chat " .. (#db.chats + 1)),
				cwd = rc.cwd or DEFAULT_CWD,
				agent = "",
				history = {},
				unread = 0,
				created = time(),
			}
			for _, m in ipairs(rc.messages or {}) do
				local role, agent = m.role, m.agent
				if role == "claude" then role, agent = "assistant", agent or "claude" end -- an older bridge's transcript
				if agent == "" then agent = nil end
				table.insert(chat.history, { role = role, text = m.text, id = m.id, t = m.t, agent = agent, references = m.references })
			end
			-- Keep the chat we're currently using last so it stays where it was.
			table.insert(db.chats, math.max(1, #db.chats), chat)
			added = added + 1
		end
	end
	run.restoring = nil
	if added > 0 then
		if current and #current.history <= 2 then
			for _, ch in ipairs(db.chats) do
				if ch ~= current and ch.name == current.name then current.name = "New chat" end
			end
		end
		AddHistory(current, "system", "Restored " .. added .. " chat(s) from the bridge after the game reset the saved data.")
		WoWAI.RenderChatList()
	end
end

local function TryLoadSlot(why)
	local name = FreeSlot()
	if not name then
		run.slotsExhausted = true
		WoWAI.ArmAutoRefresh()
		WoWAI.UpdateStatus()
		return
	end
	WoWAI_SlotData = nil
	local loaded, reason = C_AddOns.LoadAddOn(name)
	if not loaded then
		run.slotError = reason
		if reason == "MISSING" or reason == "DISABLED" then
			run.slotsMissing = true
			WoWAI.ArmAutoRefresh()
		end
		WoWAI.UpdateStatus()
		return
	end
	run.polls = (run.polls or 0) + 1
	ScheduleNextPoll()
	local data = WoWAI_SlotData
	if type(data) == "table" and type(data.now) == "number" then
		-- The bridge's clock and ours are the same machine; translate to GetTime().
		NotedBridge(GetTime() - (time() - data.now))
	end
	if type(data) == "table" and type(data.cwd) == "string" and data.cwd ~= "" then run.bridgeCwd = data.cwd end
	if type(data) == "table" then
		if type(data.agent) == "string" and data.agent ~= "" then run.bridgeAgent = data.agent end
		if type(data.agents) == "table" and #data.agents > 0 then run.bridgeAgents = data.agents end
	end
	local matched = ApplyReplies(type(data) == "table" and data.replies or nil)
	if type(data) == "table" and data.restore then ImportRestore(data.restore) end
	if type(data) == "table" and data.map and WoWAIMap then WoWAIMap.Sync(data.map) end
    if type(data) == "table" and data.refresh and WoWAI.ReceiveSnapshotRequest then WoWAI.ReceiveSnapshotRequest(data.refresh) end
    if type(data) == "table" and data.cards and WoWAI.ReceiveReferenceCards then WoWAI.ReceiveReferenceCards(data.cards) end
	if why == "signal" and not matched then
		run.signalUnreliable = true
	end
	WoWAI.Render()
end

local function Tick()
	if not db then return end
	local now = GetTime()
	PollPresence()
	-- Without presence beats, the only evidence is a slot read; spend one every
	-- IDLE_POLL_SECONDS while idle so the light still reflects reality (and stays
	-- green while the bridge is up: BridgeState allows for this interval).
	if not PresenceWorks() and db.settings.mode == "pixel" and not AnyPending()
		and now - (run.lastIdlePoll or -1e9) >= IDLE_POLL_SECONDS then
		run.lastIdlePoll = now
		TryLoadSlot("idle")
	end
	WoWAI.UpdateDot()
	WoWAI.CheckConnection()
	if db.settings.mode ~= "pixel" then return end
	local changed = false
	if run.helloPollAt and now >= run.helloPollAt then
		run.helloPollAt = nil
		TryLoadSlot("hello")
		-- Whatever that slot held, the wait is over.
		if run.restoring then
			run.restoring = nil
			WoWAI.Render()
		end
	end
	if run.restoring and now - run.restoring > 25 then
		run.restoring = nil
		WoWAI.Render()
	end
	for id, rec in pairs(run.outbound) do
		if rec.snapshot then rec.sentAt = now end
		if not rec.snapshot and not rec.acked and CheckSignal("ack", id) then
			NoteAcked(rec)
			changed = true
			NotedBridge()
		end
		-- A hello only needs the bridge to have been seen; it never escalates.
		-- A forget is the same, but the bridge must have been seen a moment after
		-- the record went up, so it had a chance to read it.
		if (rec.hello or rec.forget) and not rec.snapshot and not rec.acked and run.bridgeSeen and run.bridgeSeen >= rec.sentAt + (rec.forget and 2 or 0) then
			NoteAcked(rec)
			changed = true
		end
		if rec.acked then
			if rec.forget then db.forget[rec.forget] = nil end
			run.outbound[id] = nil
			changed = true
		elseif rec.hello and now - rec.sentAt >= 20 then
			run.outbound[id] = nil
			changed = true
		elseif now - rec.sentAt >= STRIP_SECONDS then
			rec.tries = (rec.tries or 1) + 1
			if rec.tries <= STRIP_TRIES then
				-- Nobody picked it up: show it again.
				rec.sentAt = now
				changed = true
			elseif rec.forget then
				-- The bridge is away; db.forget keeps it for the next hello.
				run.outbound[id] = nil
				changed = true
			else
				-- Give up on pixels for this message; the reload path still has it.
				run.outbound[id] = nil
				run.pixelFailed = true
				changed = true
				WoWAI.ArmAutoRefresh()
			end
		end
	end
	if changed then
		RefreshStrip()
		WoWAI.UpdateStatus()
	end
	if not AnyPending() then return end
	local moved = false
	for _, c in ipairs(db.chats) do
		if c.pendingId and PollActivity(c) then moved = true end
	end
	if moved then WoWAI.Render() end
	for _, c in ipairs(db.chats) do
		if c.pendingId and CheckSignal("sig", c.pendingId) then
			TryLoadSlot("signal")
			return
		end
	end
	if run.nextPollAt and now >= run.nextPollAt then
		TryLoadSlot("schedule")
	end
end

-- Pull whatever bridge.js last wrote into Inbox.lua (the reload path).
function WoWAI.LoadContextSlot() TryLoadSlot("context") end
local function ProcessInbox()
	local inbox = WoWAI_Inbox
	if type(inbox) ~= "table" then return end
	if type(inbox.cwd) == "string" and inbox.cwd ~= "" then run.bridgeCwd = inbox.cwd end
	if type(inbox.agent) == "string" and inbox.agent ~= "" then run.bridgeAgent = inbox.agent end
	if type(inbox.agents) == "table" and #inbox.agents > 0 then run.bridgeAgents = inbox.agents end
	ApplyReplies(inbox.replies)
	if inbox.restore then ImportRestore(inbox.restore) end
	if inbox.map and WoWAIMap then WoWAIMap.Sync(inbox.map) end
    if inbox.refresh and WoWAI.ReceiveSnapshotRequest then WoWAI.ReceiveSnapshotRequest(inbox.refresh) end
    if inbox.cards and WoWAI.ReceiveReferenceCards then WoWAI.ReceiveReferenceCards(inbox.cards) end
end

Finish = function(chat, role, text, denied, agent, summary, macros)
	AddHistory(chat, role, text, chat.pendingId, denied, agent, macros)
	chat.pendingId = nil
	chat.progress = nil
	if run.act then run.act[chat.id] = nil end
	NotedBridge()
	local visible = ui.frame and ui.frame:IsShown() and db.activeChat == chat.id
	if not visible then
		chat.unread = (chat.unread or 0) + 1
	end
	if not AnyPending() then
		keyCatcher:Hide()
	end
	if visible and ui.input and chat.draft and chat.draft ~= "" then
		ui.input:SetText(chat.draft)
		chat.draft = nil
	end
	WoWAI.Render()
	WoWAI.Notify(chat, text, agent, summary)
end

---------------------------------------------------------------------------
-- Game context and links
---------------------------------------------------------------------------

-- The agent only sees text, so two things about the game are spelled out for it:
-- who is asking (the character, where they are; sent with the hello and again
-- when it changes, and put into the agent's system prompt by the bridge), and
-- what the player shift-clicked into the message (item, spell and quest links
-- are meaningless markup to the agent; their tooltips are what the player sees).
-- Every game API here is optional: whatever the client lacks is left out.

local CONTEXT_MAX = 900 -- bytes of context per record; the strip has ~3.2 KB for everything
local LINK_LINES_MAX = 30 -- tooltip lines kept per link
local LINK_BYTES_MAX = 900 -- bytes kept per link

-- Call a game API that may not exist or may throw, and get its returns or nothing.
local function Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d, e, f, g = pcall(fn, ...)
	if ok then return a, b, c, d, e, f, g end
end

local function Money(copper)
	copper = tonumber(copper) or 0
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then return g .. "g " .. s .. "s " .. c .. "c" end
	if s > 0 then return s .. "s " .. c .. "c" end
	return c .. "c"
end

-- A few lines about the game and the character, as the bridge will show them to the agent.
-- Profession and secondary skill lines by skill id (vanilla ids).
local PROFESSION_SKILL_IDS = {
	[164] = true, [165] = true, [171] = true, [182] = true, [186] = true, [197] = true, [202] = true,
	[333] = true, [393] = true, [129] = true, [185] = true, [356] = true,
}

-- The character's skill lines as { name, isHeader, rank, maxRank, skillID }.
-- Forever only has C_SkillInfo (one table per line); the classic globals
-- (multiple returns) are the fallback for other clients.
function WoWAI.SkillLines()
	local out = {}
	if C_SkillInfo and C_SkillInfo.GetNumSkillLines then
		local n = Try(C_SkillInfo.GetNumSkillLines)
		local seen = {}
		for i = 1, (type(n) == "number" and n or 0) do
			local sk = Try(C_SkillInfo.GetSkillLineInfo, i)
			-- Child lines (parentSkillLineID ~= 0) repeat their parent; Blizzard's
			-- skills frame skips them too.
			if type(sk) == "table" and type(sk.name) == "string" and (sk.parentSkillLineID or 0) == 0 then
				local key = sk.isHeader and ("h:" .. sk.name) or (sk.skillID or sk.name)
				if not seen[key] then
					seen[key] = true
					out[#out + 1] = { name = sk.name, isHeader = sk.isHeader, rank = sk.rank, maxRank = sk.maxRank, skillID = sk.skillID }
				end
			end
		end
		return out
	end
	local n = Try(GetNumSkillLines)
	for i = 1, (type(n) == "number" and n or 0) do
		local sname, isHeader, _, rank, _, _, maxRank = Try(GetSkillLineInfo, i)
		if type(sname) == "string" then
			out[#out + 1] = { name = sname, isHeader = isHeader and true or false, rank = rank, maxRank = maxRank }
		end
	end
	return out
end

function WoWAI.GameContext()
	local lines = {}
	local version, build, _, toc = Try(GetBuildInfo)
	toc = tonumber(toc)
	local game = "World of Warcraft"
	if toc and toc >= 16000 and toc < 20000 then game = "World of Warcraft: Forever" end
	local client = ""
	if version then
		client = " (client " .. tostring(version) .. (build and ("." .. tostring(build)) or "") .. (toc and (", interface " .. toc) or "") .. ")"
	end
	table.insert(lines, "Game: " .. game .. client)

	local name = Try(UnitName, "player")
	if name then
		local realm = Try(GetRealmName)
		local level = Try(UnitLevel, "player")
		local race = Try(UnitRace, "player")
		local class = Try(UnitClass, "player")
		local faction = Try(UnitFactionGroup, "player")
		local guild = Try(GetGuildInfo, "player")
		local who = "Character: " .. tostring(name) .. (realm and (" on " .. tostring(realm)) or "")
		local desc = {}
		if level then table.insert(desc, "level " .. tostring(level)) end
		if race then table.insert(desc, tostring(race)) end
		if class then table.insert(desc, tostring(class)) end
		if #desc > 0 then who = who .. ", " .. table.concat(desc, " ") end
		if faction then who = who .. " (" .. tostring(faction) .. ")" end
		if guild then who = who .. ", guild <" .. tostring(guild) .. ">" end
		table.insert(lines, who)
	end

	local zone = Try(GetZoneText)
	local sub = Try(GetSubZoneText)
	if zone and zone ~= "" then
		table.insert(lines, "Location: " .. zone .. ((sub and sub ~= "" and sub ~= zone) and (" - " .. sub) or ""))
	end

	-- Map coordinates, as the minimap shows them (0-100 across the current map;
	-- addons get no world x/y/z). Modern C_Map first, the vanilla call as fallback.
	local x, y, mapName
	local mapId = Try(C_Map and C_Map.GetBestMapForUnit, "player")
	if type(mapId) == "number" then
		local pos = Try(C_Map.GetPlayerMapPosition, mapId, "player")
		if type(pos) == "table" and type(pos.x) == "number" and type(pos.y) == "number" then x, y = pos.x, pos.y end
		local info = Try(C_Map.GetMapInfo, mapId)
		if type(info) == "table" and type(info.name) == "string" then mapName = info.name end
	end
	if not x then
		local px, py = Try(GetPlayerMapPosition, "player")
		if type(px) == "number" and type(py) == "number" then x, y = px, py end
	end
	if x and y and (x > 0 or y > 0) then
		local where = (mapName and mapName ~= zone) and (" on " .. mapName) or ""
		table.insert(lines, string.format("Position: %.1f, %.1f%s%s", x * 100, y * 100, where, mapId and (" (map " .. mapId .. ")") or ""))
	end

	local progress = {}
	local copper = Try(GetMoney)
	if copper then table.insert(progress, "Money: " .. Money(copper)) end
	local xp, xpMax = Try(UnitXP, "player"), Try(UnitXPMax, "player")
	if type(xp) == "number" and type(xpMax) == "number" and xpMax > 0 then
		table.insert(progress, "XP: " .. xp .. "/" .. xpMax)
	end
	if #progress > 0 then table.insert(lines, table.concat(progress, "; ")) end

	-- Classic-style talent tabs: name, icon, points spent.
	local tabs = Try(GetNumTalentTabs)
	if type(tabs) == "number" and tabs > 0 then
		local parts = {}
		for i = 1, tabs do
			local tname, _, points = Try(GetTalentTabInfo, i)
			if type(tname) == "string" and type(points) == "number" then
				table.insert(parts, tname .. " " .. points)
			end
		end
		if #parts > 0 then table.insert(lines, "Talents: " .. table.concat(parts, " / ")) end
	end

	-- Skill lines under the Professions and Secondary Skills headers.
	local header, parts = nil, {}
	local wanted = { [TRADE_SKILLS or "Professions"] = true, [SECONDARY_SKILLS or "Secondary Skills"] = true }
	for _, sk in ipairs(WoWAI.SkillLines()) do
		if sk.isHeader then
			header = sk.name
		elseif (header and wanted[header]) or PROFESSION_SKILL_IDS[sk.skillID] then
			table.insert(parts, sk.name .. (sk.rank and (" " .. tostring(sk.rank) .. (sk.maxRank and ("/" .. tostring(sk.maxRank)) or "")) or ""))
		end
	end
	if #parts > 0 then table.insert(lines, "Professions: " .. table.concat(parts, ", ")) end

	-- Quest log ids (what is accepted, and which are done), so route planning can
	-- skip pickups and turn-ins that no longer apply.
	local quests = {}
	local qn = Try(C_QuestLog and C_QuestLog.GetNumQuestLogEntries) or Try(GetNumQuestLogEntries)
	if type(qn) == "number" then
		for i = 1, math.min(qn, 40) do
			local id, header, complete
			local info = Try(C_QuestLog and C_QuestLog.GetInfo, i)
			if type(info) == "table" then
				id, header = info.questID, info.isHeader
				complete = Try(C_QuestLog.IsComplete, id)
			else
				local _, _, _, isHeader, _, isComplete, _, qid = Try(GetQuestLogTitle, i)
				id, header, complete = qid, isHeader, isComplete == 1 or isComplete == true
			end
			if not header and type(id) == "number" and id > 0 then
				table.insert(quests, tostring(id) .. (complete and "*" or ""))
			end
		end
	end
	if #quests > 0 then table.insert(lines, "Quest log (id, * = ready to turn in): " .. table.concat(quests, ",")) end

	local s = table.concat(lines, "\n"):gsub("[\30\31]", " ")
	if #s > CONTEXT_MAX then s = s:sub(1, CONTEXT_MAX) end
	return s
end

-- The context to put on the next record, or nil when the bridge already has
-- it (or it wouldn't fit next to this message; it goes with a later one).
-- "" when the setting is off, so the bridge drops what it had.
local function ContextToSend(room)
	local ctx = db.settings.context and WoWAI.GameContext() or ""
	if ctx == (run.contextSent or "") then return nil end
	if room and #ctx > room then return nil end
	return ctx
end

-- Read a link's tooltip off a hidden GameTooltip, one line per row.
local scanTip
local function TooltipLines(payload)
    if run.linkAttachments and run.linkAttachments[payload] and #run.linkAttachments[payload].lines > 0 then return run.linkAttachments[payload].lines end
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "WoWAIScanTip", UIParent, "GameTooltipTemplate")
	end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	scanTip:ClearLines()
	local lines = {}
	if pcall(scanTip.SetHyperlink, scanTip, payload) then
		for i = 1, math.min(scanTip:NumLines() or 0, LINK_LINES_MAX) do
			local left = _G["WoWAIScanTipTextLeft" .. i]
			local right = _G["WoWAIScanTipTextRight" .. i]
			local l = Trim(tostring((left and left:GetText()) or ""))
			local r = Trim(tostring((right and right:IsShown() and right:GetText()) or ""))
			if r ~= "" then l = l .. "  " .. r end
			if l ~= "" and not Display(l):lower():find("submit an issue",1,true) then table.insert(lines, l) end
		end
	end
	scanTip:Hide()
	return lines
end

-- What a link is, in words: "item 2140 (Uncommon)", "spell 1978", "quest 176".
local function DescribeLink(payload)
	local kind, id = payload:match("^(%a+):(%d+)")
	if not kind then return payload:match("^(%a+)") or "link" end
	local s = kind .. " " .. id
	if kind == "item" then
		local _, _, quality = Try((C_Item and C_Item.GetItemInfo) or GetItemInfo, payload)
		local desc = type(quality) == "number" and _G["ITEM_QUALITY" .. quality .. "_DESC"]
		if desc then s = s .. " (" .. desc .. ")" end
	end
	return s
end

-- Turn the links in a message into text the agent can use: each becomes [Name]
-- in place, and a block at the end lists what the tooltip says about it.
-- Returns the new text and the number of links found.
function WoWAI.ExpandLinks(text)
    for _, a in pairs(run.linkAttachments or {}) do
        local label="["..a.name.."]"
        if text:find(label,1,true) and not text:find(a.link,1,true) then text=text:gsub(label:gsub("(%W)","%%%1"),function() return a.link end) end
    end
    text = text:gsub("|cn[^:]+:", "")
	local links, seen = {}, {}
	local function Take(payload, name)
		if not seen[payload] then
			seen[payload] = true
			table.insert(links, { payload = payload, name = name })
		end
		return "[" .. name .. "]"
	end
	-- Coloured links first (|cAARRGGBB|H...|h[Name]|h|r), then bare ones.
	local out = text:gsub("|c%x%x%x%x%x%x%x%x|H([^|]+)|h%[([^%]]*)%]|h|r", Take)
	out = out:gsub("|H([^|]+)|h%[([^%]]*)%]|h", Take)
	if #links == 0 then return text, 0 end
	local blocks = {}
	for _, l in ipairs(links) do
		local head = "[" .. l.name .. "] " .. DescribeLink(l.payload)
        if l.payload:match("^item:%d+:") then head = head .. " {link=" .. l.payload .. "}" end
		local body = Display(table.concat(TooltipLines(l.payload), "\n  "))
		local block = body ~= "" and (head .. "\n  " .. body) or head
		if #block > LINK_BYTES_MAX then block = block:sub(1, LINK_BYTES_MAX) .. "..." end
		table.insert(blocks, block)
	end
	return out .. "\n\n--- Linked from the game ---\n" .. table.concat(blocks, "\n"), #links
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- allow: optional list of permission rules to grant before this message runs.
function WoWAI.Send(text, allow)
	local c = ActiveChat()
	if not c then return end
	if db.settings.copilotEnabled == false then
		AddHistory(c, "system", "The guide is closed. Type /ai to bring back the journal tab.")
		WoWAI.Render()
		return
	end
	text = Trim(text or "")
	if c.pendingId then
		-- Typing while waiting: keep the draft, and check for the reply.
		if text ~= "" then c.draft = text end
		if db.settings.mode == "pixel" and not (run.slotsExhausted or run.slotsMissing) then
			TryLoadSlot("manual")
		else
			SafeReload()
		end
		return
	end
	if text == "" then return end
	if not WoWAI.IsConnected() then
		-- Not connected: the message stays in the box and we try to connect;
		-- CheckConnection sends it the moment the light turns green. If the bridge
		-- never answers, the text is still in the box for a later try.
		if ui.input then ui.input:SetText(text) end
		run.sendOnConnect = { chat = c.id, text = text, allow = allow }
		if not run.connectingAt then WoWAI.Connect() end
		WoWAI.Toggle(true)
		return
	end
	-- Attached links become [Name] plus their tooltip, which the guide can read.
    local displayText = Display(text)
    local references = WoWAI.ReferenceList and WoWAI.ReferenceList(text) or {}
    for payload, attachment in pairs(run.linkAttachments or {}) do
        local label = "[" .. attachment.name .. "]"
        if text:find(label, 1, true) then
            references[#references+1] = {kind=payload:match("^(%a+):"),id=tonumber(payload:match("^%a+:(%d+)")),name=attachment.name,payload=payload}
            if not text:find(attachment.link,1,true) then text=text:gsub(label:gsub("(%W)","%%%1"),function() return attachment.link end) end
        end
    end
    local links
    text, links = WoWAI.ExpandLinks(text)
	local limit = Codec.MAX_PAYLOAD - 300
	if #text > limit then
		AddHistory(c, "system", "That message is too long for one send (" .. #text .. " chars, max ~" .. limit .. "). Split it up." .. (links > 0 and " Each linked item adds its tooltip to the message." or ""))
		WoWAI.Render()
		return
	end
	-- The game context rides along when the bridge doesn't have this version yet.
	local ctx = ContextToSend(limit - #text)
    local promptSnapshot = WoWAI.QueueSnapshot and WoWAI.QueueSnapshot(false,"player",nil,true)

	db.lastSeq = db.lastSeq + 1
	local id = db.lastSeq
	local tokens = {}
	if c.resetNext then table.insert(tokens, "n") end
	if c.agent and c.agent ~= "" then table.insert(tokens, "agent=" .. c.agent) end
	table.insert(tokens, "model=" .. (c.model or db.settings.model))
    table.insert(tokens, "effort=" .. (c.effort or db.settings.effort))
    if promptSnapshot then table.insert(tokens,"snapshot="..tostring(promptSnapshot)) end
	local allowHex
	if type(allow) == "table" and #allow > 0 then
		table.insert(tokens, "allow=" .. table.concat(allow, ","))
		allowHex = ToHex(table.concat(allow, US))
	end
	local flags = table.concat(tokens, ";")
	local newSession = c.resetNext and true or nil
	c.resetNext = nil
	db.outbox = {
		id = id,
		session = db.session,
		chat = c.id,
		text = ToHex(text),
		cwd = ToHex(c.cwd),
		ctx = ctx and ToHex(ctx) or nil,
		agent = (c.agent and c.agent ~= "") and c.agent or nil,
        model = c.model or db.settings.model, effort = c.effort or db.settings.effort,
		allow = allowHex,
		newSession = newSession,
		t = time(),
	}
	c.pendingId = id
	run.linkAttachments = nil -- wire/transcript now contain the captured tooltip text
	c.draft = nil
	c.progress = nil
	AddHistory(c, "user", displayText, id)
    c.history[#c.history].references = references
	-- A chat still carrying its default name takes its title from the first message
	-- you send (system notes like "/wow-ai cd" before it don't count).
	if c.name:match("^Chat %d+$") then
		local first = true
		for _, m in ipairs(c.history) do
			if m.role == "user" and m.id ~= id then first = false break end
		end
		if first then c.name = AutoTitle(text) or c.name end
	end
	db.settings.shown = true

	if db.settings.mode == "pixel" then
		run.outbound[id] = { chat = c.id, cwd = c.cwd, flags = flags, name = c.name, text = text, ctx = ctx, sentAt = GetTime() }
		run.sentAt = GetTime()
		run.polls = 0
		StartActivity(c, id)
		ScheduleNextPoll()
		RefreshStrip()
		WoWAI.Render()
	else
		SafeReload()
	end
end

-- Forget: a record with no text telling the bridge a chat was deleted, so it drops
-- the transcript (which a later restore would otherwise bring back) and the
-- agent session. db.forget keeps the id until the bridge acks, so a delete made
-- while the bridge was away is sent again with the next hello.
local function SendForget(chatId)
	if db.settings.mode ~= "pixel" then return end
	for _, rec in pairs(run.outbound) do
		if rec.forget == chatId and not rec.acked then return end
	end
	local info = db.forget[chatId] or {}
	db.lastSeq = db.lastSeq + 1
	run.outbound[db.lastSeq] = { chat = chatId, cwd = info.cwd or "", flags = "d", name = info.name or "", text = "", sentAt = GetTime(), forget = chatId }
	RefreshStrip()
end

local function ForgetOnBridge(c)
	if not c or not c.id then return end
	db.forget[c.id] = { name = c.name, cwd = c.cwd }
	SendForget(c.id)
end

-- Snapshot packets use reserved record 0 and timed repetition, so refreshing
-- context never consumes reply slots or the finite one-shot sound ACK pool.
function WoWAI.QueueSnapshot(idle,section,requestToken,urgent)
    if not db or db.settings.copilotEnabled == false or not db.settings.context or db.settings.mode ~= "pixel" or not WoWAI.SnapshotJSON then return end
    if run.snapshotActive then
        if requestToken or (urgent and not run.snapshotRequestToken) then
            -- Player questions preempt background work; explicit tool refreshes retain priority.
            run.snapshotGeneration=nil;run.snapshotActive=nil;run.outbound[0]=nil
            run.pixelQueued=nil
        else return end
    end
    if idle and (not WoWAI.IsConnected() or next(run.outbound) or not ui.frame or not ui.frame:IsShown()) then return end
    local text = WoWAI.SnapshotJSON(section,requestToken)
    if #text > 64000 then return end
    local chunks, at = {}, 1
    while at <= #text do
        local last = math.min(at + 549, #text)
        while last < #text and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do last = last - 1 end
        chunks[#chunks + 1] = text:sub(at, last)
        at = last + 1
    end
    db.snapshotSeq = (db.snapshotSeq or 0) + 1
    local token, step = db.snapshotSeq, 0
    run.snapshotActive = true
    run.snapshotGeneration = token
    run.snapshotRequestToken = requestToken
    local function advance()
        if run.snapshotGeneration ~= token then return end
        step = step + 1
        if step > #chunks * 2 or not db.settings.context or db.settings.copilotEnabled == false then
            run.snapshotActive = nil
            run.snapshotRequestToken = nil
            run.outbound[0] = nil
            RefreshStrip()
            return
        end
        local i = ((step - 1) % #chunks) + 1
        run.outbound[0] = { chat = "", cwd = "", flags = "h", name = "",
            text = "__COPILOT1__" .. token .. ":" .. i .. ":" .. #chunks .. ":" .. chunks[i],
            sentAt = GetTime(), snapshot = true }
        RefreshStrip()
        C_Timer.After(0.25, advance)
    end
    advance()
    return token
end

-- Hello: a record with no text that just announces our session token. The bridge
-- acks it, offers a restore if our saved data is fresh, and refreshes the slots,
-- so the status light and any lost chats come back before the first message.
-- The game context always rides on it (empty when turned off), so the bridge's
-- copy is brought in line at every login and Connect.
function WoWAI.SetEnabled(enabled)
	db.settings.copilotEnabled = enabled
    if WoWAI.SetCombatEnabled then WoWAI.SetCombatEnabled(enabled) end
	if WoWAI.ApplyLinkBinding then WoWAI.ApplyLinkBinding() end
	run.sendOnConnect = nil
	if not enabled then
        run.snapshotActive,run.snapshotGeneration=nil,nil
		db.settings.shown = false
		wipe(run.outbound)
		db.outbox = nil
		for _, ch in ipairs(db.chats) do
			ch.pendingId = nil
			ch.progress = nil
		end
		if run.act then wipe(run.act) end
		keyCatcher:Hide()
	end
	db.lastSeq = db.lastSeq + 1
	run.outbound[db.lastSeq] = { chat = "", cwd = "", flags = "h", name = "", text = "__COPILOT_CONTROL__:" .. (enabled and "on" or "off"), sentAt = GetTime(), hello = true }
	RefreshStrip()
	if enabled then WoWAI.QueueSnapshot() end
	WoWAI.Render()
end

function WoWAI.SayHello()
	if db.settings.mode ~= "pixel" then return end
	if db.settings.copilotEnabled == false then WoWAI.SetEnabled(false); return end
	local now = GetTime()
	if run.lastHelloAt and now - run.lastHelloAt < 60 then return end
	run.lastHelloAt = now
    WoWAI.QueueSnapshot()
	db.lastSeq = db.lastSeq + 1
	local c = ActiveChat()
	local ctx = db.settings.context and WoWAI.GameContext() or ""
	run.outbound[db.lastSeq] = { chat = c and c.id or "", cwd = c and c.cwd or "", flags = "h", name = c and c.name or "", text = "", ctx = ctx, sentAt = now, hello = true }
	run.helloPollAt = now + 5
	-- Deletions the bridge never confirmed ride along with the hello.
	for id in pairs(db.forget) do SendForget(id) end
	-- Fresh saved data: show "restoring" instead of an empty panel until we hear back.
	if not db.restored then
		local empty = true
		for _, ch in ipairs(db.chats) do
			if #ch.history > 0 then empty = false end
		end
		if empty then run.restoring = now end
	end
	RefreshStrip()
	WoWAI.Render()
end

-- Put the active chat's pending message back on the strip.
function WoWAI.Resend()
	local c = ActiveChat()
	if not c or not c.pendingId then return end
	local text
	for i = #c.history, 1, -1 do
		if c.history[i].id == c.pendingId and c.history[i].role == "user" then
			text = c.history[i].text
			break
		end
	end
	if not text then return end
	run.outbound[c.pendingId] = { chat = c.id, cwd = c.cwd, flags = (c.agent and c.agent ~= "") and ("agent=" .. c.agent) or "", name = c.name, text = text, sentAt = GetTime() }
	run.sentAt = GetTime()
	run.polls = 0
	ScheduleNextPoll()
	RefreshStrip()
	WoWAI.UpdateStatus()
end

function WoWAI.SendFromInput()
	if not ui.input then return end
	local text = ui.input:GetText()
	ui.input:SetText("")
	ui.input:ClearFocus() -- hand the keyboard back to the game after sending
	WoWAI.Send(text)
end

-- The Allow button: grant the rules a reply asked for, then tell the agent to carry on.
function WoWAI.Allow(chatId, rules)
	local c = FindChat(chatId)
	if not c or c.pendingId or not rules or #rules == 0 then return end
	if db.activeChat ~= c.id then WoWAI.SwitchChat(c.id) end
	for _, m in ipairs(c.history) do m.denied = nil end
	AddHistory(c, "system", "Allowed: " .. table.concat(rules, ", "))
	WoWAI.Send("Those actions are allowed now. Continue from where you left off.", rules)
end

---------------------------------------------------------------------------
-- Chats
---------------------------------------------------------------------------

function WoWAI.SwitchChat(id)
	local c = FindChat(id)
	if not c then return end
	local prev = ActiveChat()
	if prev and prev ~= c and ui.input then
		local typed = Trim(ui.input:GetText() or "")
		prev.draft = typed ~= "" and typed or nil
	end
	db.activeChat = c.id
	c.unread = 0
	if ui.input then
		ui.input:SetText(c.draft or "")
		c.draft = nil
	end
	WoWAI.Render()
	WoWAI.RenderChatList()
end

function WoWAI.NewChat(name)
	local c = AddChat(name and name ~= "" and name or nil)
	if not c then
		local a = ActiveChat()
		AddHistory(a, "system", "Chat limit reached (" .. MAX_CHATS .. "). Delete one first with /wow-ai delete.")
		WoWAI.Render()
		return
	end
	WoWAI.SwitchChat(c.id)
	WoWAI.Toggle(true)
end

-- Folder this chat's agent works in. Empty (or "-" / "default") = the bridge's
-- default. Relative paths are resolved by the bridge against that default.
function WoWAI.SetFolder(rest, c)
	c = c or ActiveChat()
	if not c then return end
	rest = Trim(rest or "")
	if rest == "-" or rest == "default" then rest = "" end
	local base = run.bridgeCwd or "the bridge's default folder"
	if rest ~= "" then
		local changed = rest ~= c.cwd
		c.cwd = rest
		local absolute = rest:match("^%a:[\\/]") or rest:match("^[\\/~]")
		local note = absolute and "" or (" (relative to " .. base .. ")")
		AddHistory(c, "system", "cwd set to " .. rest .. note .. (changed and #c.history > 1 and ("; the next message starts a fresh " .. ChatAgentName(c) .. " session there") or ""))
	elseif c.cwd ~= "" then
		c.cwd = ""
		AddHistory(c, "system", "cwd reset to the bridge's default: " .. base)
	else
		AddHistory(c, "system", "cwd is the bridge's default: " .. base .. " (/wow-ai cd <folder>, or right-click the chat and pick Folder, to change)")
	end
	WoWAI.Render()
end

StaticPopupDialogs["WOWAI_FOLDER"] = {
	text = "Folder for this chat\n\nRelative to the bridge's folder (%s), ~, or a full path.\nEmpty = the bridge's default. Changing it starts a fresh agent session.",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	editBoxWidth = 320,
	maxLetters = 250,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.cwd or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		if chat and box then WoWAI.SetFolder(box:GetText(), chat) end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWAI_FOLDER"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Folder dialog for a chat (the active one when no id is given).
function WoWAI.FolderPrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWAI_FOLDER", run.bridgeCwd or "unknown until connected", nil, { id = c.id, cwd = c.cwd })
end

-- The agent this chat talks to, by id. Empty (or
-- "-" / "default") = the bridge's default. The bridge starts a fresh session
-- when a chat changes agent, since a session belongs to the agent that made it.
local function AgentList()
	return run.bridgeAgents and table.concat(run.bridgeAgents, ", ") or "claude, codex, grok, agy, hermes"
end

function WoWAI.SetAgent(rest, c)
	c = c or ActiveChat()
	if not c then return end
	rest = Trim(rest or ""):lower()
	if rest == "-" or rest == "default" then rest = "" end
	if rest ~= "" and run.bridgeAgents and not Contains(run.bridgeAgents, rest) then
		AddHistory(c, "system", "Unknown agent \"" .. rest .. "\". The bridge knows: " .. AgentList())
		WoWAI.Render()
		return
	end
	local changed = rest ~= (c.agent or "")
	c.agent = rest
	if rest ~= "" then
		AddHistory(c, "system", "agent set to " .. AgentName(rest) .. (changed and #c.history > 1 and "; the next message starts a fresh session with it" or ""))
	elseif changed then
		AddHistory(c, "system", "agent reset to the bridge's default: " .. (run.bridgeAgent and AgentName(run.bridgeAgent) or "unknown until connected"))
	else
		AddHistory(c, "system", "agent is the bridge's default: " .. (run.bridgeAgent and AgentName(run.bridgeAgent) or "unknown until connected") .. " (/wow-ai agent <name>, or right-click the chat and pick Agent, to change; agents: " .. AgentList() .. ")")
	end
	WoWAI.Render()
end

StaticPopupDialogs["WOWAI_AGENT"] = {
	text = "Agent for this chat\n\nOne of: %s.\nEmpty = the bridge's default (%s). Changing it starts a fresh session.",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	editBoxWidth = 200,
	maxLetters = 32,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.agent or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		if chat and box then WoWAI.SetAgent(box:GetText(), chat) end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWAI_AGENT"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Agent dialog for a chat (the active one when no id is given).
function WoWAI.AgentPrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWAI_AGENT", AgentList(), run.bridgeAgent and AgentName(run.bridgeAgent) or "unknown until connected", { id = c.id, agent = c.agent or "" })
end

StaticPopupDialogs["WOWAI_RENAME"] = {
	text = "Rename this chat",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 24,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		if box then
			box:SetText(data and data.name or "")
			box:HighlightText()
			box:SetFocus()
		end
	end,
	OnAccept = function(dialog, data)
		local box = dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
		local chat = data and FindChat(data.id)
		local name = box and Trim(box:GetText() or "") or ""
		if chat and name ~= "" then
			chat.name = name:sub(1, 24)
			WoWAI.Render()
		end
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		StaticPopupDialogs["WOWAI_RENAME"].OnAccept(dialog, dialog.data)
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box)
		box:GetParent():Hide()
	end,
}

-- Rename dialog for a chat (the active one when no id is given).
function WoWAI.RenamePrompt(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWAI_RENAME", nil, nil, { id = c.id, name = c.name })
end
WoWAI.RenameActive = WoWAI.RenamePrompt

-- Delete a chat (the active one when no id is given). The last chat is cleared
-- and renamed instead of removed, so there is always one to type into. Either
-- way the bridge is told to forget it, so a restore won't bring it back.
function WoWAI.DeleteChat(id)
	local c, idx = nil, nil
	if id then c, idx = FindChat(id) end
	if not c then c, idx = ActiveChat() end
	if not c then return end
	ForgetOnBridge(c)
	if #db.chats == 1 then
		wipe(c.history)
		c.pendingId, c.progress, c.unread, c.draft = nil, nil, 0, nil
		c.name = "Chat 1"
		WoWAI.Render()
		WoWAI.RenderChatList()
		return
	end
	table.remove(db.chats, idx)
	if db.activeChat == c.id then
		WoWAI.SwitchChat(db.chats[math.min(idx, #db.chats)].id)
	else
		WoWAI.RenderChatList()
	end
end

-- The trash can on a chat row asks first; /wow-ai delete does not.
StaticPopupDialogs["WOWAI_DELETE"] = {
	text = "Delete chat \"%s\"?\n\nIts transcript goes away (the last chat is cleared instead of removed).",
	button1 = OKAY,
	button2 = CANCEL,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnAccept = function(dialog, data)
		if data then WoWAI.DeleteChat(data.id) end
	end,
}

function WoWAI.ConfirmDelete(id)
	local c = (id and FindChat(id)) or ActiveChat()
	if not c then return end
	StaticPopup_Show("WOWAI_DELETE", Display(c.name), nil, { id = c.id })
end

---------------------------------------------------------------------------
-- Macros
---------------------------------------------------------------------------

-- The agent can hand over ready-made macros (a ```wowmacro block the bridge turns
-- into `macros` on the reply). Each gets a button under its message that creates
-- the macro, or updates the one with that name, and puts it on the cursor to drop
-- on an action bar. The addon never runs a macro; the player's own click does.

local MACRO_ACCOUNT_MAX = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_ACCOUNT_MACROS) or 120
local MACRO_CHAR_MAX = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_CHARACTER_MACROS) or 30
local MACRO_DEFAULT_ICON = 134400 -- question mark: with #showtooltip the game shows the spell's icon

local function MacroSay(msg)
	print("|cff66ccff[WoW AI]|r " .. msg)
end

-- Only well-formed entries survive (the slot file is trusted, but not blindly).
function WoWAI.CleanMacros(list)
	if type(list) ~= "table" then return nil end
	local out = {}
	for _, m in ipairs(list) do
		if type(m) == "table" and type(m.name) == "string" and m.name ~= "" and type(m.body) == "string" and m.body ~= "" then
			out[#out + 1] = {
				name = m.name, body = m.body, char = m.char == true, risky = m.risky == true,
				icon = (type(m.icon) == "number" or type(m.icon) == "string") and m.icon or nil,
			}
		end
	end
	return #out > 0 and out or nil
end

-- The macro called `name` among account (1..120) or character (121..150) macros:
-- the same name may exist in both, and only the requested kind counts.
local function FindMacro(name, perCharacter)
	local first = perCharacter and MACRO_ACCOUNT_MAX + 1 or 1
	local last = perCharacter and MACRO_ACCOUNT_MAX + MACRO_CHAR_MAX or MACRO_ACCOUNT_MAX
	for i = first, last do
		local n, icon, body = Try(GetMacroInfo, i)
		if n == name then return i, icon, body end
	end
end

local function MacroIcon(icon)
	if type(icon) == "number" then return icon end
	if type(icon) == "string" then
		local id = Try(GetFileIDFromPath, "Interface\\Icons\\" .. icon)
		if type(id) == "number" and id > 0 then return id end
		return icon -- CreateMacro also takes a texture name
	end
	return MACRO_DEFAULT_ICON
end

function WoWAI.MacroLabel(m)
	local verb = FindMacro(m.name, m.char) and "Update" or "Create"
	return verb .. " macro: " .. Display(m.name) .. (m.char and " (character)" or "") .. (m.risky and "  |cffff6060(runs code)|r" or "")
end

StaticPopupDialogs["WOWAI_MACRO"] = {
	text = "%s",
	button1 = OKAY,
	button2 = CANCEL,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnAccept = function(dialog, data)
		if data then WoWAI.InstallMacro(data, true) end
	end,
}

-- Create or update macro `m` ({ name, body, icon, char, risky }). Asks first when it
-- would replace a different macro of yours, or when it runs code (/run, /click...).
function WoWAI.InstallMacro(m, confirmed)
	if type(m) ~= "table" then return end
	if InCombatLockdown() then
		MacroSay("macros can't be changed in combat; click the button again afterwards.")
		return
	end
	local index, _, oldBody = FindMacro(m.name, m.char)
	if not confirmed then
		local why = {}
		if m.risky then table.insert(why, "This macro runs code or clicks buttons (/run, /script, /click). Only keep it if you trust what it does.") end
		if index and oldBody ~= m.body then table.insert(why, "It replaces your existing macro \"" .. m.name .. "\" (/wow-ai macro undo brings the old one back).") end
		if #why > 0 then
			StaticPopup_Show("WOWAI_MACRO", table.concat(why, "\n\n") .. "\n\n" .. tostring(m.body):gsub("|","¦"), nil, m)
			return
		end
	end
	-- Blizzard's macro window saves its edit box into its selected macro when it
	-- hides; close it first so that can't land on a macro we just moved.
	if MacroFrame and MacroFrame:IsShown() then
		Try(HideUIPanel, MacroFrame)
		index, _, oldBody = FindMacro(m.name, m.char)
	end
	local ok, newIndex
	if index then
		local _, oldIcon = FindMacro(m.name, m.char)
		ok, newIndex = pcall(EditMacro, index, m.name, m.icon ~= nil and MacroIcon(m.icon) or nil, m.body)
		if ok and type(newIndex) == "number" then
			db.macroUndo = { name = m.name, char = m.char, icon = oldIcon, body = oldBody }
		end
	else
		local acc, chr = Try(GetNumMacros)
		if m.char and type(chr) == "number" and chr >= MACRO_CHAR_MAX then
			MacroSay("your character macros are full (" .. MACRO_CHAR_MAX .. "); delete one in /macro first.")
			return
		elseif not m.char and type(acc) == "number" and acc >= MACRO_ACCOUNT_MAX then
			MacroSay("your account macros are full (" .. MACRO_ACCOUNT_MAX .. "); delete one in /macro first.")
			return
		end
		ok, newIndex = pcall(CreateMacro, m.name, MacroIcon(m.icon), m.body, m.char)
		if (not ok or type(newIndex) ~= "number") and m.icon ~= nil then
			ok, newIndex = pcall(CreateMacro, m.name, MACRO_DEFAULT_ICON, m.body, m.char)
		end
		if ok and type(newIndex) == "number" then
			db.macroUndo = { name = m.name, char = m.char, created = true }
		end
	end
	if not ok or type(newIndex) ~= "number" then
		MacroSay("could not save macro \"" .. m.name .. "\": " .. (ok and "the game refused it (is the list full?)" or tostring(newIndex)))
		return
	end
	-- EditMacro may move the macro (names are sorted): pick up the index it returned.
	Try(PickupMacro, newIndex)
	MacroSay("macro \"" .. m.name .. "\" " .. (index and "updated" or "created") .. " and on your cursor: click an action bar slot to place it (it is also in /macro).")
	WoWAI.Render()
end

function WoWAI.UndoMacro()
	local u = db.macroUndo
	if not u then MacroSay("nothing to undo."); return end
	if InCombatLockdown() then MacroSay("macros can't be changed in combat."); return end
	local index = FindMacro(u.name, u.char)
	if not index then MacroSay("macro \"" .. u.name .. "\" is gone already."); db.macroUndo = nil; return end
	if MacroFrame and MacroFrame:IsShown() then Try(HideUIPanel, MacroFrame); index = FindMacro(u.name, u.char) end
	if u.created then
		Try(DeleteMacro, index)
		MacroSay("removed macro \"" .. u.name .. "\".")
	else
		Try(EditMacro, index, u.name, u.icon, u.body)
		MacroSay("macro \"" .. u.name .. "\" is back to what it was.")
	end
	db.macroUndo = nil
	WoWAI.Render()
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

function WoWAI.UpdateStatus()
    if not ui.status then return end
    local c = ActiveChat()
    local mode = db.settings.mode
    local message
    if db.settings.copilotEnabled == false then
        message = "The guide is closed. /ai brings it back."
    elseif c and c.pendingId then
        if run.slotsMissing then
            message = "Restart WoW to finish setting up the guide."
        elseif run.slotsExhausted then
            message = "Use /reload to refresh the guide."
        elseif run.pixelFailed then
            message = "Message not received. Use /reload, then try again."
        elseif run.outbound[c.pendingId] and not run.outbound[c.pendingId].acked then
            message = "Sending your question..."
        else
            message = "Consulting the guide..."
        end
    elseif not WoWAI.IsConnected() then
        if run.connectingAt or run.restoring then
            message = "Opening the guide..."
        elseif run.connectFailed then
            message = "Guide unavailable. Click Connect to try again."
        elseif WoWAI.BridgeState() == "stale" then
            message = "Connection lost. Click Reconnect."
        else
            message = "Click Connect to open the guide."
        end
    elseif c and c.draft and c.draft ~= "" then
        message = "Your draft is ready. Press Enter to send."
    else
        message = "Ready for your next adventure"
    end
    ui.status:SetText(message)
    run.statusText = message
    WoWAI.UpdateDot()
    WoWAI.UpdateConnect()
    if ui.title then ui.title:SetText("Adventurer's Guide") end
    ui.cwd:SetText("Hover an item, spell, or quest: " .. (run.linkKeyActive or "use Attach") .. " to add it.")
    if ui.resend then ui.resend:SetShown(c and c.pendingId ~= nil and mode == "pixel") end
    if ui.refresh then ui.refresh:SetShown(mode ~= "pixel" or run.slotsExhausted or run.slotsMissing or run.pixelFailed or false) end
    WoWAI.UpdateMini()
end

-- One message bubble: accent bar, colored label, timestamp, wrapped body.
local function GetBubble(i)
	local b = ui.bubbles[i]
	if b then return b end
	b = CreateFrame("Frame", nil, ui.content)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.accent = b:CreateTexture(nil, "BORDER")
	b.accent:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b.accent:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
	b.accent:SetWidth(3)
	b.who = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.who:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -6)
	b.who:SetJustifyH("LEFT")
	b.when = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	b.when:SetPoint("TOPRIGHT", b, "TOPRIGHT", -8, -6)
	b.body = b:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	b.body:SetPoint("TOPLEFT", b.who, "BOTTOMLEFT", 0, -4)
	b.body:SetJustifyH("LEFT")
	b.body:SetJustifyV("TOP")
	b.body:SetWordWrap(true)
	b.body:SetNonSpaceWrap(true)
	b.allow = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
	b.allow:SetHeight(22)
	b.allow:SetPoint("TOPLEFT", b.body, "BOTTOMLEFT", 0, -6)
	b.allow:SetScript("OnClick", function(self)
		WoWAI.Allow(self.chatId, self.rules)
	end)
	b.allow:Hide()
	b.macroBtns = {}
	-- FontStrings can't be selected, so a click opens the message in the copy box.
	b:EnableMouse(true)
	b:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and self.text and self.text ~= "" then WoWAI.ShowCopy(self.text) end
	end)
	ui.bubbles[i] = b
	return b
end

function WoWAI.Render()
    if WoWAI.UpdateModelButtons and db then WoWAI.UpdateModelButtons() end
	local c = ActiveChat()
	if ui.content and c then
        local priorOffset = ui.scroll:GetVerticalScroll() or 0
        local priorRange = ui.scroll:GetVerticalScrollRange() or 0
        local following = ui.scroll.followLatest ~= false
        local chatChanged = ui.scroll.chatId ~= c.id
        ui.scroll.chatId = c.id
        ui.scroll.renderGeneration = (ui.scroll.renderGeneration or 0)+1
        local generation = ui.scroll.renderGeneration
		local width = ui.scroll:GetWidth()
		if not width or width < 80 then width = 400 end
		ui.content:SetWidth(width)
		local y, n = 0, 0
		local function Place(role, text, when, dim, denied, agent, macros, references)
			n = n + 1
			local b = GetBubble(n)
			local st = ROLE_STYLE[role] or ROLE_STYLE.system
			b:SetWidth(width)
			b.bg:SetColorTexture(st.bg[1], st.bg[2], st.bg[3], st.bg[4])
			b.accent:SetColorTexture(st.color[1], st.color[2], st.color[3], 0.9)
			b.who:SetText(st == ROLE_STYLE.assistant and ReplyAgentName(c, agent) or st.label)
			b.who:SetTextColor(st.color[1], st.color[2], st.color[3])
			b.when:SetText(when or "")
			b.body:SetWidth(width - 18)
			b.body:SetText(Display((text or ""):gsub("\n\n%-%-%- Linked from the game %-%-%-[%s%S]*", "")))
			if dim then
				b.body:SetTextColor(0.72, 0.72, 0.72)
			else
				b.body:SetTextColor(0.94, 0.89, 0.78)
			end
			local h = b.body:GetStringHeight()
			if not h or h < 1 then h = 14 end
			local extra = 0
			if denied then
				local label = "Allow " .. table.concat(denied, ", ") .. " & retry"
				b.allow:SetText(label)
				b.allow:SetWidth(math.min(width - 24, math.max(160, b.allow:GetFontString():GetStringWidth() + 30)))
				b.allow.chatId = c.id
				b.allow.rules = denied
				b.allow:Show()
				extra = 28
			else
				b.allow:Hide()
			end
			-- One button per macro the agent handed over.
			local shownMacros = 0
			for k, m in ipairs(macros or {}) do
				local mb = b.macroBtns[k]
				if not mb then
					mb = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
					mb:SetHeight(22)
					mb:SetScript("OnClick", function(self) WoWAI.InstallMacro(self.macro) end)
					mb:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:AddLine(Display(self.macro.name))
						GameTooltip:AddLine(tostring(self.macro.body):gsub("|","¦"), 1, 1, 1, true)
						GameTooltip:Show()
					end)
					mb:SetScript("OnLeave", function() GameTooltip:Hide() end)
					b.macroBtns[k] = mb
				end
				mb.macro = m
				mb:SetText(WoWAI.MacroLabel(m))
				mb:SetWidth(math.min(width - 24, math.max(160, mb:GetFontString():GetStringWidth() + 30)))
				mb:ClearAllPoints()
				mb:SetPoint("TOPLEFT", b.body, "BOTTOMLEFT", 0, -6 - extra)
				mb:Show()
				extra = extra + 28
				shownMacros = k
			end
			for k = shownMacros + 1, #b.macroBtns do b.macroBtns[k]:Hide() end
			if WoWAI.RenderReferenceCards then
                local cardHeight = WoWAI.RenderReferenceCards(b, references, width-20, b.body)
                if cardHeight > 0 then b.referenceDeck:SetPoint("TOPLEFT",b.body,"BOTTOMLEFT",0,-8-extra) end
                extra = extra + cardHeight
            end
			b:SetHeight(6 + 12 + 4 + h + 8 + extra)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, -y)
			b.text = text
			b:Show()
			y = y + b:GetHeight() + 6
		end
		local last = #c.history
		for i, m in ipairs(c.history) do
			-- The Allow button only makes sense on the newest reply, and only while idle.
			local denied = (i == last and not c.pendingId and type(m.denied) == "table" and #m.denied > 0) and m.denied or nil
			Place(m.role, m.text, m.t and date("%H:%M", m.t) or "", false, denied, m.agent, m.macros, m.references or (m.role == "assistant" and c.referenceCards and c.referenceCards[tostring(m.id)]))
		end
		if c.pendingId then
            Place("assistant", "Consulting your journal and the latest guides...", "", true)
		elseif #c.history == 0 then
			if run.restoring then
				Place("system", "Opening your journal...", "", true)
			elseif not WoWAI.IsConnected() then
				Place("system", "Welcome to your Forever journal. Connect your Codex account to get started.", "", true)
			else
				Place("system", "Where shall we go next? Ask about a quest, an item, or your next destination. Hover an item, spell, or quest and use Ctrl+Alt+middle-click to share its details.", "", true)
			end
		end
		for i = n + 1, #ui.bubbles do
			ui.bubbles[i]:Hide()
		end
        if ui.loginButton then
            local needsSetup=#c.history==0 and not c.pendingId and not WoWAI.IsConnected() and not run.restoring
            ui.loginButton:SetShown(needsSetup)
            if needsSetup then
                ui.loginButton:ClearAllPoints()
                ui.loginButton:SetPoint("TOPLEFT",ui.bubbles[n],"BOTTOMLEFT",14,-8)
                y=y+44
            end
        end
		ui.content:SetHeight(math.max(y, 1))
        C_Timer.After(0.05, function()
            local sc = ui.scroll
            if not sc or sc.renderGeneration ~= generation then return end
            -- A wheel/drag after rendering wins over this deferred layout update.
            if chatChanged or (following and sc.followLatest ~= false) then
                sc:SetVerticalScroll(sc:GetVerticalScrollRange())
                sc.followLatest = true
            else sc:SetVerticalScroll(math.min(sc.userOffset or priorOffset,sc:GetVerticalScrollRange())) end
        end)
	end
	if WoWAI.UpdateDraftCards then WoWAI.UpdateDraftCards() end
	WoWAI.UpdateStatus()
	WoWAI.RenderChatList()
end

-- Copy box (/wow-ai copy): a selectable EditBox with the last reply pre-highlighted for Ctrl+C.
function WoWAI.ShowCopy(text)
	if not ui.copy then
		local cf = CreateFrame("Frame", "WoWAICopy", UIParent, "BackdropTemplate")
		cf:SetSize(560, 320)
		cf:SetPoint("CENTER")
		cf:SetFrameStrata("FULLSCREEN_DIALOG")
		cf:SetMovable(true)
		cf:SetClampedToScreen(true)
		cf:EnableMouse(true)
		cf:RegisterForDrag("LeftButton")
		cf:SetScript("OnDragStart", cf.StartMoving)
		cf:SetScript("OnDragStop", cf.StopMovingOrSizing)
		cf:SetBackdrop(BACKDROP)
		cf:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
		cf:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
		tinsert(UISpecialFrames, "WoWAICopy")

		local t = cf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -12)
		t:SetText("Text is selected - press Ctrl+C, then Esc")

		local x = CreateFrame("Button", nil, cf, "UIPanelCloseButton")
		x:SetPoint("TOPRIGHT", cf, "TOPRIGHT", -4, -4)

		local sc = CreateFrame("ScrollFrame", "WoWAICopyScroll", cf, "UIPanelScrollFrameTemplate")
		sc:SetPoint("TOPLEFT", cf, "TOPLEFT", 14, -36)
		sc:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -32, 14)
		local eb = CreateFrame("EditBox", "WoWAICopyBox", sc)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject(ChatFontNormal)
		eb:SetMaxLetters(0)
		eb:SetSize(500, 260)
		eb:SetScript("OnEscapePressed", function() cf:Hide() end)
		sc:SetScrollChild(eb)
		sc:HookScript("OnSizeChanged", function(self, w) eb:SetWidth(w) end)
		ui.copy, ui.copyBox = cf, eb
	end
	ui.copyBox:SetText(text)
	ui.copy:Show()
	ui.copyBox:SetFocus()
	ui.copyBox:HighlightText()
end

function WoWAI.RenderChatList()
	if not ui.chatButtons then return end
	for i, btn in ipairs(ui.chatButtons) do
		local c = db.chats[i]
		if c then
			local label = Display(c.name)
			local folder = FolderName(ChatFolder(c))
			if folder ~= "" and folder:lower() ~= c.name:lower() then
				label = label .. " |cff888888" .. Display(folder) .. "|r"
			end
			if c.agent and c.agent ~= "" then
				label = label .. " |cff888888" .. AgentName(c.agent) .. "|r"
			end
			if c.pendingId then
				label = label .. " |cffffd100...|r"
			elseif (c.unread or 0) > 0 then
				label = label .. " |cff55ff55(" .. c.unread .. ")|r"
			end
			btn.label:SetText(label)
			btn.chatId = c.id
			btn.selected:SetShown(c.id == db.activeChat)
			btn:Show()
		else
			btn:Hide()
		end
	end
end

function WoWAI.UpdateMini()
	if not ui.miniBadge then return end
	local unread, working = 0, 0
	for _, c in ipairs(db.chats) do
		unread = unread + (c.unread or 0)
		if c.pendingId then working = working + 1 end
	end
	local t
	if working > 0 and unread > 0 then
		t = "|cff55ff55" .. unread .. " new|r |cffffd100" .. working .. " working|r"
	elseif working > 0 then
		t = "|cffffd100" .. (working == 1 and "Consulting..." or (working .. " questions...")) .. "|r"
	elseif unread > 0 then
		t = "|cff55ff55" .. unread .. (unread == 1 and " new reply" or " new replies") .. "|r"
	else
		t = "|cffb8a786Ready|r"
	end
	ui.miniBadge:SetText(t)
	if ui.miniPulse then
		if unread > 0 then
			if not ui.miniPulse:IsPlaying() then ui.miniPulse:Play() end
		else
			ui.miniPulse:Stop()
			ui.miniBadge:SetAlpha(1)
		end
	end
end

local ECHO_DEFAULT = 4000 -- characters of a reply to print into the game chat ("/wow-ai echo <n>")

local function ChatLinks(chat)
	return "  |Hwowai:reply:" .. chat.id .. "|h|cff55ff55[reply]|r|h |Hwowai:open:" .. chat.id .. "|h|cff7ec8ff[open]|r|h"
end

local SUMMARY_LINES = 3 -- lines of the agent's TL;DR block printed in "summary" mode
local SUMMARY_FALLBACK_LINES = 2 -- lines of the reply shown when it came without one

-- Print a reply into the game chat: prefix on the first line, then the text line
-- by line up to the limit, then clickable links. `short` prints one preview line.
-- `summary` (the default) prints the TL;DR block the bridge split off the reply,
-- or the first lines of the reply when the agent didn't write one; the full text
-- is in the window, behind [open].
local function EchoToChat(chat, text, agent, summary)
	local mode = db.settings.echo
	if mode == "off" then return end
	local prefix = "|cff7ec8ff[" .. ReplyAgentName(chat, agent) .. " · " .. Display(chat.name) .. "]|r "
	local body = Display(text)
	if mode == "short" then
		local flat = (body:gsub("%s+", " "))
		if #flat > 200 then flat = flat:sub(1, 200) .. " ..." end
		print(prefix .. flat .. ChatLinks(chat))
		return
	end
	if mode == "summary" then
		local source, max = Display(summary or ""), SUMMARY_LINES
		if not source:match("%S") then source, max = body, SUMMARY_FALLBACK_LINES end
		local lines, total = {}, 0
		for line in (source .. "\n"):gmatch("(.-)\n") do
			if line:match("%S") then
				total = total + 1
				if total <= max then table.insert(lines, line) end
			end
		end
		for i, line in ipairs(lines) do
			print((i == 1 and prefix or "    ") .. line)
		end
		if total > max then
			print("    |cff888888... click [open] to read it all|r")
		end
		print("    " .. ChatLinks(chat):sub(3))
		return
	end
	local limit = tonumber(mode) or ECHO_DEFAULT
	local first, shown = true, 0
	for line in (body .. "\n"):gmatch("(.-)\n") do
		if line:match("%S") then
			if shown + #line > limit then
				print("    |cff888888... " .. (#body - shown) .. " more characters, click [open] to read it all|r")
				break
			end
			print((first and prefix or "    ") .. line)
			first = false
			shown = shown + #line
		end
	end
	print("    " .. ChatLinks(chat):sub(3))
end

-- A reply landed. Always play the sound and echo it to the game chat; if that
-- chat isn't on screen, also flash the screen text and light up the mini bar.
function WoWAI.Notify(chat, text, agent, summary)
	pcall(PlaySound, 3081)
	WoWAI.UpdateMini()
	-- Until a real whisper arrives, /r replies to this chat.
	run.lastMessenger = "agent"
	run.lastReplyChat = chat.id
	EchoToChat(chat, text, agent, summary)
	if ui.frame and ui.frame:IsShown() and db.activeChat == chat.id then return end
	if UIErrorsFrame then
		UIErrorsFrame:AddMessage(ReplyAgentName(chat, agent) .. " replied in " .. Display(chat.name), 0.5, 0.8, 1, 1)
	end
end

-- /r goes to the agent when it was the last one to message you, exactly like
-- whisper reply, and the box shows a "To Codex [chat]:" header while you type.
--
-- The chat type underneath is left alone (a custom type would leak into chat
-- settings); instead the box remembers an agent target, the header is repainted
-- over the game's own, and the send entry points are intercepted. Any other chat
-- type, Tab, Esc or a cleared box drops the target again.
local AGENT_R, AGENT_G, AGENT_B = 0.49, 0.78, 1.0

-- Clicks on our [reply] / [open] links in the chat frame.
hooksecurefunc("SetItemRef", function(link)
	local action, chatId = tostring(link):match("^wowai:(%a+):(%w+)")
	if not action or not db then return end
	if FindChat(chatId) then WoWAI.SwitchChat(chatId) end
	WoWAI.Toggle(true)
	if action == "reply" and ui.input then ui.input:SetFocus() end
end)

-- Explicit tooltip attachments leave Blizzard's Shift-click behavior untouched.
local function Readable(value)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    if type(canaccessvalue) == "function" then
        local ok, access = pcall(canaccessvalue, value)
        if not ok or not access then return nil end
    end
    return value
end
local function TooltipText(value)
    value = Readable(value)
    return type(value) == "string" and value or nil
end
local hoverTooltips = setmetatable({}, {__mode="k"})
local hyperlinkFrames = setmetatable({}, {__mode="k"})
local function ReadHover(tooltip, explicitLink, explicitLines)
    if not tooltip and not explicitLink then return end
    tooltip = tooltip or GameTooltip
    local name, link, id = nil, explicitLink, nil
    if not link and TooltipUtil and TooltipUtil.GetDisplayedItem then name, link, id = Try(TooltipUtil.GetDisplayedItem, tooltip) end
    link, name, id = TooltipText(link), TooltipText(name), Readable(id)
    if not link and tooltip.GetItem then
        name, link = Try(tooltip.GetItem, tooltip)
        name, link = TooltipText(name), TooltipText(link)
    end
    -- ID fallback covers partially cached bag-item links on the modern client.
    local data = Readable(Try(tooltip.GetPrimaryTooltipData, tooltip))
    if not link and data and Enum and Enum.TooltipDataType then
        local kind = Readable(Try(function() return data.type end))
        local primaryID = Readable(Try(function() return data.id end))
        if kind == Enum.TooltipDataType.Item and type(primaryID) == "number" and primaryID > 0 then
            local itemName, itemLink = Try((C_Item and C_Item.GetItemInfo) or GetItemInfo, primaryID)
            name, link = TooltipText(itemName) or name, TooltipText(itemLink)
            if not link then
                local first = _G["GameTooltipTextLeft1"]
                name = name or TooltipText(first and Try(first.GetText, first)) or ("Item " .. primaryID)
                link = "|Hitem:" .. primaryID .. "|h[" .. name .. "]|h"
            end
        end
    end
    if not link then
        if TooltipUtil and TooltipUtil.GetDisplayedSpell then name, id = Try(TooltipUtil.GetDisplayedSpell, tooltip)
        end
        if not id and tooltip.GetSpell then name, id = Try(tooltip.GetSpell, tooltip) end
        if not id and data and Enum and Enum.TooltipDataType then
            -- Primary data is also available before the spell-name cache fills.
            local kind = Readable(Try(function() return data.type end))
            if kind == Enum.TooltipDataType.Spell then id = Readable(Try(function() return data.id end)) end
        end
        name, id = TooltipText(name), Readable(id)
        if type(id) == "number" and id > 0 then
            link = TooltipText(Try((C_Spell and C_Spell.GetSpellLink) or GetSpellLink, id))
            if not link then link = "|Hspell:" .. id .. "|h[" .. (name or ("Spell " .. id)) .. "]|h" end
        end
    end
    if not link then return end
    local payload, label = link:match("|H([^|]+)|h%[([^%]]*)%]|h")
    local kind = payload and payload:match("^(%a+):")
    if kind ~= "item" and kind ~= "spell" and kind ~= "quest" then return end
    local lines = explicitLines or {}
    local tipName = TooltipText(Try(tooltip.GetName, tooltip)) or "GameTooltip"
    local count = Readable(Try(tooltip.NumLines, tooltip))
    for i = 1, math.min(not explicitLines and type(count) == "number" and count or 0, LINK_LINES_MAX) do
        local left, right = _G[tipName .. "TextLeft" .. i], _G[tipName .. "TextRight" .. i]
        local a = TooltipText(left and Try(left.GetText, left)) or ""
        local b = TooltipText(right and Try(right.GetText, right)) or ""
        if b ~= "" then a = a .. "  " .. b end
        if a ~= "" and not a:lower():find("submit an issue", 1, true) then lines[#lines + 1] = a end
    end
    return { link = link, payload = payload, name = name or label, lines = lines, at = GetTime() }
end
function WoWAI.RememberHoveredTooltip(tooltip)
    if not tooltip or tooltip == scanTip then return end
    local name=TooltipText(Try(tooltip.GetName,tooltip)) or ""
    if name:lower():find("compare",1,true) or name:lower():find("shopping",1,true) then return end
    if not hoverTooltips[tooltip] then
        hoverTooltips[tooltip]=true
        if tooltip.HookScript then pcall(tooltip.HookScript,tooltip,"OnShow",WoWAI.RememberHoveredTooltip) end
    end
    if not Try(tooltip.IsShown,tooltip) then return end
    local attachment = ReadHover(tooltip)
    if attachment then run.hoverAttachment = attachment end
end
local function FrameValue(frame, key)
    return Readable(Try(function() return frame[key] end))
end
local function QuestAttachment(questID)
    if type(questID) ~= "number" or questID <= 0 then return end
    local name = TooltipText(Try(C_QuestLog and C_QuestLog.GetTitleForQuestID, questID)) or ("Quest " .. questID)
    local link = TooltipText(Try((C_QuestLog and C_QuestLog.GetQuestLink) or GetQuestLink, questID)) or ("|Hquest:" .. questID .. "|h[" .. name .. "]|h")
    local lines = { name }
    for _, objective in ipairs(Try(C_QuestLog and C_QuestLog.GetQuestObjectives, questID) or {}) do
        local text = TooltipText(Try(function() return objective.text end))
        if text then lines[#lines + 1] = text end
    end
    return ReadHover(GameTooltip, link, lines)
end
local function FrameQuestID(frame)
    local id = FrameValue(frame, "questID") or Readable(Try(frame.GetQuestID, frame))
    for _, key in ipairs({ "info", "elementData" }) do
        local data = FrameValue(frame, key)
        if not id and type(data) == "table" then id = FrameValue(data, "questID") end
    end
    local data = Try(frame.GetElementData, frame)
    if not id and type(data) == "table" then id = FrameValue(data, "questID") end
    local module = FrameValue(frame, "parentModule") or FrameValue(frame, "module")
    if not id and module then
        local report = Try(module.GetDebugReportInfo, module, frame)
        if type(report) == "table" then id = FrameValue(report, "questID") end
        -- Older tracker versions have the same block ID but no debug getter.
        if not id and (module == QuestObjectiveTracker or module == CampaignQuestObjectiveTracker or module == WorldQuestObjectiveTracker or module == QUEST_TRACKER_MODULE) then
            id = FrameValue(frame, "id")
        end
    end
    return id
end
local function EntityLink(link)
    if not link then return end
    local payload = link:match("|H([^|]+)|h")
    local visible = GameTooltip and GameTooltip:IsShown() and ReadHover(GameTooltip)
    -- Never copy an unrelated/stale tooltip onto a directly identified entity.
    if visible and visible.payload == payload then return visible end
    return ReadHover(GameTooltip, link, {})
end
local function IDAttachment(kind, id)
    if type(id) ~= "number" or id <= 0 then return end
    local name, link
    if kind == "spell" then
        name = TooltipText(Try((C_Spell and C_Spell.GetSpellName) or GetSpellInfo, id))
        link = TooltipText(Try((C_Spell and C_Spell.GetSpellLink) or GetSpellLink, id))
    else
        name, link = Try((C_Item and C_Item.GetItemInfo) or GetItemInfo, id)
        name, link = TooltipText(name), TooltipText(link)
    end
    return EntityLink(link or ("|H" .. kind .. ":" .. id .. "|h[" .. (name or (kind .. " " .. id)) .. "]|h"))
end
function WoWAI.RememberHoveredHyperlink(frame, linkData, linkText)
    linkData, linkText = TooltipText(linkData), TooltipText(linkText)
    local payload = linkData and (linkData:match("|H([^|]+)|h") or linkData)
    local kind, id
    if payload then kind, id = payload:match("^(%a+):(%d+)") end
    if kind ~= "item" and kind ~= "spell" and kind ~= "quest" then run.hoverHyperlink = nil; return end
    local label = linkText and (linkText:match("|h%[([^%]]*)%]|h") or linkText:match("^%[([^%]]*)%]$"))
    local fallback
    if kind == "quest" then fallback = QuestAttachment(tonumber(id)) else fallback = IDAttachment(kind, tonumber(id)) end
    label = label or (fallback and fallback.name) or (kind .. " " .. id)
    local attachment = ReadHover(GameTooltip, "|H" .. payload .. "|h[" .. label .. "]|h", {})
    if not attachment then return end
    run.hoverHyperlink = {frame=frame,attachment=attachment}
    run.hoverAttachment = attachment
end
local function HookHyperlinkFrame(frame)
    if not frame or hyperlinkFrames[frame] or type(frame.HookScript) ~= "function" then return end
    local ok = pcall(frame.HookScript, frame, "OnHyperlinkEnter", WoWAI.RememberHoveredHyperlink)
    if not ok then return end
    hyperlinkFrames[frame] = true
    pcall(frame.HookScript, frame, "OnHyperlinkLeave", function(self)
        if run.hoverHyperlink and run.hoverHyperlink.frame == self then run.hoverHyperlink = nil end
    end)
    pcall(frame.HookScript, frame, "OnLeave", function(self)
        if run.hoverHyperlink and run.hoverHyperlink.frame == self then run.hoverHyperlink = nil end
    end)
    pcall(frame.HookScript, frame, "OnHide", function(self)
        if run.hoverHyperlink and run.hoverHyperlink.frame == self then run.hoverHyperlink = nil end
    end)
end
function WoWAI.HookChatLinks()
    for i=1,(NUM_CHAT_WINDOWS or 10) do HookHyperlinkFrame(_G["ChatFrame" .. i]) end
    for _, name in ipairs(CHAT_FRAMES or {}) do HookHyperlinkFrame(_G[name]) end
end
for _, name in ipairs({"FCF_OpenNewWindow", "FCF_OpenTemporaryWindow"}) do
    if type(_G[name]) == "function" then pcall(hooksecurefunc, name, WoWAI.HookChatLinks) end
end
local function ReadFrameEntity(frame)
    -- Roll icons and their name/need/greed children share a parent roll ID.
    local rollID = FrameValue(frame, "rollID") or FrameValue(frame, "rollId")
    if type(rollID) == "number" then
        local link = TooltipText(Try(GetLootRollItemLink, rollID))
        if link then return EntityLink(link) end
    end
    local lootSlot = Readable(Try(frame.GetSlotIndex, frame))
    if type(lootSlot) == "number" and lootSlot > 0 then
        local link = TooltipText(Try(GetLootSlotLink, lootSlot))
        if link then return EntityLink(link) end
    end
    local bag, slot
    local location = Try(frame.GetItemLocation, frame)
    if location then bag, slot = Try(location.GetBagAndSlot, location) end
    if bag == nil then bag = Try(frame.GetBagID, frame) end
    if slot == nil then slot = Try(frame.GetSlotID, frame) or Try(frame.GetID, frame) end
    local parent = Try(frame.GetParent, frame)
    local parentName = parent and TooltipText(Try(parent.GetName, parent)) or ""
    if bag == nil and parentName:match("^ContainerFrame") then bag = Try(parent.GetID, parent) end
    bag, slot = Readable(bag), Readable(slot)
    if type(bag) == "number" and type(slot) == "number" and slot > 0 then
        local link = TooltipText(Try((C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink, bag, slot))
        if link then return EntityLink(link) end
    end
    local name = TooltipText(Try(frame.GetName, frame)) or ""
    if name:match("^Character.+Slot$") and type(slot) == "number" then
        local link = TooltipText(Try(GetInventoryItemLink, "player", slot))
        if link then return EntityLink(link) end
    end
    local link = TooltipText(FrameValue(frame, "itemLink"))
    if link then return EntityLink(link) end
    local itemID = FrameValue(frame, "itemID") or FrameValue(frame,"itemId")
    for _,key in ipairs({"item","entry","data"}) do
        local value=FrameValue(frame,key)
        if type(value)=="table" then itemID=itemID or FrameValue(value,"itemID") or FrameValue(value,"itemId") end
    end
    local item=FrameValue(frame,"item")
    if not itemID and type(item)=="table" and type(FrameValue(item,2))=="string" then itemID=FrameValue(item,1) end
    if itemID then local a = IDAttachment("item", itemID); if a then return a end end
    local spellID = FrameValue(frame, "spellID")
    local spellInfo = FrameValue(frame, "spellBookItemInfo")
    if not spellID and type(spellInfo) == "table" then spellID = FrameValue(spellInfo, "spellID") end
    if spellID then local a = IDAttachment("spell", spellID); if a then return a end end
    local action = FrameValue(frame, "action")
    if type(action) == "number" then
        local kind, id = Try(GetActionInfo, action)
        kind, id = TooltipText(kind), Readable(id)
        if kind == "macro" then
            local spell = Readable(Try(GetMacroSpell, id))
            if spell then return IDAttachment("spell", spell) end
            local _, itemLink = Try(GetMacroItem, id)
            if TooltipText(itemLink) then return EntityLink(itemLink) end
        elseif kind == "spell" or kind == "item" then return IDAttachment(kind, id) end
    end
    return QuestAttachment(FrameQuestID(frame))
end
local function ReadTrackerUnderCursor()
    local found
    local function inspect(block)
        if found or not Try(block.IsShown, block) then return end
        local over = Try(block.IsMouseOver, block) or Try(MouseIsOver, block)
        if not over then
            local header = FrameValue(block, "HeaderText")
            over = header and (Try(header.IsMouseOver, header) or Try(MouseIsOver, header))
        end
        if not over then
            for _, line in pairs(FrameValue(block, "usedLines") or {}) do
                local text = FrameValue(line, "Text")
                if Try(line.IsShown, line) and (Try(line.IsMouseOver, line) or Try(MouseIsOver, line) or (text and (Try(text.IsMouseOver, text) or Try(MouseIsOver, text)))) then over = true; break end
            end
        end
        if over then found = QuestAttachment(FrameQuestID(block)) end
    end
    for _, moduleName in ipairs({ "QuestObjectiveTracker", "CampaignQuestObjectiveTracker", "WorldQuestObjectiveTracker", "QUEST_TRACKER_MODULE" }) do
        local module = _G[moduleName]
        if module and Try(module.IsShown, module) then
            if type(module.EnumerateActiveBlocks) == "function" then Try(module.EnumerateActiveBlocks, module, inspect)
            else
                for _, blocks in pairs(FrameValue(module, "usedBlocks") or {}) do
                    if type(blocks) == "table" then
                        if FrameValue(blocks, "parentModule") then inspect(blocks)
                        else for _, block in pairs(blocks) do inspect(block) end end
                    end
                end
            end
        end
    end
    return found
end
local function VisibleHoverTooltip()
    -- Tooltip processors include custom journal/loot frames, including unnamed ones.
    -- Discover legacy addon tooltips on demand, avoiding a continuous global scan.
    if type(EnumerateFrames)=="function" then
        local frame=Try(EnumerateFrames)
        for i=1,10000 do
            if not frame then break end
            if Try(frame.GetObjectType,frame)=="GameTooltip" and Try(frame.IsShown,frame) then
                WoWAI.RememberHoveredTooltip(frame)
            end
            frame=Try(EnumerateFrames,frame)
        end
    end
    local fallback
    for tooltip in pairs(hoverTooltips) do
        if Try(tooltip.IsShown,tooltip) then
            local a=ReadHover(tooltip)
            local owner=Try(tooltip.GetOwner,tooltip)
            if a and owner then
                if Try(owner.IsMouseOver,owner) or Try(MouseIsOver,owner) or Try(tooltip.IsMouseOver,tooltip) then return tooltip,a end
                fallback=fallback or {tooltip,a}
            end
        end
    end
    if GameTooltip and GameTooltip:IsShown() then
        local a=ReadHover(GameTooltip);if a then return GameTooltip,a end
    end
    if fallback then return unpack(fallback) end
end
local function ReadPointedEntity()
    local foci = Try(GetMouseFoci)
    if type(foci) ~= "table" then foci = { Try(GetMouseFocus) } end
    local hovered = run.hoverHyperlink
    if hovered and Try(hovered.frame.IsShown, hovered.frame) then
        local over = Try(hovered.frame.IsMouseOver, hovered.frame) or Try(MouseIsOver, hovered.frame)
        for _, focus in ipairs(foci) do if focus == hovered.frame then over = true end end
        if over then
            -- Hover events do not repeat while resting on a link: renew its age
            -- only while this exact link remains under the mouse.
            hovered.attachment.at = GetTime()
            return hovered.attachment
        end
    end
    local tooltip,visible=VisibleHoverTooltip()
    local tipOwner=tooltip and Try(tooltip.GetOwner,tooltip)
    -- The actual pointed frame wins over a tooltip owned by an earlier hover.
    for _, focus in ipairs(foci) do
        local frame, visited = focus, {}
        for depth = 1, 12 do
            if not frame or visited[frame] then break end
            visited[frame] = true
            local attachment = ReadFrameEntity(frame)
            if attachment then
                -- A quest's item button is more specific than its parent block.
                if visible and visited[tipOwner] then
                    if attachment.payload:match("^quest:") or attachment.payload:match("^(%a+:%d+)")==visible.payload:match("^(%a+:%d+)") then return visible end
                end
                return attachment
            end
            frame = FrameValue(frame, "parentBlock") or Try(frame.GetParent, frame)
        end
    end
    if visible and tipOwner and (Try(tipOwner.IsMouseOver, tipOwner) or Try(MouseIsOver, tipOwner)) then return ReadFrameEntity(tipOwner) or visible end
    local tracker = ReadTrackerUnderCursor()
    if tracker then return tracker end
    if tipOwner then return ReadFrameEntity(tipOwner) or visible end
    return visible
end
function WoWAI.AttachHovered(useLast)
    if db.settings.copilotEnabled == false then return end
    local attachment = not useLast and (ReadPointedEntity() or (GameTooltip and GameTooltip:IsShown() and ReadHover(GameTooltip))) or nil
    if useLast then attachment = run.hoverAttachment end
    if not attachment or GetTime() - attachment.at > 30 then
        print("Adventurer's Guide: hover a bag item, spell, or quest row, then press " .. (db.settings.linkKey or "CTRL-ALT-BUTTON3") .. ".")
        return
    end
    run.linkAttachments = run.linkAttachments or {}
    if run.linkAttachments[attachment.payload] == nil then
        local count = 0
        for _ in pairs(run.linkAttachments) do count = count + 1 end
        if count >= 8 then print("Adventurer's Guide: send or clear the current attachments before adding more."); return end
    end
    run.linkAttachments[attachment.payload] = attachment
    WoWAI.Toggle(true)
    local current = ui.input:GetText() or ""
    attachment.name = Display(attachment.name)
    local label = "[" .. attachment.name .. "]"
    if not current:find(label, 1, true) then ui.input:Insert((current ~= "" and " " or "") .. label) end
    if WoWAI.UpdateDraftCards then WoWAI.UpdateDraftCards() end
    -- Focus after the initiating key event, so it cannot become draft text.
    C_Timer.After(0, function() if ui.frame:IsShown() then ui.input:SetFocus() end end)
end
local function CanonicalAttachmentKey(key)
    local modifiers = {}
    local prefix = key:match("^(ALT)%-") or key:match("^(CTRL)%-") or key:match("^(SHIFT)%-")
    while prefix do
        modifiers[prefix] = true
        key = key:sub(#prefix + 2)
        prefix = key:match("^(ALT)%-") or key:match("^(CTRL)%-") or key:match("^(SHIFT)%-")
    end
    return (modifiers.ALT and "ALT-" or "") .. (modifiers.CTRL and "CTRL-" or "") .. (modifiers.SHIFT and "SHIFT-" or "") .. key
end
function WoWAI.ApplyLinkBinding()
    if not ui.linkBindingOwner then return end
    if run.applyingLinkBinding then return end
    if InCombatLockdown() then run.linkBindingPending = true; return end
    run.applyingLinkBinding = true
    run.linkBindingPending = nil
    if type(ClearOverrideBindings) == "function" then ClearOverrideBindings(ui.linkBindingOwner) end
    run.linkKeyActive = nil
    local key = db.settings.linkKey
    if key == "CTRL-ALT-G" then key = "CTRL-ALT-BUTTON3"; db.settings.linkKey = key end
    if key == nil then key = "CTRL-ALT-BUTTON3" end
    if key == "" or db.settings.copilotEnabled == false then run.applyingLinkBinding = nil; return end
    key = CanonicalAttachmentKey(key)
    db.settings.linkKey = key
    local action = Try(GetBindingAction, key, true) or ""
    if action ~= "" and action ~= "CLICK WoWAIHoverAttachButton:LeftButton" then
        print("Adventurer's Guide: " .. key .. " is already bound. Choose a free shortcut with /ai linkkey <key>.")
        run.applyingLinkBinding = nil; return
    end
    if type(SetOverrideBindingClick) == "function" then
        local ok = pcall(SetOverrideBindingClick, ui.linkBindingOwner, true, key, "WoWAIHoverAttachButton", "LeftButton")
        if ok then run.linkKeyActive = key end
    end
    run.applyingLinkBinding = nil
end
local mouseBindingNames = { LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }
function WoWAI.HandleAttachmentMouse(button, down)
    if not down then
        if run.attachmentMouseHeld == button then run.attachmentMouseHeld = nil end
        return
    end
    local key = run.linkKeyActive
    if not key or db.settings.copilotEnabled == false then return end
    if mouseBindingNames[button] ~= key:match("([^%-]+)$") then return end
    if (not not Try(IsControlKeyDown)) ~= (key:find("CTRL-", 1, true) ~= nil)
        or (not not Try(IsAltKeyDown)) ~= (key:find("ALT-", 1, true) ~= nil)
        or (not not Try(IsShiftKeyDown)) ~= (key:find("SHIFT-", 1, true) ~= nil) then return end
    -- UI buttons consume mouse bindings. Global mouse events still arrive;
    -- dispatch once even if the override button also receives this press.
    if run.attachmentMouseHeld then return end
    run.attachmentMouseHeld = button
    WoWAI.AttachHovered(false)
end
local function HookHoverTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        for _, kind in ipairs({ "Item", "Spell" }) do
            local id = Enum.TooltipDataType[kind]
            if id then pcall(TooltipDataProcessor.AddTooltipPostCall, id, WoWAI.RememberHoveredTooltip) end
        end
    elseif GameTooltip and GameTooltip.HookScript then
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", WoWAI.RememberHoveredTooltip)
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetSpell", WoWAI.RememberHoveredTooltip)
    end
end
HookHoverTooltips()

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function MakeButton(parent, label, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	return b
end

local PANEL_W = 150

function WoWAI.ClampChatBounds()
    local f = ui.frame
    if not f or run.clampingChat then return end
    run.clampingChat = true
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    local w, h = f:GetSize()
    w, h = math.max(1, math.min(w, sw)), math.max(1, math.min(h, sh))
    f:SetResizeBounds(math.min(480, sw), math.min(320, sh), sw, sh)
    if w ~= f:GetWidth() or h ~= f:GetHeight() then f:SetSize(w, h) end
    local left, top = f:GetLeft(), f:GetTop()
    if type(left) == "number" and type(top) == "number" then
        local x, y = math.max(0, math.min(left, sw - w)), math.max(h, math.min(top, sh))
        if x ~= left or y ~= top then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y - sh)
        end
    end
    run.clampingChat = nil
end

-- Expand from the launcher's corner; flip corners near screen edges.
function WoWAI.PlaceSideChat()
    local f, m = ui.frame, ui.mini
    if not f or not m then return end
    local left, top = m:GetLeft(), m:GetTop()
    if not left or not top then return end
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    WoWAI.ClampChatBounds()
    local w, h = f:GetSize()
    local x, y
    local s = db.settings
    if s.chatOffsetX and s.chatOffsetY then
        x, y = left + s.chatOffsetX, top + s.chatOffsetY
    else
        x = left + w <= sw and left or left + m:GetWidth() - w
        y = top >= h and top or top - m:GetHeight() + h
    end
    x = math.max(0, math.min(x, math.max(0, sw - w)))
    y = math.max(math.min(h, sh), math.min(y, sh))
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y - sh)
    s.point, s.relPoint, s.x, s.y = "TOPLEFT", "TOPLEFT", x, y - sh
end

local function SaveChatGeometry()
    WoWAI.ClampChatBounds()
    local f, m, s = ui.frame, ui.mini, db.settings
    s.width, s.height = f:GetSize()
    local point, _, relPoint, x, y = f:GetPoint()
    s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
    if m and f:GetLeft() and m:GetLeft() then
        s.chatOffsetX, s.chatOffsetY = f:GetLeft() - m:GetLeft(), f:GetTop() - m:GetTop()
    end
end

function WoWAI.BeginChatResize(axis)
    if run.resize or not GetCursorPosition then return end
    WoWAI.ClampChatBounds()
    local f = ui.frame
    local left, top = f:GetLeft(), f:GetTop()
    if not left or not top then return end
    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    local w, h = f:GetSize()
    run.resize = { axis = axis, x = x / scale, y = y / scale, left = left, top = top, width = w, height = h, scale = scale }
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top - UIParent:GetHeight())
end

function WoWAI.UpdateChatResize()
    local r = run.resize
    if not r then return end
    local x, y = GetCursorPosition()
    local maxW, maxH = UIParent:GetWidth() - r.left, r.top
    local w = r.axis == "height" and r.width or math.max(math.min(480, maxW), math.min(maxW, r.width + x / r.scale - r.x))
    local h = r.axis == "width" and r.height or math.max(math.min(320, maxH), math.min(maxH, r.height + r.y - y / r.scale))
    ui.frame:SetSize(w, h)
end

function WoWAI.EndChatResize()
    if not run.resize then return end
    WoWAI.UpdateChatResize()
    run.resize = nil
    SaveChatGeometry()
end

WoWAI.CopilotModels = { { "gpt-6-luna", "Luna" }, { "gpt-6.1-sol", "Sol 6.1" }, { "gpt-6-astra", "Astra" } }
WoWAI.CopilotEfforts = { "low", "medium", "high", "xhigh", "max" }
function WoWAI.UpdateModelButtons()
    local c = ActiveChat()
    local model, effort = c and c.model or db.settings.model, c and c.effort or db.settings.effort
    local label = model
    for _, entry in ipairs(WoWAI.CopilotModels) do if entry[1] == model then label = entry[2] end end
    if ui.modelButton then ui.modelButton:SetText("Model: " .. label) end
    if ui.effortButton then ui.effortButton:SetText("Effort: " .. effort) end
end

function WoWAI.PositionMinimapButton()
    if not ui.minimapButton or not Minimap or not db then return end
    local radians = (tonumber(db.settings.minimapAngle) or 160) * math.pi / 180
    local rx = (Try(Minimap.GetWidth,Minimap) or 140)/2 + 8
    local ry = (Try(Minimap.GetHeight,Minimap) or 140)/2 + 8
    ui.minimapButton:ClearAllPoints()
    ui.minimapButton:SetPoint("CENTER",Minimap,"CENTER",math.cos(radians)*rx,math.sin(radians)*ry)
end
local function BuildMinimapButton()
    if not Minimap or ui.minimapButton then return end
    local button = CreateFrame("Button","WoWAIMinimapButton",UIParent)
    ui.minimapButton = button
    button:SetSize(32,32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Try(Minimap.GetFrameLevel,Minimap) or 0)+20)
    button:SetClampedToScreen(true)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    local icon = button:CreateTexture(nil,"ARTWORK")
    icon:SetSize(20,20);icon:SetPoint("CENTER",0,1)
    icon:SetTexture("Interface\\AddOns\\WoWAI\\Art\\GuideIcon")
    local border = button:CreateTexture(nil,"OVERLAY")
    border:SetSize(54,54);border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button:SetScript("OnClick",function(self)
        if self.dragging then return end
        if db.settings.copilotEnabled == false then WoWAI.SetEnabled(true) end
        WoWAI.Toggle(true)
    end)
    button:SetScript("OnDragStart",function(self)
        self.dragging = true
        GameTooltip:Hide()
        self:SetScript("OnUpdate",function()
            local x,y = Try(GetCursorPosition)
            local cx,cy = Try(Minimap.GetCenter,Minimap)
            if type(x)~="number" or type(y)~="number" or type(cx)~="number" or type(cy)~="number" then return end
            local scale = Try(Minimap.GetEffectiveScale,Minimap) or 1
            local dx,dy = x/scale-cx,y/scale-cy
            if dx==0 and dy==0 then return end
            local atan = math.atan2 or math.atan
            db.settings.minimapAngle = (atan(dy,dx)*180/math.pi)%360
            WoWAI.PositionMinimapButton()
        end)
    end)
    button:SetScript("OnDragStop",function(self)
        self:SetScript("OnUpdate",nil)
        C_Timer.After(0,function() self.dragging=nil end)
    end)
    button:SetScript("OnEnter",function(self)
        if self.dragging then return end
        GameTooltip:SetOwner(self,"ANCHOR_LEFT")
        GameTooltip:SetText("Adventurer's Guide")
        GameTooltip:AddLine("Click to open your journal. Drag to move this icon.",1,.85,.6,true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave",function() GameTooltip:Hide() end)
    WoWAI.PositionMinimapButton()
    button:Show()
end
local function BuildUI()
	if ui.frame then return end
	local s = db.settings

	local f = CreateFrame("Frame", "WoWAIFrame", UIParent, "BackdropTemplate")
	ui.frame = f
	f:SetSize(s.width, s.height)
	if s.point then
		f:SetPoint(s.point, UIParent, s.relPoint or s.point, s.x or 0, s.y or 0)
	else
		f:SetPoint("CENTER")
	end
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:SetResizable(true)
	f:SetClampedToScreen(true)
	f:SetResizeBounds(math.min(480, UIParent:GetWidth()), math.min(320, UIParent:GetHeight()), UIParent:GetWidth(), UIParent:GetHeight())
	f:HookScript("OnSizeChanged", function() if not run.resize then WoWAI.ClampChatBounds() end end)
	f:SetScript("OnUpdate", function()
		if run.resize then
			if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then WoWAI.EndChatResize() else WoWAI.UpdateChatResize() end
		end
	end)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.point, s.relPoint, s.x, s.y = point, relPoint, x, y
        SaveChatGeometry()
	end)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(0.22, 0.18, 0.13, 0.98)
	f:SetBackdropBorderColor(0.82, 0.68, 0.42, 1)
	f:Hide()
	tinsert(UISpecialFrames, "WoWAIFrame")

	-- Status light: green = bridge seen recently, yellow = stale, red = gone.
	local function MakeDot(parent)
		local holder = CreateFrame("Frame", nil, parent)
		holder:SetSize(16, 16)
		local dot = holder:CreateTexture(nil, "OVERLAY")
		dot:SetAllPoints()
		dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Offline")
		holder:EnableMouse(true)
		holder:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(dot.tip or "Bridge status", 0.9, 0.9, 0.9, 1, true)
			GameTooltip:Show()
		end)
		holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return holder, dot
	end

	local dotHolder, dot = MakeDot(f)
	dotHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -44)
	ui.dot = dot
	local book = f:CreateTexture(nil, "ARTWORK")
	book:SetSize(26, 26)
	book:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -13)
	book:SetTexture("Interface\\AddOns\\WoWAI\\Art\\GuideIcon")

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", book, "TOPRIGHT", 10, -4)
	title:SetPoint("RIGHT", f, "RIGHT", -70, 0)
	title:SetJustifyH("LEFT")
	title:SetText("Adventurer's Guide")
    title:SetWordWrap(false)
	ui.title = title

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.effortButton = MakeButton(f, "Effort: low", 100, function()
        local c = ActiveChat()
        if not c then return end
        local current = c.effort or s.effort
        for i, effort in ipairs(WoWAI.CopilotEfforts) do
            if effort == current then c.effort = WoWAI.CopilotEfforts[i % #WoWAI.CopilotEfforts + 1]; break end
        end
        WoWAI.UpdateModelButtons()
    end)
    ui.effortButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -42)
    ui.modelButton = MakeButton(f, "Model: Sol 6.1", 120, function()
        local c = ActiveChat()
        if not c then return end
        local current = c.model or s.model
        for i, entry in ipairs(WoWAI.CopilotModels) do
            if entry[1] == current then c.model = WoWAI.CopilotModels[i % #WoWAI.CopilotModels + 1][1]; break end
        end
        WoWAI.UpdateModelButtons()
    end)
    ui.modelButton:SetPoint("RIGHT", ui.effortButton, "LEFT", -4, 0)
    for _, button in ipairs({ ui.modelButton, ui.effortButton }) do
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Click to cycle. Saved for this chat; applies to the next message. Luna + low favors speed and lower usage.")
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    WoWAI.UpdateModelButtons()

	status:SetPoint("LEFT", dotHolder, "RIGHT", 6, 0)
	status:SetPoint("RIGHT", ui.modelButton, "LEFT", -12, 0)
	status:SetWordWrap(false)
	status:SetTextColor(0.76, 0.69, 0.56)
	status:SetJustifyH("LEFT")
	ui.status = status

	-- Minimize button in the corner where a close X would be: this window is never
	-- closed from here, only collapsed to the mini bar (Esc does the same, see OnHide).
	-- The mini bar's own X is the one that hides everything.
	local mini
	if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("RedButton-MiniCondense") then
		-- Blizzard's own minimize button: the close button's chrome with a "condense" glyph.
		local ok, b = pcall(CreateFrame, "Button", nil, f, "UIPanelHideButtonNoScripts")
		if ok and b then mini = b end
	end
	if not mini then
		-- Older art: draw a dash on a plain button.
		mini = CreateFrame("Button", nil, f)
		mini:SetSize(24, 24)
		local dash = mini:CreateTexture(nil, "ARTWORK")
		dash:SetSize(10, 2)
		dash:SetPoint("CENTER", mini, "CENTER", 0, -3)
		dash:SetColorTexture(0.9, 0.9, 0.9, 1)
		local hl = mini:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.15)
	end
	mini:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -4)
	mini:SetScript("OnClick", function() WoWAI.Minimize(true) end)
	mini:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Minimize to the small bar  (Esc)")
		GameTooltip:AddLine("Your guide keeps looking; the journal glows when an answer arrives.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local close=CreateFrame("Button","WoWAICloseButton",f,"UIPanelCloseButton")
    close:SetSize(28,28);close:SetPoint("TOPRIGHT",f,"TOPRIGHT",-4,-4)
    close:SetScript("OnClick",function() WoWAI.CloseGuide() end)
    close:SetScript("OnEnter",function(self) GameTooltip:SetOwner(self,"ANCHOR_LEFT");GameTooltip:SetText("Close the guide");GameTooltip:AddLine("Stops requests and hides the journal tab. Type /ai to return.",1,1,1,true);GameTooltip:Show() end)
    close:SetScript("OnLeave",function() GameTooltip:Hide() end)

	-- Esc (via UISpecialFrames) just calls Hide(); treat that as a minimize unless
	-- we're hiding on purpose. Ignore hides caused by the whole UI going away.
	f:SetScript("OnHide", function()
		WoWAI.EndChatResize()
		if ui.quitting then
			ui.quitting = nil
			return
		end
		if not db or not db.settings.shown or not UIParent:IsShown() then return end
		db.settings.minimized = true
		if ui.mini then ui.mini:Show() end
		WoWAI.UpdateMini()
	end)

	-- Left panel: chat list
	local panel = CreateFrame("Frame", nil, f, "BackdropTemplate")
	panel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -76)
	panel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 50)
	panel:SetWidth(PANEL_W)
	panel:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0.12, 0.09, 0.06, 0.7)
	panel:SetBackdropBorderColor(0.55, 0.43, 0.26, 1)

	local newBtn = MakeButton(panel, "+ New chat", PANEL_W - 16, function() WoWAI.NewChat() end)
	newBtn:SetPoint("TOP", panel, "TOP", 0, -8)

	-- Per-chat menu: Rename, Folder and Agent, opened by right-clicking a chat
	-- row. A plain frame of our own rather than a Blizzard dropdown, so it looks
	-- the same on every client.
	local menu = CreateFrame("Frame", "WoWAIChatMenu", f, "BackdropTemplate")
	menu:SetSize(110, 2 * 20 + 12)
	menu:SetFrameStrata("TOOLTIP")
	menu:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	menu:SetBackdropColor(0.08, 0.08, 0.1, 0.97)
	menu:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	menu:EnableMouse(true)
	menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	menu.title:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -8)
	menu.title:SetPoint("RIGHT", menu, "RIGHT", -8, 0)
	menu.title:SetJustifyH("LEFT")
	menu.title:SetWordWrap(false)
	local function MenuItem(label, order, onClick)
		local it = CreateFrame("Button", nil, menu)
		it:SetSize(110 - 12, 20)
		it:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -6 - order * 20)
		local hl = it:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.12)
		it.label = it:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		it.label:SetPoint("LEFT", it, "LEFT", 6, 0)
		it.label:SetText(label)
		it:SetScript("OnClick", function()
			menu:Hide()
			onClick(menu.chatId)
		end)
		return it
	end
	MenuItem("Rename...", 1, WoWAI.RenamePrompt)
	-- Close once the mouse has wandered away from the menu and the row it came from.
	menu:SetScript("OnUpdate", function(self, dt)
		if not MouseIsOver then return end
		if MouseIsOver(self) or (self.owner and MouseIsOver(self.owner)) then
			self.away = 0
		else
			self.away = (self.away or 0) + dt
			if self.away > 0.5 then self:Hide() end
		end
	end)
	menu:Hide()
	ui.chatMenu = menu

	function WoWAI.ShowChatMenu(chatId, anchor)
		local c = FindChat(chatId)
		if not c then return end
		if menu:IsShown() and menu.chatId == chatId then
			menu:Hide()
			return
		end
		menu.chatId = chatId
		menu.owner = anchor
		menu.away = 0
		menu.title:SetText(Display(c.name))
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 8, 2)
		menu:Show()
	end

	ui.chatButtons = {}
	for i = 1, MAX_CHATS do
		local b = CreateFrame("Button", nil, panel)
		b:SetSize(PANEL_W - 16, 20)
		b:SetPoint("TOP", newBtn, "BOTTOM", 0, -6 - (i - 1) * 21)
		b.selected = b:CreateTexture(nil, "BACKGROUND")
		b.selected:SetAllPoints()
		b.selected:SetColorTexture(1, 1, 1, 0.12)
		b.selected:Hide()
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)

		-- Trash can: delete this chat (asks first). Blizzard's red delete button
		-- where the client has it, a plain X elsewhere.
		b.del = CreateFrame("Button", nil, b)
		b.del:SetSize(16, 16)
		b.del:SetPoint("RIGHT", b, "RIGHT", -2, 0)
		if C_Texture and C_Texture.GetAtlasExists and C_Texture.GetAtlasExists("128-RedButton-Delete") then
			b.del:SetNormalAtlas("128-RedButton-Delete")
			b.del:SetPushedAtlas("128-RedButton-Delete-Pressed")
			b.del:SetHighlightAtlas("128-RedButton-Delete-Highlight")
		else
			b.del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
			b.del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
		end
		b.del:SetAlpha(0.6)
		b.del:SetScript("OnClick", function() WoWAI.ConfirmDelete(b.chatId) end)
		b.del:SetScript("OnEnter", function(self)
			self:SetAlpha(1)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Delete this chat")
			GameTooltip:Show()
		end)
		b.del:SetScript("OnLeave", function(self)
			self:SetAlpha(0.6)
			GameTooltip:Hide()
		end)

		b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.label:SetPoint("LEFT", b, "LEFT", 6, 0)
		b.label:SetPoint("RIGHT", b.del, "LEFT", -4, 0)
		b.label:SetJustifyH("LEFT")
		b.label:SetWordWrap(false)
		-- Left-click switches to the chat; right-click opens its menu (Rename,
		-- Folder, Agent). A second right-click on the same row closes the menu again.
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				WoWAI.ShowChatMenu(self.chatId, self)
			else
				WoWAI.SwitchChat(self.chatId)
			end
		end)
		b:SetScript("OnDoubleClick", function(self)
			WoWAI.SwitchChat(self.chatId)
			WoWAI.RenamePrompt(self.chatId)
		end)
		b:Hide()
		ui.chatButtons[i] = b
	end

	-- Transcript: a scrolling stack of message bubbles
	local scroll = CreateFrame("ScrollFrame", "WoWAIScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 0)
	scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 96)
    ui.scroll = scroll
    if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
    scroll.followLatest = true
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel",function(self,delta)
        local range=self:GetVerticalScrollRange()
        local offset=math.max(0,math.min(range,(self.smoothTarget or self:GetVerticalScroll() or 0)-delta*12))
        self.smoothTarget=offset;self.followLatest=range-offset<=3
    end)
    scroll:SetScript("OnUpdate",function(self,elapsed)
        if not self.smoothTarget then return end
        local current=self:GetVerticalScroll() or 0
        local target=math.min(self.smoothTarget,self:GetVerticalScrollRange())
        local offset=current+(target-current)*math.min(1,elapsed*20)
        if math.abs(target-offset)<.25 then offset=target;self.smoothTarget=nil end
        self.smoothing=true;self:SetVerticalScroll(offset);self.smoothing=nil
    end)
    scroll:HookScript("OnVerticalScroll",function(self,offset)
        if not self.smoothing then self.smoothTarget=nil end
        self.userOffset=offset;self.followLatest=self:GetVerticalScrollRange()-offset<=3
    end)

	local content = CreateFrame("Frame", "WoWAIContent", scroll)
	content:SetSize(500, 1)
	scroll:SetScrollChild(content)
	ui.content = content
	ui.bubbles = {}
    local loginButton=MakeButton(content,"Log in to Codex",160,function()
        if db.settings.copilotEnabled==false then WoWAI.SetEnabled(true) end
        db.lastSeq=db.lastSeq+1
        run.outbound[db.lastSeq]={chat="",cwd="",flags="h",name="",text="__COPILOT_LOGIN__",sentAt=GetTime(),hello=true}
        RefreshStrip()
        WoWAI.ShowCopy("First setup: open Interface > AddOns > WoWAI in your Forever game folder.\n\nRun Start Guide.cmd on Windows, or Start Guide.sh on Linux.\n\nClick Sign in to Codex in the setup window. Your own account is used.\n\nIf the companion is already running, its sign-in page opens automatically.")
    end)
    loginButton:Hide();ui.loginButton=loginButton
	scroll:HookScript("OnSizeChanged", function(self, w, h)
		if ui.frame:IsShown() then WoWAI.Render() end
	end)

	-- Input box, with Send docked at its right end like a messaging app.
	local SEND_W = 84
	local inputBg = CreateFrame("Frame", "WoWAIInputBackground", f, "BackdropTemplate")
	inputBg:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14 + PANEL_W + 8, 44)
    inputBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14 - SEND_W - 6, 44)
    inputBg:SetHeight(42)
	inputBg:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	inputBg:SetBackdropColor(0.08, 0.06, 0.04, 0.85)
	inputBg:SetBackdropBorderColor(0.66, 0.51, 0.29, 1)

	local inScroll = CreateFrame("ScrollFrame", "WoWAIInputScroll", inputBg, "UIPanelScrollFrameTemplate")
	inScroll:SetPoint("TOPLEFT", inputBg, "TOPLEFT", 8, -6)
    inScroll:SetPoint("BOTTOMRIGHT", inputBg, "BOTTOMRIGHT", -24, 6)
    inScroll:EnableMouseWheel(true)
    inScroll:SetScript("OnMouseWheel",function(self,delta) self:SetVerticalScroll(math.max(0,math.min(self:GetVerticalScrollRange(),(self:GetVerticalScroll() or 0)-delta*12))) end)

	local input = CreateFrame("EditBox", "WoWAIInput", inScroll)
	input:SetMultiLine(true)
	input:SetAutoFocus(false)
	input:SetFontObject(ChatFontNormal)
	input:SetMaxLetters(0)
    input:SetSize(500, 28)
	input:SetScript("OnEnterPressed", function() WoWAI.SendFromInput() end)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	inScroll:SetScrollChild(input)
	inScroll:HookScript("OnSizeChanged", function(self, w, h)
		input:SetWidth(w)
	end)
	inputBg:SetScript("OnMouseDown", function() input:SetFocus() end)
	ui.input = input

    local draftDeck = CreateFrame("Frame", "WoWAIDraftReferences", f)
    function WoWAI.UpdateDraftCards()
        if not WoWAI.RenderReferenceCards then return end
        local refs = {}
        local text = input:GetText() or ""
        for payload, a in pairs(run.linkAttachments or {}) do
            if text:find("[" .. a.name .. "]", 1, true) then refs[#refs+1] = { kind=payload:match("^(%a+):"),id=tonumber(payload:match("^%a+:(%d+)")),name=a.name,payload=payload } end
        end
        table.sort(refs,function(a,b) return a.payload<b.payload end)
        draftDeck:SetSize(inputBg:GetWidth(),100)
        draftDeck:ClearAllPoints();draftDeck:SetPoint("BOTTOMLEFT",inputBg,"TOPLEFT",0,8)
        WoWAI.RenderReferenceCards(draftDeck,refs,inputBg:GetWidth(),nil,function(ref)
            run.linkAttachments[ref.payload]=nil
            input:SetText((input:GetText() or ""):gsub(("["..ref.name.."]"):gsub("(%W)","%%%1"),""))
            WoWAI.UpdateDraftCards()
        end)
        if draftDeck.referenceDeck then draftDeck.referenceDeck:ClearAllPoints();draftDeck.referenceDeck:SetPoint("TOPLEFT",draftDeck,"TOPLEFT",0,0) end
        draftDeck:SetShown(#refs>0)
        scroll:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-32,44+inputBg:GetHeight()+10+(#refs>0 and 108 or 0))
    end
    input:HookScript("OnTextChanged",function() WoWAI.UpdateDraftCards() end)

	-- Send sits to the right of the input box, vertically centred on it.
	local send = MakeButton(f, "Send", SEND_W, WoWAI.SendFromInput)
	send:SetHeight(30)
	send:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	ui.send = send

	-- Connect stands in for Send until the bridge has been seen (see UpdateConnect).
	local connect = MakeButton(f, "Connect", SEND_W, WoWAI.Connect)
	connect:SetHeight(30)
	connect:SetPoint("LEFT", inputBg, "RIGHT", 6, 0)
	connect:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Open your guide")
		GameTooltip:AddLine("Connect to the companion on your computer. The seal turns green when it is ready.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	connect:SetScript("OnLeave", function() GameTooltip:Hide() end)
	connect:Hide()
	ui.connect = connect

	-- Reload is the fallback transport's button; it sits apart on the right and
	-- only shows when a reload would do something (see UpdateStatus).
	local refresh = MakeButton(f, "Reload", 70, function() SafeReload() end)
	refresh:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 16)
	refresh:Hide()
	ui.refresh = refresh

	-- Bottom row: Clear, plus Resend while a message is in flight. Rename, Folder
	-- and Delete live on each chat row in the left panel.
	local clear = MakeButton(f, "Clear", 60, function()
		local c = ActiveChat()
        if c then wipe(c.history) end
        if ui.scroll then ui.scroll.followLatest=true;ui.scroll.userOffset=0 end
		run.linkAttachments = nil
		WoWAI.Render()
	end)
	clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 16)
	local attach = CreateFrame("Button", "WoWAIAttachButton", f, "UIPanelButtonTemplate")
	attach:SetSize(68, 22)
	attach:SetText("Attach")
	attach:SetPoint("LEFT", clear, "RIGHT", 6, 0)
	attach:SetScript("OnClick", function() WoWAI.AttachHovered(true) end)
	attach:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Attach the last inspected item or spell")
		local a = run.hoverAttachment
		GameTooltip:AddLine(a and GetTime() - a.at <= 30 and a.name or "Hover something in your bags or spellbook first.", 0.85, 0.76, 0.6, true)
		GameTooltip:Show()
	end)
	attach:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- Separate always-visible owner: shortcut works while the journal is minimized.
	ui.linkBindingOwner = CreateFrame("Frame", nil, UIParent)
	ui.linkBindingOwner:SetSize(1, 1)
	ui.linkBindingOwner:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
	local hoverAttach = CreateFrame("Button", "WoWAIHoverAttachButton", ui.linkBindingOwner)
	hoverAttach:SetSize(1, 1)
	hoverAttach:SetAllPoints()
	hoverAttach:RegisterForClicks("AnyDown", "AnyUp")
	hoverAttach:SetScript("OnClick", function(self, button, down)
		-- A complete click may deliver both edges. Attach on press only;
		-- legacy clients without the down argument deliver a single click.
		if down == false then return end
		local mouse = run.linkKeyActive and run.linkKeyActive:match("(BUTTON%d+)$")
		if mouse then
			for name, binding in pairs(mouseBindingNames) do
				if mouse == binding then WoWAI.HandleAttachmentMouse(name, true); return end
			end
		else WoWAI.AttachHovered(false) end
	end)

	local resend = MakeButton(f, "Resend", 70, WoWAI.Resend)
	resend:SetPoint("LEFT", attach, "RIGHT", 6, 0)
	resend:Hide()
	ui.resend = resend

	-- A named, always-present button so a keybinding can click it (see /wow-ai bind).
	local hotkey = CreateFrame("Button", "WoWAIRefreshButton", UIParent)
	hotkey:SetSize(1, 1)
	hotkey:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
	hotkey:SetScript("OnClick", function()
		local c = ActiveChat()
		if c and c.pendingId then
			WoWAI.Send("")
		else
			WoWAI.Toggle()
		end
	end)

	local cwd = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	cwd:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 4)
	cwd:SetPoint("RIGHT", f, "RIGHT", -38, 0)
	cwd:SetJustifyH("LEFT")
	cwd:SetWordWrap(false)
	ui.cwd = cwd

	-- Resize grip (larger target for easier dragging).
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(24, 24)
	grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function() WoWAI.BeginChatResize("both") end)
	grip:SetScript("OnMouseUp", WoWAI.EndChatResize)
	grip:RegisterForDrag("LeftButton")
	grip:SetScript("OnDragStart", function() WoWAI.BeginChatResize("both") end)
	grip:SetScript("OnDragStop", WoWAI.EndChatResize)
	local function ResizeEdge(name, axis, point, relative, w, h)
		local edge = CreateFrame("Button", name, f)
		edge:SetSize(w, h)
		edge:SetPoint(point, f, relative, 0, 0)
		local mark = edge:CreateTexture(nil, "ARTWORK")
		mark:SetSize(axis == "width" and 2 or 28, axis == "width" and 28 or 2)
		mark:SetPoint("CENTER")
		mark:SetColorTexture(0.75, 0.59, 0.32, 0.7)
		edge:SetScript("OnMouseDown", function() WoWAI.BeginChatResize(axis) end)
		edge:SetScript("OnMouseUp", WoWAI.EndChatResize)
		edge:RegisterForDrag("LeftButton")
		edge:SetScript("OnDragStart", function() WoWAI.BeginChatResize(axis) end)
		edge:SetScript("OnDragStop", WoWAI.EndChatResize)
		edge:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(axis == "width" and "Drag to change width" or "Drag to change height")
			GameTooltip:Show()
		end)
		edge:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	ResizeEdge("WoWAIWidthHandle", "width", "RIGHT", "RIGHT", 12, 70)
	ResizeEdge("WoWAIHeightHandle", "height", "BOTTOM", "BOTTOM", 70, 12)

	-- Mini bar: what the window collapses into. Click it to expand, drag to move.
	local m = CreateFrame("Frame", "WoWAIMini", UIParent, "BackdropTemplate")
	ui.mini = m
	m:SetSize(320, 38)
	if s.miniPoint then
		m:SetPoint(s.miniPoint, UIParent, s.miniRelPoint or s.miniPoint, s.miniX or 0, s.miniY or 0)
	else
		m:SetPoint("TOP", UIParent, "TOP", 0, -40)
	end
	m:SetFrameStrata("DIALOG")
	m:SetMovable(true)
	m:SetClampedToScreen(true)
	m:EnableMouse(true)
	m:RegisterForDrag("LeftButton")
	m:SetScript("OnDragStart", function(self)
		self.dragging = true
		self:StartMoving()
	end)
	m:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		s.miniPoint, s.miniRelPoint, s.miniX, s.miniY = point, relPoint, x, y
        s.chatOffsetX, s.chatOffsetY = nil, nil
		WoWAI.PlaceSideChat()
		C_Timer.After(0, function() self.dragging = nil end)
	end)
	m:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" and not self.dragging then
			WoWAI.Minimize(false)
		end
	end)
	m:SetBackdrop(BACKDROP)
	m:SetBackdropColor(0.22, 0.18, 0.13, 0.98)
	m:SetBackdropBorderColor(0.82, 0.68, 0.42, 1)
	m:Hide()

	local miniDotHolder, miniDot = MakeDot(m)
	miniDotHolder:SetPoint("LEFT", m, "LEFT", 9, 0)
	ui.miniDot = miniDot

	local mlabel = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	mlabel:SetPoint("LEFT", miniDotHolder, "RIGHT", 6, 0)
	mlabel:SetText("Adventurer's Guide")

	local badge = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	badge:SetPoint("LEFT", mlabel, "RIGHT", 8, 0)
	badge:SetPoint("RIGHT", m, "RIGHT", -26, 0)
	badge:SetJustifyH("LEFT")
	badge:SetWordWrap(false)
	ui.miniBadge = badge

	local ok, pulse = pcall(function()
		local g = badge:CreateAnimationGroup()
		local a1 = g:CreateAnimation("Alpha")
		a1:SetFromAlpha(1)
		a1:SetToAlpha(0.25)
		a1:SetDuration(0.6)
		a1:SetOrder(1)
		local a2 = g:CreateAnimation("Alpha")
		a2:SetFromAlpha(0.25)
		a2:SetToAlpha(1)
		a2:SetDuration(0.6)
		a2:SetOrder(2)
		g:SetLooping("REPEAT")
		return g
	end)
	if ok then ui.miniPulse = pulse end

	local mclose = CreateFrame("Button", "WoWAIMiniCloseButton", m, "UIPanelCloseButton")
	mclose:SetSize(24, 24)
	mclose:SetPoint("RIGHT", m, "RIGHT", -2, 0)
	mclose:SetScript("OnClick", function() WoWAI.CloseGuide() end)
	mclose:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Close the guide (/ai brings it back)")
		GameTooltip:Show()
	end)
	mclose:SetScript("OnLeave", function() GameTooltip:Hide() end)
    BuildMinimapButton()
end

function WoWAI.Toggle(show)
	if not ui.frame then return end
	if show == nil then show = not ui.frame:IsShown() end
	if show then
        if not ui.frame:IsShown() then WoWAI.PlaceSideChat() end
		db.settings.minimized = false
		local c = ActiveChat()
		if c then c.unread = 0 end
	end
	if ui.mini then ui.mini:Hide() end
	if not show then ui.quitting = true end
	ui.frame:SetShown(show)
	ui.quitting = nil
	db.settings.shown = show
	if show then
		WoWAI.ClampChatBounds()
		WoWAI.Render()
		-- No auto-focus: the game keeps the keyboard until you click the box.
		-- No automatic hello either: if the bridge hasn't been seen, the panel
		-- shows Connect in place of Send and waits for a click.
	end
	WoWAI.UpdateMini()
end

function WoWAI.CloseGuide()
    WoWAI.Toggle(false)
    if ui.copy then ui.copy:Hide() end
    WoWAI.SetEnabled(false)
end
function WoWAI.ShowLauncher()
    if db.settings.copilotEnabled==false then WoWAI.SetEnabled(true) end
    if not ui.frame then return end
    ui.quitting=true;ui.frame:Hide();ui.quitting=nil
    db.settings.minimized=true;db.settings.shown=true
    if ui.mini then ui.mini:Show() end
    WoWAI.UpdateMini()
end

function WoWAI.Minimize(mini)
	if not ui.frame then return end
	if mini == nil then mini = not db.settings.minimized end
	if mini then
		db.settings.minimized = true
		db.settings.shown = true
		ui.frame:Hide() -- OnHide shows the mini bar
		if ui.mini and not ui.mini:IsShown() then ui.mini:Show() end
		WoWAI.UpdateMini()
	else
		WoWAI.Toggle(true)
	end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local HELP = table.concat({
    "Adventurer's Guide — World of Warcraft: Forever",
    "/ai                           bring back the small journal tab",
    "/ai <question>                ask about quests, items, talents or where to go",
    "X closes the guide and stops requests. Minimize keeps the journal tab.",
    "/ai mini                      collapse to the small journal",
    "/ai new [name]                start another conversation",
    "/ai rename [name]             rename this conversation",
    "/ai clear                     clear this conversation",
    "/ai context on|off            share or stop sharing your character details",
    "/ai map                       show route and map options",
    "/ai reload                    refresh the guide if replies stop arriving",
    "Hover an item, spell, or quest and use Ctrl+Alt+middle-click to attach its tooltip.",
    "/ai linkkey <key>|off          choose a free attachment shortcut or disable it",
    "Ask 'Remember that ...', 'What are my saved notes?', or 'Forget ...' to manage your character notebook.",
    "Drag the journal to move it. Drag the right edge for width, bottom edge for height, or corner for both.",
    "Model and Effort buttons change the next reply; choices are saved for each conversation.",
}, "\n")

-- What each subcommand accepts, so that free text which happens to start with
-- one of these words ("delete the unused imports", "help me with this macro")
-- is sent as a message instead of run as a command. 0 = no arguments, 1 = at
-- most one word, a table = one of those words, a function decides, true = anything.
local function OnOffOrNumber(rest)
	return rest == "" or rest == "on" or rest == "off" or tonumber(rest) ~= nil
end

local function ChatArgument(rest)
	if rest == "" or tonumber(rest) or not rest:find("%s") then return true end
	for _, ch in ipairs(db.chats) do
		if ch.name:lower() == rest:lower() then return true end
	end
	return false
end

local COMMAND_ARGS = {
	mini = 0, min = 0, hide = 0, quit = 0, help = 0, clear = 0, delete = 0, reset = 0, copy = 0,
	cancel = 0, resend = 0, reload = 0, refresh = 0, slots = 0, diag = 0,
	context = { [""] = true, on = true, off = true }, ctx = { [""] = true, on = true, off = true },
	mode = { [""] = true, pixel = true, reload = true },
	signal = { [""] = true, on = true, off = true }, longchat = { [""] = true, on = true, off = true },
	auto = OnOffOrNumber,
	echo = function(rest) return rest == "" or rest == "summary" or rest == "full" or rest == "short" or rest == "off" or tonumber(rest) ~= nil end,
	bind = 1, agent = 1, linkkey = 1,
	chat = ChatArgument, chats = ChatArgument,
	cd = true, new = true, rename = true,
	map = true, -- /wow-ai map ...: Map.lua (layers, navigator, herb/ore nodes)
	macro = { undo = true }, -- /wow-ai macro undo; "/ai macro for my warrior" still goes to the agent
}

local function IsCommand(cmd, rest)
	local spec = COMMAND_ARGS[cmd]
	if spec == nil then return false end
	if spec == true then return true end
	if spec == 0 then return rest == "" end
	if spec == 1 then return not rest:find("%s") end
	if type(spec) == "table" then return spec[rest:lower()] == true end
	return spec(rest) == true
end

local function ApplyLongChat()
	local box = ChatFrame1EditBox
	if not box or not box.SetMaxLetters then return end
	box:SetMaxLetters(db.settings.longchat and 4000 or 255)
end

SLASH_WOWAI1 = "/wow-ai"
SLASH_WOWAI2 = "/wowai"
SLASH_WOWAI3 = "/wow-claude" -- the project's old name, kept so old habits and macros still work
SLASH_WOWAI4 = "/ai" -- the short form: /ai <text> sends, /ai agent codex and the rest work too
SLASH_WOWAI5 = "/ask"
SlashCmdList["WOWAI"] = function(msg)
	msg = Trim(msg or "")
	local cmd, rest = msg:match("^(%S+)%s*(.-)$")
	cmd = cmd and cmd:lower() or ""
	local s = db.settings
	local c = ActiveChat()

	-- Anything that isn't a command, or a command word followed by something it
	-- doesn't take, is a message for the agent.
	if cmd ~= "" and not IsCommand(cmd, rest) then
		WoWAI.Send(msg)
		return
	end
	if cmd == "" then
		WoWAI.ShowLauncher()
	elseif cmd == "mini" or cmd == "min" then
		WoWAI.Minimize(true)
	elseif cmd == "new" then
		WoWAI.NewChat(rest)
	elseif cmd == "chat" or cmd == "chats" then
		local n = tonumber(rest)
		local target = n and db.chats[n]
		if not target and rest ~= "" then
			for _, ch in ipairs(db.chats) do
				if ch.name:lower() == rest:lower() then target = ch end
			end
		end
		if target then
			WoWAI.SwitchChat(target.id)
		else
			local lines = {}
			for i, ch in ipairs(db.chats) do
				table.insert(lines, i .. ". " .. ch.name .. (ch.id == db.activeChat and "  (current)" or "") .. (ch.pendingId and "  working" or "") .. ((ch.unread or 0) > 0 and ("  " .. ch.unread .. " new") or ""))
			end
			AddHistory(c, "system", "Chats:\n" .. table.concat(lines, "\n"))
			WoWAI.Render()
		end
		WoWAI.Toggle(true)
	elseif cmd == "rename" then
		if rest ~= "" then
			c.name = rest:sub(1, 24)
			WoWAI.Render()
		else
			WoWAI.RenameActive()
		end
		WoWAI.Toggle(true)
	elseif cmd == "delete" then
		WoWAI.DeleteChat()
	elseif cmd == "cd" then
		WoWAI.SetFolder(rest, c)
		WoWAI.Toggle(true)
	elseif cmd == "map" then
		if WoWAIMap then WoWAIMap.Command(rest) else print("|cff66ccff[WoW AI]|r the map module did not load") end
	elseif cmd == "agent" then
		WoWAI.SetAgent(rest, c)
		WoWAI.Toggle(true)
	elseif cmd == "reset" then
		c.resetNext = true
		local where = ChatFolder(c)
		AddHistory(c, "system", "Next message starts a fresh " .. ChatAgentName(c) .. " session" .. (where ~= "" and (" in " .. where) or ""))
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "context" or cmd == "ctx" then
		rest = rest:lower()
		if rest == "on" or rest == "off" then
			s.context = rest == "on"
			-- Make sure the next record carries the change, hello throttle or not.
			run.contextSent = nil
			run.lastHelloAt = nil
			if WoWAI.IsConnected() then WoWAI.SayHello() end
		end
		local ctx = WoWAI.GameContext()
		AddHistory(c, "system", (s.context
			and "Game context is ON: the agent is told this with each message (it goes into its system prompt, so unrelated projects are unaffected by anything but a few lines). /wow-ai context off to stop.\n\n"
			or "Game context is OFF: the agent is told nothing about the game. /wow-ai context on to send this:\n\n") .. ctx
			.. "\n\nTip: hover a bag item or spellbook spell, then press your attachment shortcut to share its tooltip.")
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "mode" then
		if rest == "pixel" or rest == "reload" then
			s.mode = rest
			AddHistory(c, "system", "mode set to " .. rest)
		else
			AddHistory(c, "system", "mode is " .. s.mode .. " (pixel or reload)")
		end
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "resend" then
		WoWAI.Resend()
	elseif cmd == "auto" then
		local n = tonumber(rest)
		if n then
			s.interval = math.max(5, math.floor(n))
			s.autoRefresh = true
		elseif rest == "on" then
			s.autoRefresh = true
		elseif rest == "off" then
			s.autoRefresh = false
		end
		WoWAI.UpdateStatus()
		WoWAI.ArmAutoRefresh()
	elseif cmd == "hide" or cmd == "quit" then
		WoWAI.Toggle(false)
	elseif cmd == "macro" and rest == "undo" then
		WoWAI.UndoMacro()
	elseif cmd == "copy" then
		for i = #c.history, 1, -1 do
			if c.history[i].role == "assistant" then
				WoWAI.ShowCopy(c.history[i].text)
				break
			end
		end
	elseif cmd == "echo" then
		if rest == "summary" or rest == "full" or rest == "short" or rest == "off" then
			s.echo = rest
		elseif tonumber(rest) then
			s.echo = tostring(math.max(200, math.floor(tonumber(rest))))
		end
		AddHistory(c, "system", "replies in game chat: " .. s.echo .. " (summary = the agent's TL;DR lines, full = " .. ECHO_DEFAULT .. " chars, short, off, or a number of characters)")
		WoWAI.Render()
	elseif cmd == "longchat" then
		if rest == "on" then s.longchat = true elseif rest == "off" then s.longchat = false end
		ApplyLongChat()
		AddHistory(c, "system", "game chat box limit: " .. (s.longchat and "4000 characters (fine for /ai; real chat over 255 may be rejected by the server)" or "255 (default)"))
		WoWAI.Render()
	elseif cmd == "signal" then
		if rest == "on" then s.signal = true elseif rest == "off" then s.signal = false end
		AddHistory(c, "system", "signal check is " .. (s.signal and "on" or "off"))
		WoWAI.Render()
	elseif cmd == "slots" then
		local free = 0
		for i = 1, SLOT_COUNT do
			if not C_AddOns.IsAddOnLoaded(SlotName(i)) then free = free + 1 end
		end
		AddHistory(c, "system", free .. " of " .. SLOT_COUNT .. " reply slots free this session (a reload frees all)")
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "refresh" or cmd == "reload" then
		SafeReload()
	elseif cmd == "bind" then
		local key = rest:upper()
		if key ~= "" and not InCombatLockdown() then
			SetBinding(key, "CLICK WoWAIRefreshButton:LeftButton")
			SaveBindings(GetCurrentBindingSet())
			AddHistory(c, "system", key .. " is now bound: checks for a reply while waiting, otherwise toggles this window")
		end
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "linkkey" then
		if rest ~= "" then
			s.linkKey = rest:lower() == "off" and "" or rest:upper()
			WoWAI.ApplyLinkBinding()
		end
		AddHistory(c, "system", "Attachment shortcut: " .. ((s.linkKey == "") and "off (use Attach)" or (run.linkKeyActive or "unavailable; choose an unused key")))
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "diag" then
		local free = 0
		for i = 1, SLOT_COUNT do
			if not C_AddOns.IsAddOnLoaded(SlotName(i)) then free = free + 1 end
		end
		local lines = {
			"sound channel: " .. (signalAvailable and "usable" or "UNUSABLE") .. " (self-test: " .. tostring(signalStats.selftest) .. ")" .. (signalStats.error and (" error: " .. signalStats.error) or ""),
			"signal setting: " .. tostring(s.signal) .. ", marked unreliable this session: " .. tostring(run.signalUnreliable or false),
			"sound checks: " .. signalStats.checks .. ", valid hits: " .. signalStats.hits .. (signalStats.lastHit and (", last hit " .. FmtDur(GetTime() - signalStats.lastHit) .. " ago") or ""),
			"slot polls this session: " .. (run.polls or 0) .. ", free slots: " .. free .. "/" .. SLOT_COUNT,
			"presence: head at " .. tostring(run.presence and run.presence.last or "?") .. ", beats seen: " .. tostring(run.presence and run.presence.beats or 0),
			select(5, WoWAI.BridgeState()),
			"mode: " .. s.mode .. ", session token: " .. tostring(db.session),
		}
		for _, ch in ipairs(db.chats) do
			local a = run.act and run.act[ch.id]
			if ch.pendingId then
				table.insert(lines, ch.name .. ": pending #" .. ch.pendingId .. (a and (", heartbeat " .. (a.unreliable and "unreliable" or (a.count .. " beats"))) or ", no heartbeat state"))
			end
		end
		AddHistory(c, "system", "Diagnostics:\n" .. table.concat(lines, "\n"))
		WoWAI.Render()
		WoWAI.Toggle(true)
	elseif cmd == "cancel" then
		if c.pendingId then
			AddHistory(c, "system", "Gave up waiting on #" .. c.pendingId)
			run.outbound[c.pendingId] = nil
			if run.act then run.act[c.id] = nil end
			c.pendingId = nil
			c.progress = nil
			RefreshStrip()
			if not AnyPending() then keyCatcher:Hide() end
		end
		WoWAI.Render()
	elseif cmd == "clear" then
		wipe(c.history)
		WoWAI.Render()
	elseif cmd == "help" then
		AddHistory(c, "system", HELP)
		WoWAI.Render()
		WoWAI.Toggle(true)
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("DISPLAY_SIZE_CHANGED")
ev:RegisterEvent("UI_SCALE_CHANGED")
ev:RegisterEvent("UPDATE_BINDINGS")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_TALENT_UPDATE")
ev:RegisterEvent("GLOBAL_MOUSE_DOWN")
ev:RegisterEvent("GLOBAL_MOUSE_UP")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("UPDATE_MACROS")
ev:RegisterEvent("CHAT_MSG_WHISPER")
ev:RegisterEvent("CHAT_MSG_BN_WHISPER")
ev:RegisterEvent("ADDON_ACTION_BLOCKED")
ev:RegisterEvent("ADDON_ACTION_FORBIDDEN")
ev:SetScript("OnEvent", function(self, event, arg1, arg2)
	if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if db and arg1 == ADDON_NAME then db.lastBlockedAction={action=tostring(arg2 or "unknown"),at=time(),event=event} end
    elseif event == "ADDON_LOADED" then
		WoWAI.HookChatLinks()
        if arg1 == ADDON_NAME then
			InitDB()
		end
	elseif event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER" then
		-- A real person whispered: /r belongs to them again.
		run.lastMessenger = "player"
	elseif event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
		if ui.frame then SaveChatGeometry() end
        WoWAI.PositionMinimapButton()
	elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "PLAYER_LEVEL_UP" or event == "PLAYER_TALENT_UPDATE" then
        run.contextSent = nil
        C_Timer.After(1,function() WoWAI.QueueSnapshot(true) end)
	elseif event == "UPDATE_BINDINGS" then
		WoWAI.ApplyLinkBinding()
	elseif event == "GLOBAL_MOUSE_DOWN" or event == "GLOBAL_MOUSE_UP" then
		WoWAI.HandleAttachmentMouse(arg1, event == "GLOBAL_MOUSE_DOWN")
	elseif event == "PLAYER_LOGIN" then
		if not db then InitDB() end
		BuildMinimapButton()
		BuildUI()
		run = { outbound = {} }
		WoWAI.HookChatLinks()
		WoWAI.ApplyLinkBinding()
		SelfTestSignals()
		ProcessInbox()
		if AnyPending() then
			-- Still waiting after a reload: resume polling with a fresh slot pool.
			run.sentAt = GetTime()
			run.polls = 0
			run.act = {}
			for _, ch in ipairs(db.chats) do
				if ch.pendingId then
					-- Beats already written stay valid, so the counter catches up on its own.
					run.act[ch.id] = { next = 1, count = 0, startedAt = GetTime() }
				end
			end
			ScheduleNextPoll()
		end
		local c = ActiveChat()
		if c and c.draft and c.draft ~= "" then
			ui.input:SetText(c.draft)
			if not c.pendingId then c.draft = nil end
		end
		WoWAI.Render()
		if db.settings.shown then
			if db.settings.minimized then
				WoWAI.Minimize(true)
			else
				WoWAI.Toggle(true)
			end
		end
		WoWAI.ArmAutoRefresh()
		WoWAI.UpdateDot()
		if db.settings.longchat then ApplyLongChat() end
		C_Timer.NewTicker(TICK_SECONDS, Tick)
		C_Timer.After(3, WoWAI.SayHello)
	elseif event == "UPDATE_MACROS" then
		-- "Create" / "Update" on the macro buttons follows what exists now.
		if ui.frame and ui.frame:IsShown() then WoWAI.Render() end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if run.linkBindingPending then WoWAI.ApplyLinkBinding() end
		if WoWAI.reloadAfterCombat then
			WoWAI.reloadAfterCombat = nil
			ReloadUI()
		elseif db then
			WoWAI.ArmAutoRefresh()
		end
	end
end)
