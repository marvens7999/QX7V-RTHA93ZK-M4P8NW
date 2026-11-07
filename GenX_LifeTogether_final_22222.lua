--[[
	GenX | Life Together v5.0 (Dreamville GUI, Life Together features)
	Roblox / Delta (mobile, landscape) | Luau | single file
	Backend removed: no billboard/tags sync, no remote loaders. Features tab buttons and auto-launch are wired to the Life Together engine.
	Server hop reads Roblox's public server list (games.roblox.com) to find a server with exactly 27 players.
	Settings > Copy Avatar Logs: records every Copy Avatar step (time, run, level, step) locally; nothing is sent anywhere.
]]

-- ============================================================================
-- 1. CONSTANTS, SERVICES, GAME LOCK
-- ============================================================================
local VERSION = "GenX | Life Together v6.7.4"
local SPECTATE_MAX_DISTANCE = 150 -- studs; farther than this and Spectate refuses
local DREAMVILLE_PLACE_ID = 13967668166
local CONFIG_FILE = "genx_dreamville_config.json"

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local TextChatService = game:GetService("TextChatService")
local HapticService = game:GetService("HapticService")
local AES = game:GetService("AvatarEditorService")
local StarterGui = game:GetService("StarterGui")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService") -- JSON only, never used for requests
local SoundService = game:GetService("SoundService")
local CoreGui = game:GetService("CoreGui")
local LP = Players.LocalPlayer
local G = (getgenv and getgenv()) or _G

-- a previous run cleans up first (also covers the loader re-running us)
if G.GENX_DV_STOP then pcall(G.GENX_DV_STOP) end
G.GENX_DV_STOP = nil

if game.PlaceId ~= DREAMVILLE_PLACE_ID then
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "GenX",
			Text = "GenX | Life Together only works in Life Together RP",
			Duration = 5,
		})
	end)
	return
end

-- Gen-X OWNER billboard: loaded from GitHub (no billboard code lives in this file)
task.spawn(function()
	local ok, err = pcall(function()
		loadstring(game:HttpGet("https://raw.githubusercontent.com/marvens7999/Life-tg-billboard-/refs/heads/main/GenX%20Owner%20Billboard.lua"))()
	end)
	if not ok then
		pcall(function()
			StarterGui:SetCore("SendNotification", { Title = "GenX", Text = "Billboard failed to load: " .. tostring(err), Duration = 6 })
		end)
	end
end)

-- ============================================================================
-- 2. MAID / CLEANUP
-- ============================================================================
local dead = false
local conns, insts, cleanups = {}, {}, {}

local function keep(c) conns[#conns + 1] = c return c end
local function track(i) insts[#insts + 1] = i return i end
local function onClean(fn) cleanups[#cleanups + 1] = fn end

-- ============================================================================
-- 3. (logging removed)
-- ============================================================================
local t0, curRun, runCounter = os.clock(), 0, 0
local function log() end

local function short(v, n)
	local s
	if typeof(v) == "table" then
		n = n or 160
		local parts, c = {}, 0
		for k, val in pairs(v) do
			c += 1
			if c > 8 then parts[#parts + 1] = "..." break end
			local vs = (typeof(val) == "table") and "{...}" or tostring(val)
			if #vs > 50 then vs = vs:sub(1, 50) .. "~" end
			parts[#parts + 1] = tostring(k) .. "=" .. vs
		end
		s = "{" .. table.concat(parts, ", ") .. "}"
	else
		n = n or 70
		s = tostring(v)
	end
	if #s > n then s = s:sub(1, n) .. "..." end
	return s
end

-- ============================================================================
-- 4. CAPABILITY DETECTION + CONTEXT
-- ============================================================================
local CAP = {
	gethui = typeof(gethui) == "function",
	writefile = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function",
	clipboard = typeof(setclipboard) == "function",
	qot = typeof(queue_on_teleport) == "function",
	idexec = typeof(identifyexecutor) == "function",
}
local EXECUTOR = "Unknown"
if CAP.idexec then
	local ok, a = pcall(identifyexecutor)
	if ok and a then EXECUTOR = tostring(a) end
end

local CTX = (typeof(G.GENX_CTX) == "table") and G.GENX_CTX or nil
-- placeholder: no hosted link (backend removed). Auto-launch stays off until one is added.
CAP.selfUrl = "" -- placeholder: no hosted loader link (backend removed)

local function copyText(s)
	if not CAP.clipboard then return false end
	return (pcall(setclipboard, s))
end

log("info", string.format("%s | executor=%s | place=%s | job=%s | gethui=%s writefile=%s clip=%s qot=%s ctx=%s",
	VERSION, EXECUTOR, tostring(game.PlaceId), tostring(game.JobId):sub(1, 8),
	tostring(CAP.gethui), tostring(CAP.writefile), tostring(CAP.clipboard), tostring(CAP.qot), tostring(CTX ~= nil)))

-- ============================================================================
-- 5. CONFIG (auto-saves, loads on start)
-- ============================================================================
local cfg = {
	theme = "Midnight",
	playIntro = true,
	joinAlerts = true,
	leaveAlerts = true,
	haptics = true,
	sound = true,
	volume = 0.5,
	uiScale = 0.82,
	opacity = 0.92,
	fps = true,
	antiAfk = false,
	autoRejoin = false,
	lowGfx = false,
	muteGame = false,
	unlockZoom = false,
	autoExec = false,
	btnX = -1, btnY = -1, -- -1 = default spot
	recent = {},
	chatCmds = true, -- run commands typed in the game chat (needs an executor that can intercept chat)
	prefix = ";",
	antiSteal = false, -- Anti Outfit Stealer switch (Quick Commands)
	billboard = true, -- show billboards (Settings). Off: nobody sees yours and you see none
	tutorialV2 = false, -- first-run walkthrough finished
	autoLaunch = true, -- relaunch GenX after rejoin / every Dreamville join (Settings switch)
	alNotified = false, -- the one-time "auto-launch is on" notice was shown
	copyLogs = true, -- Settings > Copy Avatar Logs: record every Copy Avatar step
	copyLogsFile = false, -- also write the log to genx_copy_logs_latest.txt after every copy
	firstRun = 0, runs = 0, -- who this user is on this device: first launch time + launch count
}

local function cfgLoad()
	if not CAP.writefile then return end
	local ok, raw = pcall(function()
		if isfile(CONFIG_FILE) then return readfile(CONFIG_FILE) end
	end)
	if not ok or not raw then return end
	local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if ok2 and type(data) == "table" then
		for k, v in pairs(data) do
			if cfg[k] ~= nil and typeof(v) == typeof(cfg[k]) then cfg[k] = v end
		end
	end
end

local saveQueued = false
local function cfgSave()
	if not CAP.writefile or dead or saveQueued then return end
	saveQueued = true
	task.delay(0.8, function()
		saveQueued = false
		pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(cfg)) end)
	end)
end
cfgLoad()
onClean(function()
	if CAP.writefile then pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(cfg)) end) end
end)

-- ============================================================================
-- 5b. COPY AVATAR LOGGER
-- Only the Copy Avatar engine writes here. Settings > Copy Avatar Logs shows, filters, copies and saves it.
-- Every entry keeps: wall-clock time (to the millisecond), seconds since its run started, level, run number, step, message.
-- ============================================================================
do
	local CL = {
		entries = {}, runs = {}, runOrder = {}, listeners = {},
		counts = { ok = 0, info = 0, warn = 0, fail = 0 },
		seq = 0, MAX = 2500, lastEnd = nil, pending = nil,
	}
	CAP.CL = CL
	local LV = { ok = "ok", info = "info", warn = "warn", fail = "fail", err = "fail", fe = "warn" }
	local LABEL = { ok = "OK", info = "INFO", warn = "WARN", fail = "FAIL" }
	local WORD = {
		retry = "RETRY", scale = "SCALE", color = "COLOR", verify = "VERIFY", wipe = "PLAN", diff = "PLAN", target = "PLAN",
		removeaccessories = "REMOVE", fallback = "REMOVE", unequip = "UNEQUIP", cancelled = "CANCEL", done = "DONE",
		revealed = "REVEAL", movement = "ANIM", you = "ANIM", game = "GAME", avatar = "REMOTES", item = "DETAILS",
		reading = "READ", waiting = "WAIT", waited = "WAIT", apply = "ERROR", leftovers = "SWEEP", sweep = "SWEEP",
		face = "FIX", head = "FIX", all = "VERIFY", switching = "QUEUE", logging = "LOG", remote = "REMOTE",
	}
	local function catOf(msg)
		local up = msg:match("^(%u[%u_]+)[%s:]")
		if up then return up end
		local c1 = msg:sub(1, 2)
		if c1 == "+ " then return "EQUIP" elseif c1 == "- " then return "UNEQUIP" end
		local w = msg:lower():match("^%s*(%a+)")
		return (w and WORD[w]) or "INFO"
	end
	local function nowMs()
		local sec, ms = os.time(), 0
		pcall(function()
			local t = DateTime.now().UnixTimestampMillis
			sec, ms = math.floor(t / 1000), math.floor(t % 1000)
		end)
		return sec, ms
	end
	function CL.stampOf(sec, ms, h12)
		if h12 then return os.date("%I:%M:%S", sec) .. string.format(".%03d", ms) .. os.date(" %p", sec) end
		return os.date("%H:%M:%S", sec) .. string.format(".%03d", ms)
	end
	local function notify(kind, a)
		for _, fn in ipairs(CL.listeners) do pcall(fn, kind, a) end
	end

	-- level: ok / info / warn / fail (err and fe are mapped), msg: text, cat: optional step name (derived from the text when nil)
	function CL.add(level, msg, cat)
		if cfg.copyLogs == false then return end
		msg = tostring(msg)
		local lv = LV[level] or "info"
		local run = (curRun ~= 0 and curRun) or CL.pending or 0
		local pc = msg:match("^POSTCHECK r(%d+)") -- the delayed post-check belongs to the run it checks
		if pc then run = tonumber(pc) or run end
		local sec, ms = nowMs()
		local r = CL.runs[run]
		CL.seq += 1
		local e = {
			id = CL.seq, lv = lv, level = LABEL[lv], msg = msg, cat = cat or catOf(msg), run = run,
			sec = sec, ms = ms, up = os.clock() - t0, rel = r and (os.clock() - r.t0) or nil,
		}
		CL.counts[lv] += 1
		if r then
			r.n += 1
			if lv == "warn" then r.warns += 1 elseif lv == "fail" then r.fails += 1 end
		end
		local list = CL.entries
		list[#list + 1] = e
		local n = #list
		if n > CL.MAX + 100 then -- drop the oldest 100 at once instead of one by one
			table.move(list, 101, n, 1)
			for i = n - 99, n do list[i] = nil end
		end
		notify("entry", e)
		return e
	end

	function CL.beginRun(no, plr)
		CL.pending = no
		if cfg.copyLogs == false then return end
		local sec, ms = nowMs()
		CL.runs[no] = { no = no, name = plr.DisplayName, user = plr.Name, uid = plr.UserId, sec = sec, ms = ms, t0 = os.clock(), status = "running", warns = 0, fails = 0, n = 0 }
		CL.runOrder[#CL.runOrder + 1] = no
		if #CL.runOrder > 60 then CL.runs[table.remove(CL.runOrder, 1)] = nil end
		notify("run", CL.runs[no])
	end

	function CL.endRun(no, status, rej)
		CL.pending = nil
		CL.lastEnd = os.clock()
		local r = CL.runs[no]
		if not r then return end
		r.status, r.dur, r.rejected = status, os.clock() - r.t0, rej or 0
		notify("run", r)
		if cfg.copyLogsFile then
			task.delay(3, function() -- after the delayed post-check has written its lines
				if not dead then CL.save(true) end
			end)
		end
	end

	function CL.clear()
		CL.entries, CL.runs, CL.runOrder = {}, {}, {}
		CL.counts = { ok = 0, info = 0, warn = 0, fail = 0 }
		notify("clear")
	end

	function CL.line(e)
		return string.format("[%s] [%s] [%-4s] [%s] [%s] %s", CL.stampOf(e.sec, e.ms),
			e.rel and string.format("+%.2fs", e.rel) or "  --  ", e.level, e.run > 0 and ("r" .. e.run) or "--", e.cat, e.msg)
	end

	function CL.runLine(r)
		return string.format("RUN #%d | %s (@%s, id=%d) | started %s | %s | %.2fs | warn=%d fail=%d | lines=%d%s",
			r.no, r.name, r.user, r.uid, CL.stampOf(r.sec, r.ms), r.status:upper(), r.dur or (os.clock() - r.t0), r.warns, r.fails, r.n,
			(r.rejected and r.rejected > 0) and (" | server rejected " .. r.rejected) or "")
	end

	-- full text export (header, one summary line per run, then every line); pred filters the lines
	function CL.text(pred)
		local c = CL.counts
		local out = {
			"=== GenX Copy Avatar Logs ===",
			VERSION,
			string.format("Executor: %s | Place: %s | Job: %s", EXECUTOR, tostring(game.PlaceId), tostring(game.JobId)),
			string.format("Player: %s (@%s, id=%d)", LP.DisplayName, LP.Name, LP.UserId),
			"Exported: " .. os.date("%Y-%m-%d %H:%M:%S"),
			string.format("Entries: %d | Runs: %d | OK %d | INFO %d | WARN %d | FAIL %d", #CL.entries, #CL.runOrder, c.ok, c.info, c.warn, c.fail),
			"",
		}
		for _, no in ipairs(CL.runOrder) do
			local r = CL.runs[no]
			if r then out[#out + 1] = CL.runLine(r) end
		end
		out[#out + 1] = ""
		out[#out + 1] = "Line format: [clock time] [seconds since the run started] [level] [run] [step] message"
		for _, e in ipairs(CL.entries) do
			if not pred or pred(e) then out[#out + 1] = CL.line(e) end
		end
		return table.concat(out, "\n")
	end

	function CL.save(auto)
		if not CAP.writefile then return false, "this executor can't write files" end
		local name = auto and "genx_copy_logs_latest.txt" or ("genx_copy_logs_" .. os.date("%Y%m%d_%H%M%S") .. ".txt")
		local ok, err = pcall(writefile, name, CL.text())
		return ok, ok and name or tostring(err)
	end

	CL.add("info", string.format("SESSION %s | executor=%s | place=%s | job=%s | player=%s (@%s)",
		VERSION, EXECUTOR, tostring(game.PlaceId), tostring(game.JobId):sub(1, 8), LP.DisplayName, LP.Name), "SESSION")
	CL.add("info", "v1.1.5: game HUD is restored after Unfollow, continuous waypoint search, low graphics while scanning, scale learn mode", "SESSION")
end

-- ============================================================================
-- 5c. ERROR RECORDER (whole script)
-- From here on, everything that goes wrong lands in the same log (Settings > Copy Avatar Logs), with where it happened:
--   PCALL    a pcall that failed (soft failures: the script kept going)       ERROR    an xpcall that failed, or any script error nobody caught
--   GAME_ERR an error raised by a game script, not by us                        CONSOLE  an error line the Roblox console printed
--   TOAST    every warning / error toast the UI showed
-- Repeats collapse: the first 2 are printed in full, then every 25th with a counter, so a loop can't flood the log.
-- ============================================================================
CAP.CL.rawPcall, CAP.CL.rawXpcall = pcall, xpcall
local pcall, xpcall
do
	local CL = CAP.CL
	local rp, rx = CL.rawPcall, CL.rawXpcall
	local seen, nSeen, inRec, saveQueued = {}, 0, false, false
	local recent, recentN = {}, 0 -- last uncaught error texts, so the console copy of the same error is not logged twice

	local function where(f)
		if type(f) ~= "function" then return "?" end
		local ok, src, line, name = rp(debug.info, f, "sln")
		if not ok then return "?" end
		src = tostring(src or "?")
		if #src > 40 then src = src:sub(1, 40) .. "~" end
		return string.format("%s%s:%s", (name and name ~= "") and (name .. " @ ") or "", src, tostring(line or "?"))
	end

	-- repeats: the first 2 are printed in full, then at most one summary line per key every 15s ("N more since the last line")
	local SELF_SRC = tostring(debug.info(1, "s") or "")
	local function record(level, cat, text, key)
		if inRec or dead then return end
		key = key or (cat .. text:sub(1, 160))
		local rec = seen[key]
		local now = os.clock()
		if not rec then
			nSeen += 1
			if nSeen > 3000 then seen, nSeen = {}, 1 end
			rec = { n = 0, last = 0, held = 0 }
			seen[key] = rec
		end
		rec.n += 1
		if rec.n > 2 then
			if now - rec.last < 15 then rec.held += 1 return end
			text = text .. string.format("  (+%d more since the last line, %d total)", rec.held, rec.n)
			rec.held = 0
		end
		rec.last = now
		inRec = true
		rp(function()
			local m = #text > 700 and (text:sub(1, 700) .. "~") or text
			CL.add(level, m, cat)
			if cfg.copyLogsFile and not saveQueued then -- errors outside a copy run still reach the saved log file
				saveQueued = true
				task.delay(2, function()
					saveQueued = false
					if not dead then rp(CL.save, true) end
				end)
			end
		end)
		inRec = false
	end
	CL.record = record

	local function after(f, ok, ...)
		if not ok then
			local e = tostring((...))
			record("warn", "PCALL", string.format("pcall failed in %s: %s", where(f), e), "P" .. e:sub(1, 160))
		end
		return ok, ...
	end
	pcall = function(f, ...) return after(f, rp(f, ...)) end

	xpcall = function(f, h, ...)
		return rx(f, function(e)
			local s = tostring(e)
			record("fail", "ERROR", string.format("xpcall error in %s: %s", where(f), s), "X" .. s:sub(1, 160))
			if h then return h(e) end
			return e
		end, ...)
	end

	-- anything that throws with no pcall around it (event handlers, task.spawn / delay / defer threads, loops)
	rp(function()
		local SC = game:GetService("ScriptContext")
		keep(SC.Error:Connect(function(msg, trace, scr)
			msg = tostring(msg)
			recentN = recentN % 12 + 1
			recent[recentN] = msg
			local tr = tostring(trace or ""):gsub("%s*\n%s*", " | ")
			if #tr > 360 then tr = tr:sub(1, 360) .. "~" end
			if scr then
				local sn = "?"
				rp(function() sn = scr:GetFullName() end)
				record("warn", "GAME_ERR", string.format("game script %s: %s | %s", sn, msg, tr), "G" .. msg:sub(1, 160))
			elseif SELF_SRC ~= "" and msg:find(SELF_SRC, 1, true) == 1 then
				record("fail", "ERROR", string.format("GenX script error: %s | %s", msg, tr), "U" .. msg:sub(1, 160))
			else
				record("warn", "OTHER_SCRIPT", string.format("error in another executor script (not GenX): %s | %s", msg, tr), "O" .. msg:sub(1, 160))
			end
		end))
	end)
	rp(function()
		keep(game:GetService("LogService").MessageOut:Connect(function(message, mtype)
			if mtype ~= Enum.MessageType.MessageError then return end
			message = tostring(message)
			if SELF_SRC ~= "" and message:find(SELF_SRC, 1, true) == 1 then return end -- our own errors are logged once, by ScriptContext.Error
			for _, r in pairs(recent) do if r ~= "" and message:find(r, 1, true) then return end end
			record("warn", "CONSOLE", "console error: " .. message, "C" .. message:sub(1, 160))
		end))
	end)
end

-- ============================================================================
-- 6. UI HELPERS
-- ============================================================================
local function mk(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function tw(inst, t, props, style, dir)
	if not inst or not inst.Parent then return end
	local tween = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	tween:Play()
	return tween
end

local function round(parent, r) return mk("UICorner", { CornerRadius = UDim.new(0, r or 14) }, parent) end

local function pad(parent, l, t, r, b)
	return mk("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0), PaddingTop = UDim.new(0, t or l or 0),
		PaddingRight = UDim.new(0, r or l or 0), PaddingBottom = UDim.new(0, b or t or l or 0),
	}, parent)
end

local function fmtClock()
	return os.date("%H:%M")
end
local function fmtDuration(s)
	s = math.max(0, math.floor(s))
	local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
	if h > 0 then return string.format("%dh %02dm", h, m) end
	return string.format("%dm %02ds", m, s % 60)
end

-- ============================================================================
-- 7. THEMES (every themed instance is registered, switching recolors live)
-- ============================================================================
local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
local THEMES = {
	Midnight = { bg = rgb(10, 12, 20), card = rgb(20, 24, 38), stroke = rgb(46, 54, 80), text = rgb(236, 240, 252), muted = rgb(168, 178, 206), accent = rgb(96, 140, 255), accent2 = rgb(150, 110, 255), ok = rgb(90, 220, 150), warn = rgb(255, 205, 90), err = rgb(255, 110, 120) },
	Crimson  = { bg = rgb(16, 8, 10), card = rgb(32, 16, 20), stroke = rgb(84, 38, 46), text = rgb(252, 238, 240), muted = rgb(206, 170, 177), accent = rgb(235, 64, 82), accent2 = rgb(255, 120, 90), ok = rgb(90, 220, 150), warn = rgb(255, 205, 90), err = rgb(255, 140, 140) },
	Ocean    = { bg = rgb(6, 14, 22), card = rgb(12, 28, 42), stroke = rgb(30, 66, 92), text = rgb(232, 246, 252), muted = rgb(158, 194, 214), accent = rgb(40, 190, 230), accent2 = rgb(60, 120, 240), ok = rgb(90, 220, 170), warn = rgb(255, 205, 90), err = rgb(255, 110, 120) },
	Violet   = { bg = rgb(14, 8, 22), card = rgb(28, 18, 44), stroke = rgb(70, 48, 108), text = rgb(244, 236, 254), muted = rgb(192, 172, 224), accent = rgb(166, 98, 255), accent2 = rgb(236, 100, 220), ok = rgb(90, 220, 150), warn = rgb(255, 205, 90), err = rgb(255, 110, 130) },
	Emerald  = { bg = rgb(6, 16, 12), card = rgb(12, 30, 24), stroke = rgb(30, 72, 56), text = rgb(232, 252, 242), muted = rgb(156, 206, 184), accent = rgb(40, 210, 130), accent2 = rgb(120, 230, 90), ok = rgb(110, 240, 160), warn = rgb(255, 205, 90), err = rgb(255, 110, 120) },
	Mono     = { bg = rgb(10, 10, 10), card = rgb(24, 24, 24), stroke = rgb(60, 60, 60), text = rgb(244, 244, 244), muted = rgb(178, 178, 178), accent = rgb(236, 236, 236), accent2 = rgb(170, 170, 170), ok = rgb(150, 230, 170), warn = rgb(240, 210, 120), err = rgb(240, 130, 130) },
}
local THEME_ORDER = { "Midnight", "Crimson", "Ocean", "Violet", "Emerald", "Mono" }

if CTX and typeof(CTX.theme) == "table" then
	local ok, a1 = pcall(Color3.fromHex, tostring(CTX.theme.accent or ""))
	local ok2, a2 = pcall(Color3.fromHex, tostring(CTX.theme.accent2 or ""))
	if ok and ok2 then
		local t = table.clone(THEMES.Midnight)
		t.accent, t.accent2 = a1, a2
		THEMES.Server = t
		THEME_ORDER[#THEME_ORDER + 1] = "Server"
	end
end
if not THEMES[cfg.theme] then cfg.theme = "Midnight" end

local themeReg, themeHooks = {}, {}
local function T() return THEMES[cfg.theme] end

-- themed(inst, { BackgroundColor3 = "card", ... }) registers and applies once
local function themed(inst, map)
	themeReg[#themeReg + 1] = { inst = inst, map = map }
	local th = T()
	for prop, key in pairs(map) do inst[prop] = th[key] end
	return inst
end
local function onTheme(fn, inst) themeHooks[#themeHooks + 1] = { fn = fn, inst = inst } fn(T(), false) end

local function applyTheme(name, animate)
	if not THEMES[name] then return end
	cfg.theme = name
	cfgSave()
	local th, alive = THEMES[name], {}
	for _, e in ipairs(themeReg) do
		if e.inst and e.inst.Parent then
			alive[#alive + 1] = e
			for prop, key in pairs(e.map) do
				if animate then tw(e.inst, 0.25, { [prop] = th[key] }, Enum.EasingStyle.Sine) else e.inst[prop] = th[key] end
			end
		end
	end
	themeReg = alive
	local hooks = {}
	for _, h in ipairs(themeHooks) do
		if not h.inst or h.inst.Parent then
			hooks[#hooks + 1] = h
			pcall(h.fn, th, animate)
		end
	end
	themeHooks = hooks
end


-- ============================================================================
-- 7b. ICON SET (vector icons built from frames: crisp at any scale, theme-aware)
-- ============================================================================
local Icon = (function()
	local I, DEFS = {}, {}

	local function build(parent, px, defFn)
		local s = px / 24
		local th = math.max(1.4, 2 * s)
		local root = mk("Frame", { Size = UDim2.fromOffset(px, px), BackgroundTransparency = 1, BorderSizePixel = 0 }, parent)
		local parts, cur, b = {}, root, {}
		function b.bar(x1, y1, x2, y2)
			local dx, dy = x2 - x1, y2 - y1
			local f = mk("Frame", {
				Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) * s + th, th), AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset((x1 + x2) / 2 * s, (y1 + y2) / 2 * s), Rotation = math.deg(math.atan2(dy, dx)), BorderSizePixel = 0,
			}, cur)
			mk("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
			parts[#parts + 1] = { f = f }
		end
		function b.dot(x, y, d)
			local f = mk("Frame", { Size = UDim2.fromOffset(d * s, d * s), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x * s, y * s), BorderSizePixel = 0 }, cur)
			mk("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
			parts[#parts + 1] = { f = f }
		end
		function b.ring(x, y, w, h, r)
			local f = mk("Frame", {
				Size = UDim2.fromOffset(w * s - th, h * s - th), Position = UDim2.fromOffset(x * s + th / 2, y * s + th / 2),
				BackgroundTransparency = 1, BorderSizePixel = 0,
			}, cur)
			mk("UICorner", { CornerRadius = UDim.new(0, (r or 0) * s) }, f)
			parts[#parts + 1] = { st = mk("UIStroke", { Thickness = th, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f) }
		end
		function b.clip(x, y, w, h)
			cur = mk("Frame", { Size = UDim2.fromOffset(w * s, h * s), Position = UDim2.fromOffset(x * s, y * s), BackgroundTransparency = 1, ClipsDescendants = true, BorderSizePixel = 0 }, root)
		end
		function b.unclip() cur = root end
		defFn(b)
		return root, parts
	end

	local function eye(b) b.ring(2, 6, 20, 12, 6) b.dot(12, 12, 5) end
	local function arrowUp(b) b.bar(12, 20, 12, 4) b.bar(6, 10, 12, 4) b.bar(18, 10, 12, 4) end

	DEFS.home = function(b) b.bar(3, 12, 12, 4) b.bar(12, 4, 21, 12) b.bar(6, 11, 6, 20) b.bar(18, 11, 18, 20) b.bar(6, 20, 18, 20) b.bar(12, 20, 12, 15) end
	DEFS.terminal = function(b) b.ring(2, 4, 20, 16, 4) b.bar(7, 9, 11, 12) b.bar(11, 12, 7, 15) b.bar(13, 15.5, 17, 15.5) end
	DEFS.sliders = function(b)
		b.bar(3, 7, 21, 7) b.bar(3, 12, 21, 12) b.bar(3, 17, 21, 17)
		b.dot(8, 7, 5) b.dot(16, 12, 5) b.dot(11, 17, 5)
	end
	DEFS.bell = function(b) b.ring(2, 3, 20, 14, 5) b.bar(7, 17, 7, 21.5) b.bar(7, 21.5, 12, 17) b.dot(8, 10, 2.6) b.dot(12, 10, 2.6) b.dot(16, 10, 2.6) end
	DEFS.discord = function(b) b.ring(3, 3, 21, 16, 6) b.dot(9, 10, 1.8) b.dot(15, 10, 1.8) b.bar(7.5, 16, 7.5, 19.5) b.bar(16.5, 16, 16.5, 19.5) end
	DEFS.wave = function(b) b.bar(4, 10, 4, 14) b.bar(8, 7, 8, 17) b.bar(12, 4, 12, 20) b.bar(16, 7, 16, 17) b.bar(20, 10, 20, 14) end
	DEFS.person = function(b) b.ring(8, 3, 8, 8, 4) b.clip(4, 14, 16, 7) b.ring(0, 0, 16, 14, 7) b.unclip() end
	DEFS.personPlus = function(b)
		b.ring(3, 3, 8, 8, 4) b.clip(0, 14, 14, 7) b.ring(0, 0, 14, 14, 7) b.unclip()
		b.bar(18, 6, 18, 13) b.bar(14.5, 9.5, 21.5, 9.5)
	end
	DEFS.eye = eye
	DEFS.eyeOff = function(b) eye(b) b.bar(4, 20, 20, 4) end
	DEFS.noclip = function(b)
		b.bar(4, 9, 4, 4) b.bar(4, 4, 9, 4) b.bar(15, 4, 20, 4) b.bar(20, 4, 20, 9)
		b.bar(20, 15, 20, 20) b.bar(20, 20, 15, 20) b.bar(9, 20, 4, 20) b.bar(4, 20, 4, 15)
		b.dot(12, 12, 4)
	end
	DEFS.fly = arrowUp
	DEFS.arrowD = function(b) b.bar(12, 4, 12, 20) b.bar(6, 14, 12, 20) b.bar(18, 14, 12, 20) end
	DEFS.float = function(b) b.ring(6, 3, 12, 12, 6) b.bar(7, 19, 17, 19) b.bar(10, 22, 14, 22) end
	DEFS.jump = function(b) b.bar(6, 11, 12, 5) b.bar(18, 11, 12, 5) b.bar(6, 19, 12, 13) b.bar(18, 19, 12, 13) end
	DEFS.sun = function(b)
		b.ring(7, 7, 10, 10, 5)
		for i = 0, 7 do
			local a = i * math.pi / 4
			b.bar(12 + math.cos(a) * 7.5, 12 + math.sin(a) * 7.5, 12 + math.cos(a) * 10.5, 12 + math.sin(a) * 10.5)
		end
	end
	DEFS.target = function(b)
		b.ring(5, 5, 14, 14, 7) b.dot(12, 12, 3)
		b.bar(12, 1.5, 12, 5) b.bar(12, 19, 12, 22.5) b.bar(1.5, 12, 5, 12) b.bar(19, 12, 22.5, 12)
	end
	DEFS.film = function(b) b.ring(3, 5, 18, 14, 3) b.bar(10, 9, 15, 12) b.bar(15, 12, 10, 15) b.bar(10, 9, 10, 15) end
	DEFS.camera = function(b) b.ring(2, 7, 20, 13, 3) b.ring(8.5, 10, 7, 7, 3.5) b.bar(8, 4.5, 11, 4.5) end
	DEFS.mute = function(b)
		b.bar(3, 10, 3, 14) b.bar(3, 10, 7, 10) b.bar(3, 14, 7, 14) b.bar(7, 10, 12, 6) b.bar(7, 14, 12, 18) b.bar(12, 6, 12, 18)
		b.bar(16, 9, 21, 15) b.bar(21, 9, 16, 15)
	end
	DEFS.check = function(b) b.bar(5, 12, 10, 17) b.bar(10, 17, 19, 7) end
	DEFS.cross = function(b) b.bar(6, 6, 18, 18) b.bar(18, 6, 6, 18) end
	DEFS.info = function(b) b.dot(12, 6.5, 3) b.bar(12, 11, 12, 18) end
	DEFS.warn = function(b) b.bar(12, 5, 12, 14) b.dot(12, 19, 3) end
	DEFS.plus = function(b) b.bar(12, 5, 12, 19) b.bar(5, 12, 19, 12) end
	DEFS.minus = function(b) b.bar(5, 12, 19, 12) end
	DEFS.send = function(b) b.bar(4, 12, 20, 12) b.bar(14, 6, 20, 12) b.bar(14, 18, 20, 12) end
	DEFS.chevR = function(b) b.bar(9, 5, 16, 12) b.bar(16, 12, 9, 19) end
	DEFS.chevL = function(b) b.bar(15, 5, 8, 12) b.bar(8, 12, 15, 19) end
	DEFS.play = function(b) b.bar(8, 5, 8, 19) b.bar(8, 5, 19, 12) b.bar(8, 19, 19, 12) end
	DEFS.tp = function(b) b.ring(5, 2, 14, 14, 7) b.dot(12, 9, 4) b.bar(7.5, 14.5, 12, 22) b.bar(16.5, 14.5, 12, 22) end
	DEFS.follow = function(b)
		b.dot(6, 5.5, 5) b.bar(6, 9, 6, 16) b.bar(6, 16, 3, 21.5) b.bar(6, 16, 9, 21.5) b.bar(2.5, 11.5, 9.5, 11.5)
		b.bar(13, 6, 17, 12) b.bar(17, 12, 13, 18) b.bar(18, 6, 22, 12) b.bar(22, 12, 18, 18)
	end
	DEFS.role = function(b) b.ring(2, 5, 20, 14, 3) b.ring(6, 8.5, 5, 5, 2.5) b.bar(5.5, 16, 11.5, 16) b.bar(14, 10, 18, 10) b.bar(14, 14, 18, 14) end

	DEFS.car = function(b) b.ring(2, 10, 20, 8, 3) b.bar(6, 10, 9, 5) b.bar(9, 5, 15, 5) b.bar(15, 5, 18, 10) b.dot(7, 19, 4.5) b.dot(17, 19, 4.5) end
	DEFS.rainbow = function(b) b.clip(2, 6, 20, 11) b.ring(0, 0, 20, 20, 10) b.ring(4, 4, 12, 12, 6) b.ring(8, 8, 4, 4, 2) b.unclip() end
	DEFS.troll = function(b) b.ring(3, 3, 18, 18, 9) b.dot(9, 10, 3) b.dot(15, 10, 3) b.bar(8, 15, 12, 18) b.bar(12, 18, 16, 15) end
	DEFS.lock = function(b) b.ring(5, 11, 14, 10, 3) b.bar(8, 11, 8, 7) b.bar(16, 11, 16, 7) b.bar(8, 7, 16, 7) b.dot(12, 16, 2.5) end

	-- Icon.new(parent, name, px, color [Color3 or theme key], zIndex?) -> { frame, color(c3), alpha(n) }
	function I.new(parent, name, px, color, z)
		local root, parts = build(parent, px or 20, DEFS[name] or function(b) b.dot(12, 12, 6) end)
		local obj = { frame = root }
		function obj.color(c)
			for _, p in ipairs(parts) do
				if p.f then p.f.BackgroundColor3 = c else p.st.Color = c end
			end
		end
		function obj.alpha(a)
			for _, p in ipairs(parts) do
				if p.f then p.f.BackgroundTransparency = a else p.st.Transparency = a end
			end
		end
		if z then
			root.ZIndex = z
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("GuiObject") then d.ZIndex = z end
			end
		end
		if typeof(color) == "string" then
			onTheme(function(t) obj.color(t[color]) end, root)
		else
			obj.color(color or Color3.new(1, 1, 1))
		end
		return obj
	end
	return I
end)()


-- ============================================================================
-- 7c. ICON EXTENSIONS (same Icon.new signature; new names fall through to a mirror of the 7b builder)
-- ============================================================================
do
	local EXT = {}
	local function ib(parent, px, defFn)
		local s = px / 24
		local th = math.max(1.4, 2 * s)
		local root = mk("Frame", { Size = UDim2.fromOffset(px, px), BackgroundTransparency = 1, BorderSizePixel = 0 }, parent)
		local parts, cur, b = {}, root, {}
		function b.bar(x1, y1, x2, y2)
			local dx, dy = x2 - x1, y2 - y1
			local f = mk("Frame", {
				Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) * s + th, th), AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset((x1 + x2) / 2 * s, (y1 + y2) / 2 * s), Rotation = math.deg(math.atan2(dy, dx)), BorderSizePixel = 0,
			}, cur)
			mk("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
			parts[#parts + 1] = { f = f }
		end
		function b.dot(x, y, d)
			local f = mk("Frame", { Size = UDim2.fromOffset(d * s, d * s), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x * s, y * s), BorderSizePixel = 0 }, cur)
			mk("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
			parts[#parts + 1] = { f = f }
		end
		function b.ring(x, y, w, h, r)
			local f = mk("Frame", { Size = UDim2.fromOffset(w * s - th, h * s - th), Position = UDim2.fromOffset(x * s + th / 2, y * s + th / 2), BackgroundTransparency = 1, BorderSizePixel = 0 }, cur)
			mk("UICorner", { CornerRadius = UDim.new(0, (r or 0) * s) }, f)
			parts[#parts + 1] = { st = mk("UIStroke", { Thickness = th, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f) }
		end
		function b.clip(x, y, w, h)
			cur = mk("Frame", { Size = UDim2.fromOffset(w * s, h * s), Position = UDim2.fromOffset(x * s, y * s), BackgroundTransparency = 1, ClipsDescendants = true, BorderSizePixel = 0 }, root)
		end
		function b.unclip() cur = root end
		defFn(b)
		return root, parts
	end

	EXT.bolt = function(b) b.bar(14, 3, 6, 13) b.bar(6, 13, 12, 13) b.bar(12, 13, 10, 21) b.bar(10, 21, 18, 10) b.bar(18, 10, 12, 10) b.bar(12, 10, 14, 3) end
	EXT.users = function(b) b.ring(3, 4, 8, 8, 4) b.clip(0, 15, 14, 7) b.ring(0, 0, 14, 14, 7) b.unclip() b.ring(14, 7, 6, 6, 3) b.clip(13, 15, 9, 6) b.ring(0, 0, 9, 9, 4.5) b.unclip() end
	EXT.clock = function(b) b.ring(3, 3, 18, 18, 9) b.bar(12, 7, 12, 12) b.bar(12, 12, 16, 14) end
	EXT.signal = function(b) b.bar(5, 19, 5, 15) b.bar(10, 19, 10, 11) b.bar(15, 19, 15, 7) b.bar(20, 19, 20, 3) end
	EXT.search = function(b) b.ring(3, 3, 12, 12, 6) b.bar(14, 14, 20, 20) end
	EXT.grid = function(b) b.ring(3, 3, 7, 7, 2) b.ring(14, 3, 7, 7, 2) b.ring(3, 14, 7, 7, 2) b.ring(14, 14, 7, 7, 2) end
	EXT.moon = function(b) b.ring(4, 4, 15, 15, 7.5) b.ring(9, 1.5, 12, 12, 6) end
	EXT.chevU = function(b) b.bar(5, 15, 12, 8) b.bar(12, 8, 19, 15) end
	EXT.chevD = function(b) b.bar(5, 9, 12, 16) b.bar(12, 16, 19, 9) end
	EXT.trash = function(b) b.bar(4, 6, 20, 6) b.bar(9, 6, 9, 3) b.bar(9, 3, 15, 3) b.bar(15, 3, 15, 6) b.ring(6, 8, 12, 13, 2) end
	EXT.reset = function(b) b.ring(4, 4, 16, 16, 8) b.bar(17, 2, 20, 6) b.bar(20, 6, 15, 7) end
	EXT.swap = function(b) b.bar(4, 8, 19, 8) b.bar(15, 4, 19, 8) b.bar(15, 12, 19, 8) b.bar(20, 16, 5, 16) b.bar(9, 12, 5, 16) b.bar(9, 20, 5, 16) end
	EXT.link = function(b) b.ring(2, 8, 12, 8, 4) b.ring(10, 8, 12, 8, 4) b.bar(9, 12, 15, 12) end
	EXT.copy = function(b) b.ring(3, 3, 13, 13, 3) b.ring(8, 8, 13, 13, 3) end
	EXT.chip = function(b)
		b.ring(6, 6, 12, 12, 3) b.dot(12, 12, 4)
		b.bar(10, 3, 10, 6) b.bar(14, 3, 14, 6) b.bar(10, 18, 10, 21) b.bar(14, 18, 14, 21)
		b.bar(3, 10, 6, 10) b.bar(3, 14, 6, 14) b.bar(18, 10, 21, 10) b.bar(18, 14, 21, 14)
	end
	EXT.gear = function(b)
		b.ring(7, 7, 10, 10, 5)
		for i = 0, 7 do
			local a = i * math.pi / 4
			b.bar(12 + math.cos(a) * 7, 12 + math.sin(a) * 7, 12 + math.cos(a) * 10, 12 + math.sin(a) * 10)
		end
	end
	EXT.filter = function(b) b.bar(3, 5, 21, 5) b.bar(3, 5, 10, 13) b.bar(21, 5, 14, 13) b.bar(10, 13, 10, 20) b.bar(14, 13, 14, 20) end
	EXT.grip = function(b) b.dot(8, 7, 3) b.dot(16, 7, 3) b.dot(8, 12, 3) b.dot(16, 12, 3) b.dot(8, 17, 3) b.dot(16, 17, 3) end
	EXT.shield = function(b) b.bar(12, 3, 4, 6) b.bar(12, 3, 20, 6) b.bar(4, 6, 4, 13) b.bar(20, 6, 20, 13) b.bar(4, 13, 12, 21) b.bar(20, 13, 12, 21) end
	EXT.navHome = function(b)
		b.clip(5, 10, 14, 11) b.ring(1, -8, 12, 18.5, 3.5) b.unclip()
		b.bar(3, 11.5, 12, 4) b.bar(12, 4, 21, 11.5)
		b.ring(9.5, 13.5, 5, 7.5, 2)
	end
	EXT.navAvatar = function(b)
		b.ring(4.5, 3, 9, 9, 4.5)
		b.clip(2, 15, 15, 6.5) b.ring(0, 0, 15, 13, 6.5) b.unclip()
		b.bar(19.5, 5.5, 19.5, 11.5) b.bar(16.5, 8.5, 22.5, 8.5)
	end
	EXT.navTroll = function(b)
		b.ring(2.5, 2.5, 19, 19, 9.5)
		b.dot(9, 10, 2.6) b.dot(15, 10, 2.6)
		b.clip(7, 13.5, 10, 5) b.ring(0, -4.5, 10, 9, 4.5) b.unclip()
	end
	EXT.navSettings = function(b)
		b.ring(5, 5, 14, 14, 7) b.ring(9, 9, 6, 6, 3)
		for i = 0, 7 do
			local a = i * math.pi / 4
			b.bar(12 + math.cos(a) * 8.6, 12 + math.sin(a) * 8.6, 12 + math.cos(a) * 10.8, 12 + math.sin(a) * 10.8)
		end
	end
	EXT.palette = function(b) b.ring(3, 3, 18, 18, 9) b.dot(8, 9, 3) b.dot(13, 7, 3) b.dot(16.5, 11.5, 3) b.dot(10, 15, 3) end

	local baseNew = Icon.new
	function Icon.new(parent, name, px, color, z)
		local def = EXT[name]
		if not def then return baseNew(parent, name, px, color, z) end
		local root, parts = ib(parent, px or 20, def)
		local obj = { frame = root }
		function obj.color(c) for _, p in ipairs(parts) do if p.f then p.f.BackgroundColor3 = c else p.st.Color = c end end end
		function obj.alpha(a) for _, p in ipairs(parts) do if p.f then p.f.BackgroundTransparency = a else p.st.Transparency = a end end end
		if z then
			root.ZIndex = z
			for _, d in ipairs(root:GetDescendants()) do if d:IsA("GuiObject") then d.ZIndex = z end end
		end
		if typeof(color) == "string" then onTheme(function(t) obj.color(t[color]) end, root) else obj.color(color or Color3.new(1, 1, 1)) end
		return obj
	end
	Icon.ext = EXT
end

-- ============================================================================
-- 8. SCREEN GUI ROOT + SCALING
-- ============================================================================
local SOUND_ID = "rbxassetid://6895079853" -- short ping; swap here if it ever goes silent
local WIN_W, WIN_H = 780, 400 -- legacy names, the overlay now fills the screen

local H = {} -- late-bound hooks the shell fills in (shake, pulse, badge, onTab, editBar)
local UI = { glass = {}, tabs = {}, curTab = nil, cards = {}, reg = {}, state = "closed", editing = false, chrome = {} }
-- a UIStroke on a CanvasGroup is not covered by GroupTransparency: it stayed on screen as an empty outline when the card was hidden
function H.fadeStroke(cg, stroke, base)
	local function sync() stroke.Transparency = base + (1 - base) * math.clamp(cg.GroupTransparency, 0, 1) end
	cg:GetPropertyChangedSignal("GroupTransparency"):Connect(sync)
	sync()
end

-- NEW cfg keys (UI preferences only). cfgLoad runs again so saved values for them are picked up:
--   accent "" | blur 0.4 | hapticStrength 0.7 | compact false | rememberTab true | lastTab "Home" | dnd false | wLayout {} | friendAlerts true
do
	local d = { accent = "", blur = 0.4, hapticStrength = 0.7, compact = false, rememberTab = true, lastTab = "Home", dnd = false, wLayout = {}, friendAlerts = true, hideHud = true }
	for k, v in pairs(d) do if cfg[k] == nil then cfg[k] = v end end
	cfgLoad()
end

local gui = mk("ScreenGui", {
	Name = "GenXDV" .. tostring(math.random(1000, 9999)),
	ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 2147483647,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
do
	local parent
	if CAP.gethui then
		local ok, h = pcall(gethui)
		if ok and h then parent = h end
	end
	gui.Parent = parent or CoreGui
end
track(gui)
onClean(function() pcall(function() gui:Destroy() end) end)

local cam = workspace.CurrentCamera
local function viewport() return (workspace.CurrentCamera or cam).ViewportSize end
local function fitScale()
	local vp = viewport()
	return math.clamp(math.min(vp.X / 700, vp.Y / 330), 0.5, 1.6)
end
-- final overlay scale: fit * user scale * compact, never narrower than 720 virtual px
function UI.scaleNow()
	local vp = viewport()
	local s = fitScale() * cfg.uiScale * (cfg.compact and 0.88 or 1)
	return math.max(0.4, math.min(s, vp.X / 720))
end

-- accent override: recolors every theme live (cfg.accent = hex, "" = theme default)
do
	local base = {}
	function UI.setAccent(c, silent)
		for name, th in pairs(THEMES) do
			base[name] = base[name] or { th.accent, th.accent2 }
			if c then
				local h, s, v = c:ToHSV()
				th.accent, th.accent2 = c, Color3.fromHSV((h + 0.07) % 1, math.clamp(s * 0.9, 0, 1), v)
			else
				th.accent, th.accent2 = base[name][1], base[name][2]
			end
		end
		cfg.accent = c and c:ToHex() or ""
		if not silent then applyTheme(cfg.theme, true) end
	end
	UI.ACCENTS = { "5C8CFF", "A662FF", "EB4052", "28D282", "28BEE6", "FFB020", "FF6FB5", "EDEDED" }
	if cfg.accent ~= "" then pcall(function() UI.setAccent(Color3.fromHex(cfg.accent), true) end) end
end


-- ============================================================================
-- 9. THUMBNAILS (cached, never blocks)
-- ============================================================================
local thumbCache = {}
local function thumb(userId, kind, cb)
	kind = kind or "HeadShot"
	local key = kind .. userId
	if thumbCache[key] then cb(thumbCache[key]) return end
	task.spawn(function()
		local ok, img = pcall(function()
			local c, ready = Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType[kind],
				kind == "HeadShot" and Enum.ThumbnailSize.Size100x100 or Enum.ThumbnailSize.Size150x150)
			return c
		end)
		if ok and img then
			thumbCache[key] = img
			if not dead then cb(img) end
		end
	end)
end


-- ============================================================================
-- 10. HAPTICS (honest: real vibration is rare, the visual fallback always plays)
-- ============================================================================
local function haptic(strength)
	if not cfg.haptics or dead then return end
	strength = math.clamp((strength or 0.6) * (cfg.hapticStrength / 0.7), 0.05, 1)
	pcall(function()
		local pad1 = Enum.UserInputType.Gamepad1
		if HapticService:IsVibrationSupported(pad1) and HapticService:IsMotorSupported(pad1, Enum.VibrationMotor.Small) then
			HapticService:SetMotor(pad1, Enum.VibrationMotor.Small, strength)
			task.delay(0.12, function() pcall(function() HapticService:SetMotor(pad1, Enum.VibrationMotor.Small, 0) end) end)
		end
	end)
	if H.shake then pcall(H.shake, strength) end -- visual fallback: tiny overlay shake
	if H.pulse then pcall(H.pulse, strength) end -- and the emblem pulses
end

-- ============================================================================
-- 11. NOTIFICATIONS (centered glass toasts + history)
-- ============================================================================
local notifSound = mk("Sound", { SoundId = SOUND_ID, Volume = cfg.volume, Name = "GenXPing" }, gui)
local function refreshVolume() notifSound.Volume = cfg.sound and cfg.volume or 0 end
refreshVolume()

local N = { history = {}, unread = 0, active = {}, seq = 0 }
N.scale = mk("UIScale", { Scale = math.clamp(fitScale() * 0.95, 0.7, 1.3) })
N.stack = mk("Frame", {
	Name = "Toasts", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -26),
	Size = UDim2.fromOffset(270, 300), BackgroundTransparency = 1, ZIndex = 80,
}, gui)
N.scale.Parent = N.stack
mk("UIListLayout", {
	Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom,
}, N.stack)

-- toasts sit at the bottom of the screen, just above the nav bar while the menu is on, lower when it is closed
function N.place()
	local lift = (UI.state and UI.state ~= "closed") and 78 or 26
	pcall(function() tw(N.stack, 0.45, { Position = UDim2.new(0.5, 0, 1, -lift) }, Enum.EasingStyle.Quint) end)
end

local KIND_STYLE = {
	ok = { icon = "check", key = "ok" }, warn = { icon = "warn", key = "warn" }, err = { icon = "cross", key = "err" },
	info = { icon = "info", key = "accent" }, join = { icon = "plus", key = "ok" }, leave = { icon = "minus", key = "muted" },
	friend = { icon = "users", key = "accent2" },
}

function N.dismiss(t, dir)
	if t.gone then return end
	t.gone = true
	for i, v in ipairs(N.active) do if v == t then table.remove(N.active, i) break end end
	tw(t.inner, 0.26, { GroupTransparency = 1, Position = UDim2.fromOffset(dir and dir * 90 or 0, dir and 0 or 12) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	task.delay(0.14, function() if t.wrap.Parent then tw(t.wrap, 0.3, { Size = UDim2.fromOffset(256, 0) }, Enum.EasingStyle.Quint) end end)
	task.delay(0.5, function() pcall(function() t.wrap:Destroy() end) end)
end

-- (re)start a toast's life: progress line + auto dismiss. dur >= 60 means sticky
function N.arm(t, dur)
	t.tok = (t.tok or 0) + 1
	local my = t.tok
	dur = dur or t.dur or 3.2
	t.dur = dur
	if t.twn then t.twn:Cancel() end
	t.bar.Size = UDim2.new(1, -44, 0, 2)
	if dur >= 60 then t.bar.Visible = false return end
	t.bar.Visible = true
	t.twn = tw(t.bar, dur, { Size = UDim2.new(0, 0, 0, 2) }, Enum.EasingStyle.Linear)
	task.delay(dur, function() if t.tok == my and not t.gone and not dead then N.dismiss(t) end end)
end

-- toast(kind, title, body, opts): opts.userId headshot, opts.silent no haptic/sound, opts.noHistory,
--   opts.duration seconds, opts.buttons = { {text=, primary=, fn=, keep=} } (returns the toast record, rec.dismiss())
local function toast(kind, title, body, opts)
	if dead then return end
	opts = opts or {}
	if kind == "err" or kind == "warn" then -- every warning / error the UI shows is also written to the log
		pcall(CAP.CL.add, kind == "err" and "fail" or "warn", tostring(title) .. ": " .. tostring(body), "TOAST")
	end
	local st = KIND_STYLE[kind] or KIND_STYLE.info
	if not opts.noHistory then
		local top = N.history[1]
		if top and top.kind == kind and top.title == title and top.body == body and os.time() - top.at < 30 then
			top.count = (top.count or 1) + 1
			top.at = os.time()
		else
			table.insert(N.history, 1, { kind = kind, title = title, body = body, at = os.time(), userId = opts.userId, count = 1 })
			if #N.history > 40 then table.remove(N.history) end
		end
		N.unread += 1
		if H.badge then pcall(H.badge) end
		if N.onNew then pcall(N.onNew) end
	end
	if cfg.dnd and kind ~= "err" then return end -- do not disturb: history only

	-- repeats collapse into one toast with an "x3" counter
	if not opts.buttons then
		for _, t in ipairs(N.active) do
			if not t.gone and not t.buttons and t.kind == kind and t.title == title and t.body == body then
				t.count += 1
				t.cnt.Text = "x" .. t.count
				t.cnt.Visible = true
				t.sc.Scale = 1.07
				tw(t.sc, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
				N.arm(t, opts.duration)
				return t
			end
		end
	end

	N.seq += 1
	N.place()
	local btns = opts.buttons
	local fullH = btns and 84 or 46
	-- the slot grows open first (older toasts glide up), the card fades and rises into it
	local wrap = mk("Frame", { Size = UDim2.fromOffset(256, 0), BackgroundTransparency = 1, LayoutOrder = N.seq }, N.stack)
	local inner = mk("CanvasGroup", { Size = UDim2.fromOffset(256, fullH), Position = UDim2.fromOffset(0, 20), GroupTransparency = 1, BorderSizePixel = 0, ZIndex = 81 }, wrap)
	themed(inner, { BackgroundColor3 = "card" })
	inner.BackgroundTransparency = 0.12
	round(inner, btns and 18 or 23)
	local stroke = mk("UIStroke", { Thickness = 1.2, Transparency = 0.45 }, inner)
	themed(stroke, { Color = st.key })
	UI.sheen(inner)
	local sc = mk("UIScale", { Scale = 1 }, inner)
	local rec = { wrap = wrap, inner = inner, sc = sc, kind = kind, title = title, body = body, count = 1, buttons = btns }
	rec.dismiss = function() N.dismiss(rec) end

	local ic = mk("Frame", { Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(8, 8), BorderSizePixel = 0, ZIndex = 82 }, inner)
	themed(ic, { BackgroundColor3 = st.key })
	ic.BackgroundTransparency = 0.78
	round(ic, 15)
	local glyph = Icon.new(ic, st.icon, 16, st.key, 83).frame
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	if opts.userId then
		local img = mk("ImageLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 84 }, ic)
		round(img, 15)
		glyph.Visible = false
		thumb(opts.userId, "HeadShot", function(c) if img.Parent then img.Image = c end end)
	end
	local ttl = mk("TextLabel", {
		Position = UDim2.fromOffset(46, 6), Size = UDim2.new(1, -100, 0, 17), BackgroundTransparency = 1, Text = title or "",
		Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 82,
	}, inner)
	themed(ttl, { TextColor3 = "text" })
	local bd = mk("TextLabel", {
		Position = UDim2.fromOffset(46, 23), Size = UDim2.new(1, -66, 0, 14), BackgroundTransparency = 1, Text = body or "",
		Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 82,
	}, inner)
	themed(bd, { TextColor3 = "muted" })
	rec.cnt = mk("TextLabel", {
		Size = UDim2.fromOffset(30, 16), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), BackgroundTransparency = 1,
		Text = "x2", Visible = false, Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 82,
	}, inner)
	themed(rec.cnt, { TextColor3 = st.key })
	rec.bar = mk("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 22, 1, -4), Size = UDim2.new(1, -44, 0, 2), BorderSizePixel = 0, ZIndex = 83 }, inner)
	themed(rec.bar, { BackgroundColor3 = st.key })
	round(rec.bar, 1)

	-- tap or swipe sideways to dismiss (sits under the action buttons)
	local tap = mk("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 81 }, inner)
	local startX
	tap.InputBegan:Connect(function(i) if UI.isPress(i) then startX = i.Position.X end end)
	tap.InputChanged:Connect(function(i)
		if startX and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
			local dx = i.Position.X - startX
			inner.Position = UDim2.fromOffset(dx, 0)
			inner.GroupTransparency = math.clamp(math.abs(dx) / 200, 0, 0.8)
		end
	end)
	tap.InputEnded:Connect(function(i)
		if not startX then return end
		local dx = i.Position.X - startX
		startX = nil
		if math.abs(dx) > 50 then N.dismiss(rec, dx > 0 and 1 or -1)
		elseif math.abs(dx) < 6 then N.dismiss(rec)
		else tw(inner, 0.25, { Position = UDim2.new(), GroupTransparency = 0 }, Enum.EasingStyle.Quint) end
	end)

	if btns then
		local row = mk("Frame", { Position = UDim2.fromOffset(12, 46), Size = UDim2.new(1, -24, 0, 32), BackgroundTransparency = 1, ZIndex = 85 }, inner)
		mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, row)
		for _, b in ipairs(btns) do
			local bt = UI.button(row, b.text, b.primary, UDim2.new(1 / #btns, -4, 1, 0), function()
				if b.fn then pcall(b.fn) end
				if not b.keep then N.dismiss(rec) end
			end, true)
			bt.ZIndex = 86
			bt.TextSize = 12
		end
	end

	table.insert(N.active, 1, rec)
	while #N.active > 3 do N.dismiss(N.active[#N.active]) end
	tw(wrap, 0.4, { Size = UDim2.fromOffset(256, fullH) }, Enum.EasingStyle.Quint)
	tw(inner, 0.5, { Position = UDim2.new() }, Enum.EasingStyle.Quint)
	tw(inner, 0.35, { GroupTransparency = 0 }, Enum.EasingStyle.Sine)
	N.arm(rec, opts.duration)

	if not opts.silent then
		haptic(kind == "err" and 0.9 or 0.5)
		if cfg.sound and cfg.volume > 0 then pcall(function() notifSound:Play() end) end
	end
	return rec
end
-- toast with buttons (AutoFollow left / rejoined): UI.actionToast(kind, title, body, { {text=, primary=, fn=} }, seconds)
function UI.actionToast(kind, title, body, buttons, duration)
	return toast(kind, title, body, { buttons = buttons, duration = duration or 14 })
end
onClean(function() N.active = {} end)


-- ============================================================================
-- 12. COPY AVATAR ENGINE (v4.1 engine, GUI removed; progress goes through toasts)
-- ============================================================================
-- ============================================================================
-- 12. COPY AVATAR ENGINE - GENX LIFE TOGETHER BUILD
-- The Dreamville engine that lived here talked to Dreamville's own outfit
-- remotes (Packages.Flux AvatarService). This build keeps the exact same
-- public surface the UI uses (AV.apply / AV.setSync / AV.syncTarget /
-- AV.applying / AV.stopAll / AV.onApply / AV.onSync) but drives Life
-- Together's own wardrobe actions through the game's Modules.Core.Net -
-- the same Send/Get traffic the real client makes. Steps are written to
-- the same Copy Avatar log the Settings tab reads (CAP.CL).
-- ============================================================================
-- Net bootstrap: Flames Hub's own Life Together network loader, adapted.
-- Their loader does NOT assume one fixed path for the dispatcher module:
-- it finds Modules/Core/Game wherever they sit under ReplicatedStorage,
-- requires EVERY module inside them (the dispatcher relies on its sibling
-- modules being loaded), and uses the module that exposes send/get. The
-- old build required Modules.Core.Net in isolation, which can leave the
-- dispatcher degraded - the outfit still applied, but skin tone and body
-- scale, which ride on the same dispatcher, came out wrong.
local GXLT_Net = nil
local GXLT_Mods = {}
local function GXLT_loadNet()
	if GXLT_Net then return end
	if not game:IsLoaded() then game.Loaded:Wait() end
	local function deep(root, name)
		if not root then return nil end
		return root:FindFirstChild(name) or root:FindFirstChild(name, true)
	end
	local modules = deep(RS, "Modules")
	local core = deep(modules, "Core") or deep(RS, "Core")
	local gameFolder = deep(RS, "Game") or deep(modules, "Game")
	local function loadAll(folder)
		if not folder then return end
		if folder:IsA("ModuleScript") then
			local ok, res = pcall(require, folder)
			if ok and type(res) == "table" then GXLT_Mods[folder.Name] = res end
		end
		for _, m in ipairs(folder:GetDescendants()) do
			if m:IsA("ModuleScript") then
				local ok, res = pcall(require, m)
				if ok and type(res) == "table" then GXLT_Mods[m.Name] = res end
			end
		end
	end
	loadAll(core)
	loadAll(gameFolder)
	local net = GXLT_Mods["Net"] or GXLT_Mods["Network"]
	if net and type(net.send) == "function" and type(net.get) == "function" then
		GXLT_Net = net
		return
	end
	for _, res in pairs(GXLT_Mods) do
		if type(res.send) == "function" and type(res.get) == "function" then GXLT_Net = res return end
	end
end
GXLT_loadNet()
local GXLT_Remotes = RS:WaitForChild("Remotes", 10)
local function GXLT_Send(...)
	if not GXLT_Net then GXLT_loadNet() end
	if GXLT_Net and type(GXLT_Net.send) == "function" then
		return GXLT_Net.send(...)
	end
	local remote = GXLT_Remotes and GXLT_Remotes:FindFirstChild("Send")
	if remote then return remote:FireServer(...) end
end
local function GXLT_Get(...)
	if not GXLT_Net then GXLT_loadNet() end
	if GXLT_Net and type(GXLT_Net.get) == "function" then
		return GXLT_Net.get(...)
	end
	local remote = GXLT_Remotes and GXLT_Remotes:FindFirstChild("Get")
	if remote then return remote:InvokeServer(...) end
end
local function GXLT_notify(title, text, secs)
	local kind = (title == "Error" and "err") or (title == "Warning" and "warn") or (title == "Success" and "ok") or "info"
	pcall(toast, kind, tostring(title), tostring(text), (type(secs) == "number" and secs > 0) and { duration = secs } or nil)
end

local AV = (function()
local API = {} -- onApply(plr, state), onSync(plr, on) are set by the UI
local log = CAP.CL.add -- Copy Avatar only: everything below writes to Settings > Copy Avatar Logs
local Send, Get, notify = GXLT_Send, GXLT_Get, GXLT_notify
local fw = task.wait

local function get_human(player, timeout)
	local char = player and player.Character
	if not char then return nil end
	return char:FindFirstChildWhichIsA("Humanoid")
		or char:WaitForChild("Humanoid", timeout or 2)
end

-- Flames Hub's own copy code, line for line: avgSkin, clear_avatar and the
-- copier itself, lifted from their Life Together file unchanged apart from
-- mapping their g. environment onto this script's Send/Get/notify/get_human
-- and leaving out two of their guard blocks on purpose - their hub-owner
-- list, and their Anti Stealer refusal (GenX copies anyone; that refusal
-- living in their hub is exactly what makes our Anti Steal work).
local COPYING_FLAMES = false

local function avgSkin(bc)
	local skin_tone_colors = {
		bc.HeadColor3,
		bc.LeftArmColor3,
		bc.RightArmColor3,
		bc.TorsoColor3,
		bc.LeftLegColor3,
		bc.RightLegColor3
	}

	local r,g,b = 0,0,0
	for _,c in ipairs(skin_tone_colors) do
		r = r + c.R
		g = g + c.G
		b = b + c.B
	end
	return Color3.new(r/6,g/6,b/6)
end

local function clear_avatar()
	local args = {
		"wear_outfit_from_desc",
		{
			accessories = {
				{
					Rotation = "  ",
					AccessoryType = "Hair",
					Position = "  ",
					Scale = "1 1 1",
					IsLayered = false,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "Face",
					Position = "  ",
					Scale = "1 1 1",
					IsLayered = false,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "Face",
					Position = "  ",
					Scale = "1 1 1",
					IsLayered = false,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "Hat",
					Position = "  ",
					Scale = "1 1 1",
					IsLayered = false,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "Face",
					Position = "  ",
					Scale = "1 1 1",
					IsLayered = false,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "Shirt",
					Scale = "1 1 1",
					Position = "  ",
					Order = 1,
					IsLayered = true,
					Puffiness = 0,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "DressSkirt",
					Scale = "1 1 1",
					Position = "  ",
					Order = 2,
					IsLayered = true,
					Puffiness = 0,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "RightShoe",
					Scale = "1 1 1",
					Position = "  ",
					Order = 3,
					IsLayered = true,
					Puffiness = 0,
					AssetId = 0
				},
				{
					Rotation = "  ",
					AccessoryType = "LeftShoe",
					Scale = "1 1 1",
					Position = "  ",
					Order = 4,
					IsLayered = true,
					Puffiness = 0,
					AssetId = 0
				}
			},
			properties = {
				SwimAnimation = 0,
				RightLegColor = "^zH;",
				MoodAnimation = 0,
				Torso = 0,
				WidthScale = 1,
				BodyTypeScale = 0.25,
				ClimbAnimation = 0,
				LeftArmColor = "^zH;",
				Shirt = 0,
				GraphicTShirt = 0,
				RightArmColor = "^zH;",
				LeftArm = 0,
				RunAnimation = 0,
				JumpAnimation = 0,
				RightArm = 0,
				Face = 0,
				Head = 0,
				DepthScale = 1,
				LeftLegColor = "^zH;",
				FallAnimation = 0,
				Pants = 0,
				HeadColor = "^zH;",
				TorsoColor = "^zH;",
				IdleAnimation = 0,
				RightLeg = 0,
				HeadScale = 1,
				HeightScale = 1,
				ProportionScale = 0,
				LeftLeg = 0
			}
		}
	}

	pcall(function() Send(unpack(args)) end)
end

local function copyAvatarFlames(Player)
	if COPYING_FLAMES then notify("Warning","Avatar copier already in progress!", 3); return end
	COPYING_FLAMES = true
	if not Player or not Player.Character then
		COPYING_FLAMES = false
		notify("Warning","Target not found!",3)
		return 
	end

	local hum = Player.Character:FindFirstChildWhichIsA("Humanoid") or get_human(Player, Players.RespawnTime + 1)
	if not hum then
		COPYING_FLAMES = false
		notify("Warning","No humanoid!",3)
		return 
	end

	local desc = hum:GetAppliedDescription()
	if not desc then
		COPYING_FLAMES = false
		notify("Warning","No description!",3)
		return 
	end

	clear_avatar()
	task.wait(0.2)
	local accessories = {}
	for _,acc in ipairs(desc:GetAccessories(true)) do
		table.insert(accessories,{
			Rotation = "  ",
			Position = "  ",
			Scale = "1 1 1",
			IsLayered = acc.IsLayered,
			AccessoryType = acc.AccessoryType.Name,
			AssetId = acc.AssetId,
			Order = acc.Order,
			Puffiness = acc.Puffiness
		})
	end

	local properties = {
		Head = desc.Head or 0,
		Torso = desc.Torso or 0,
		LeftArm = desc.LeftArm or 0,
		RightArm = desc.RightArm or 0,
		LeftLeg = desc.LeftLeg or 0,
		RightLeg = desc.RightLeg or 0,
		Face = desc.Face or 0,
		Shirt = desc.Shirt or 0,
		Pants = desc.Pants or 0,
		GraphicTShirt = desc.GraphicTShirt or 0,
		RunAnimation = desc.RunAnimation or 0,
		WalkAnimation = desc.WalkAnimation or 0,
		JumpAnimation = desc.JumpAnimation or 0,
		FallAnimation = desc.FallAnimation or 0,
		ClimbAnimation = desc.ClimbAnimation or 0,
		IdleAnimation = desc.IdleAnimation or 0,
		SwimAnimation = desc.SwimAnimation or 0,
		HeightScale = desc.HeightScale or 1,
		WidthScale = desc.WidthScale or 1,
		DepthScale = desc.DepthScale or 1,
		HeadScale = desc.HeadScale or 1,
		BodyTypeScale = desc.BodyTypeScale or 0,
		ProportionScale = desc.ProportionScale or 0,
	}

	local args = {
		"wear_outfit_from_desc",
		{
			accessories = accessories,
			properties = properties
		}
	}

	pcall(function() Send(unpack(args)) end)
	task.wait(0.1)
	local bodyColors = Player.Character:FindFirstChildOfClass("BodyColors")
	if Player.Character and bodyColors then Send("skin_tone", avgSkin(bodyColors)) end
	local height = math.clamp(math.floor((desc.HeightScale or 1)*100+0.5),90,105)
	local width  = math.clamp(math.floor((desc.WidthScale  or 1)*100+0.5),70,100)
	Send("body_scale","HeightScale",height)
	task.wait(0.15)
	Send("body_scale","WidthScale",width)
	local age = Player:GetAttribute("age")
	if age then Get("age",age) end
	notify("Success","Copied avatar from "..Player.Name,5)
	COPYING_FLAMES = false
end

-- Builds the same wear_outfit_from_desc payload Flames' copier builds
-- from a description (all six scale fields as raw fractions). Used by
-- the settle pass in applyAvatar to write the scales AFTER the age.
local function outfitArgsFromDesc(desc)
	local accessories = {}
	for _, acc in ipairs(desc:GetAccessories(true)) do
		table.insert(accessories, {
			Rotation = "  ",
			Position = "  ",
			Scale = "1 1 1",
			IsLayered = acc.IsLayered,
			AccessoryType = acc.AccessoryType.Name,
			AssetId = acc.AssetId,
			Order = acc.Order,
			Puffiness = acc.Puffiness,
		})
	end
	local properties = {
		Head = desc.Head or 0,
		Torso = desc.Torso or 0,
		LeftArm = desc.LeftArm or 0,
		RightArm = desc.RightArm or 0,
		LeftLeg = desc.LeftLeg or 0,
		RightLeg = desc.RightLeg or 0,
		Face = desc.Face or 0,
		Shirt = desc.Shirt or 0,
		Pants = desc.Pants or 0,
		GraphicTShirt = desc.GraphicTShirt or 0,
		RunAnimation = desc.RunAnimation or 0,
		WalkAnimation = desc.WalkAnimation or 0,
		JumpAnimation = desc.JumpAnimation or 0,
		FallAnimation = desc.FallAnimation or 0,
		ClimbAnimation = desc.ClimbAnimation or 0,
		IdleAnimation = desc.IdleAnimation or 0,
		SwimAnimation = desc.SwimAnimation or 0,
		HeightScale = desc.HeightScale or 1,
		WidthScale = desc.WidthScale or 1,
		DepthScale = desc.DepthScale or 1,
		HeadScale = desc.HeadScale or 1,
		BodyTypeScale = desc.BodyTypeScale or 0,
		ProportionScale = desc.ProportionScale or 0,
	}
	return { accessories = accessories, properties = properties }
end

local applyingPlr = nil
local syncOn, syncPlr, syncToken = false, nil, 0

local function applyAvatar(plr)
	if not plr or applyingPlr then return end
	applyingPlr = plr
	if API.onApply then pcall(API.onApply, plr, "start") end
	log("info", "copy started: " .. plr.Name, "COPY")
	local ok, err = pcall(copyAvatarFlames, plr)
	applyingPlr = nil
	if ok then
		-- Flames' sequence sends skin + scale ~0.1s after the outfit, but the
		-- server's outfit apply lands later and overwrites them (that is why
		-- hands/feet came out black and the height never stuck). Their calls
		-- stay exactly as they wrote them - we just repeat the writes once
		-- everything has settled. AGE ORDER FIX: their copy sends the age
		-- LAST, and the game's age applies its own body preset over the
		-- copied scales (all six fields, not just height). So the settle
		-- pass now re-sends the full outfit first (raw scale fractions -
		-- the route the game's own size system uses), and only then the
		-- skin + body_scale sends: the scales end up as the last thing
		-- written, not the age.
		task.delay(1.2, function()
			if dead or not plr or not plr.Character then return end
			local hum2 = plr.Character:FindFirstChildWhichIsA("Humanoid")
			local d2 = hum2 and select(2, pcall(function() return hum2:GetAppliedDescription() end))
			if d2 then
				pcall(function() GXLT_Send("wear_outfit_from_desc", outfitArgsFromDesc(d2)) end)
				task.wait(0.4)
				if dead or not plr or not plr.Character then return end
			end
			local bc = plr.Character:FindFirstChildOfClass("BodyColors")
			if bc then pcall(function() GXLT_Send("skin_tone", avgSkin(bc)) end) end
			if d2 then
				local h2 = math.clamp(math.floor((d2.HeightScale or 1) * 100 + 0.5), 90, 105)
				local w2 = math.clamp(math.floor((d2.WidthScale or 1) * 100 + 0.5), 70, 100)
				pcall(function() GXLT_Send("body_scale", "HeightScale", h2) end)
				task.wait(0.15)
				pcall(function() GXLT_Send("body_scale", "WidthScale", w2) end)
			end
		end)
		log("ok", "copy finished: " .. plr.Name, "COPY")
		if API.onApply then pcall(API.onApply, plr, "done") end
	else
		COPYING_FLAMES = false
		log("fail", "copy incomplete for " .. plr.Name .. ": " .. tostring(err), "COPY")
		pcall(toast, "err", "Copy Avatar", "Failed - try again", { duration = 3 })
		if API.onApply then pcall(API.onApply, plr, "fail") end
	end
end

-- Sync Anim: mirror the target's playing animations (movement + emotes) on
-- your own character. This is animations ONLY - it never touches outfits.
-- (The Dreamville engine this replaced used "sync" to re-copy the avatar on
-- a loop, which is why pressing Sync Anim used to copy their avatar too.)
local syncTracks = {}
local function stopSyncTracks()
	for _, e in pairs(syncTracks) do
		pcall(function() e.track:Stop(0.1) end)
		pcall(function() e.track:Destroy() end)
		pcall(function() e.anim:Destroy() end)
	end
	syncTracks = {}
end
local function animSyncStep(plr)
	local myChar, tChar = LP.Character, plr and plr.Character
	if not myChar or not tChar then return end
	local myHum = myChar:FindFirstChildWhichIsA("Humanoid")
	local tHum = tChar:FindFirstChildWhichIsA("Humanoid")
	if not myHum or not tHum then return end
	local tAnim = tHum:FindFirstChildOfClass("Animator") or tHum
	local myAnim = myHum:FindFirstChildOfClass("Animator") or myHum
	local ok, tracks = pcall(function() return tAnim:GetPlayingAnimationTracks() end)
	if not ok or type(tracks) ~= "table" then return end
	local playing = {}
	for _, tr in ipairs(tracks) do
		local id = tr.Animation and tr.Animation.AnimationId
		if id and id ~= "" then
			playing[id] = tr
			local e = syncTracks[id]
			if not e then
				local a = Instance.new("Animation")
				a.AnimationId = id
				local ok2, ntr = pcall(function() return myAnim:LoadAnimation(a) end)
				if ok2 and ntr then
					e = { track = ntr, anim = a }
					syncTracks[id] = e
					pcall(function() ntr:Play(0.1) end)
				else
					pcall(function() a:Destroy() end)
				end
			end
			if e then
				pcall(function()
					e.track:AdjustSpeed(tr.Speed)
					if math.abs(e.track.TimePosition - tr.TimePosition) > 0.35 then e.track.TimePosition = tr.TimePosition end
				end)
			end
		end
	end
	for id, e in pairs(syncTracks) do
		if not playing[id] then
			pcall(function() e.track:Stop(0.1) end)
			pcall(function() e.track:Destroy() end)
			pcall(function() e.anim:Destroy() end)
			syncTracks[id] = nil
		end
	end
end

local function setSync(plr, on)
	if on then
		if syncOn and syncPlr == plr then return end
		syncOn, syncPlr = true, plr
		syncToken += 1
		local my = syncToken
		if API.onSync then pcall(API.onSync, plr, true) end
		log("info", "sync ON for " .. plr.Name, "SYNC")
		task.spawn(function()
			while syncOn and syncToken == my and syncPlr == plr and not dead do
				if plr.Parent and LP.Character then pcall(animSyncStep, plr) end
				task.wait(0.25)
			end
			stopSyncTracks()
		end)
	else
		if syncOn and syncPlr == plr then
			syncOn, syncPlr = false, nil
			syncToken += 1
			stopSyncTracks()
			if API.onSync then pcall(API.onSync, plr, false) end
			log("info", "sync OFF for " .. plr.Name, "SYNC")
		end
	end
end

API.apply = applyAvatar
API.setSync = setSync
API.syncTarget = function() return syncOn and syncPlr or nil end
API.applying = function() return applyingPlr end
API.stopAll = function()
	if applyingPlr then log("warn", "STOP requested while a copy was running (script stopped or cleaned up)", "STOP") end
	syncOn, syncPlr = false, nil
	syncToken += 1
	stopSyncTracks()
	applyingPlr = nil
	do local T = G.GENX_TAGS if T and T.setCopying then pcall(T.setCopying, false) end end
end

if GXLT_Net then log("ok", "Life Together Net module ready - Copy Avatar will work") else log("fail", "Net module not found, Copy Avatar will not work") end

return API
end)()

-- Life Together fallbacks for two Troll-tab mechanics that fired Dreamville
-- vehicle/role remotes. The GUI code stays untouched apart from the call
-- lines: when the Dreamville remote exists it is used exactly as before;
-- in Life Together these route through the game's own Net actions instead.
function GX_rainbowFire(rem, col)
	if rem then
		local ok, res = pcall(function() return GX_rainbowFire(rem, col) end)
		if ok then return res end
	end
	local veh = nil
	local vf = workspace:FindFirstChild("Vehicles")
	if vf then
		for _, m in ipairs(vf:GetChildren()) do
			local o = m:FindFirstChild("owner")
			if o and o.Value == LP and m:FindFirstChildOfClass("VehicleSeat") then veh = m break end
		end
	end
	if veh then
		pcall(GXLT_Send, "vehicle_color", col, veh)
		return true
	end
	return false
end

function GX_roleFire(r, role)
	if r then return r:InvokeServer(role) end
	GXLT_Send("job", role)
	return true
end

-- ============================================================================
-- GenX Life Together feature engine: the chosen OP + defense + utility set,
-- extracted from the Life Together feature library and rewired to this GUI.
-- Everything exports through the global X table the pages read.
-- ============================================================================
local function GXEngineMain()
local LocalPlayer = LP
local ReplicatedStorage = RS
local fw = task.wait
local COPYING = false
local notify = GXLT_notify
local Send = GXLT_Send
local Get = GXLT_Get

local function get_human(player, timeout)
	local char = player and player.Character
	if not char then return nil end
	return char:FindFirstChildWhichIsA("Humanoid")
		or char:WaitForChild("Humanoid", timeout or 2)
end

local function findplr(text)
	if not text or tostring(text) == "" then return nil end
	local q = tostring(text):lower()
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer
			and (p.Name:lower():find(q, 1, true) or p.DisplayName:lower():find(q, 1, true)) then
			return p
		end
	end
	return nil
end

-- ===== extra wiring for the vehicle / rainbow / freepay features =====
local Workspace = game:GetService("Workspace")

local vehicles_folder_cache = nil
local Rainbow_Vehicle = false
local Has_Free_LifePremium = false
local originals = {}

local function myChar() return LocalPlayer.Character end
local function myHum()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildWhichIsA("Humanoid")
end
local function myRoot()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function get_char(p) return p and p.Character end
local function get_root(p)
    local c = p and p.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- the game's own Data module (Free Premium patches your local copy of it)
local Data = nil
do
    local ok, mod = pcall(function()
        local modules = ReplicatedStorage:WaitForChild("Modules", 10)
        local core = modules and modules:WaitForChild("Core", 10)
        return core and require(core:WaitForChild("Data", 10))
    end)
    if ok and type(mod) == "table" then Data = mod end
end

local debug_ext = { getupvalue = getupvalue or (debug and debug.getupvalue) }

-- ===== end extra wiring =====

X = {} -- global on purpose: the pages section (chunk level) reads it after engineMain() runs -- cross-section exports (keeps top-level locals under the Luau 200 limit)

-- ===== FlamesLibrary shim + game module handles (for the v3 feature pack) =====
local CoreGui = game:GetService("CoreGui")

local FLIB = { _tasks = {}, _conns = {}, _threads = {} }
-- Actually stop a spawned thread: a task.spawn loop cannot be stopped by
-- flipping a flag it never reads - it has to be cancelled/closed. (This is
-- why Rainbow Skin kept cycling after toggle-off: disconnect only flipped
-- the bookkeeping flag while the while-true loop ran on untouched.)
local function killThread(th)
    if not th then return end
    if type(task) == "table" and type(task.cancel) == "function" then pcall(task.cancel, th) end
    if coroutine and coroutine.close and coroutine.status and coroutine.status(th) == "suspended" then pcall(coroutine.close, th) end
end
function FLIB.spawn(a, b, c)
    if type(a) == "function" then
        return task.spawn(a)
    end
    if type(c) == "function" then
        if type(a) == "string" then
            if FLIB._threads[a] then killThread(FLIB._threads[a]) end
            FLIB._tasks[a] = true
            local th = task.spawn(c)
            FLIB._threads[a] = th
            return th
        end
        return task.spawn(c)
    end
    if type(b) == "function" then
        return task.spawn(b)
    end
end
function FLIB.disconnect(key)
    if type(key) ~= "string" then return end
    FLIB._tasks[key] = false
    local th = FLIB._threads[key]
    if th then
        killThread(th)
        FLIB._threads[key] = nil
    end
    local conn = FLIB._conns[key]
    if conn then
        pcall(function() conn:Disconnect() end)
        FLIB._conns[key] = nil
    end
end
function FLIB.connect(key, conn)
    FLIB._conns[key] = conn
    return conn
end
function FLIB.is_alive(key)
    if type(key) ~= "string" then return false end
    return FLIB._tasks[key] == true
end
function FLIB.cleanup_all()
    for k in pairs(FLIB._tasks) do FLIB._tasks[k] = false end
    for k, th in pairs(FLIB._threads) do killThread(th); FLIB._threads[k] = nil end
    for k, conn in pairs(FLIB._conns) do
        pcall(function() conn:Disconnect() end)
        FLIB._conns[k] = nil
    end
end
FLIB.wait = task.wait
function FLIB.safe_func(f) return f end

local function reqModule(name)
    local inst = ReplicatedStorage:FindFirstChild(name, true)
    if inst and inst:IsA("ModuleScript") then
        local ok, m = pcall(require, inst)
        if ok then return m end
    end
    return nil
end

local CharMod = reqModule("Char")
local PhoneMod = reqModule("Phone")
local UtilMod = reqModule("Util")
local InvisibleMode = reqModule("InvisibleMode")
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Game_Folder = ReplicatedStorage:FindFirstChild("Game", true)

-- ===== end shim =====
do
-- ===== vehicle helpers + kill (Framework_Base_1, logic verbatim, rewired) =====
local function find_vehicles_folder()
    local cache = vehicles_folder_cache
    if cache and cache:IsA("Folder") then return cache end
    for i, v in pairs(Workspace:GetChildren()) do
        if v:IsA("Folder") and v.Name == "Vehicles" then
            vehicles_folder_cache = v
            return v
        end
    end

    return nil
end

local function get_vehicle()
    local folder = vehicles_folder_cache or find_vehicles_folder()
    if not folder or not folder:IsA("Folder") then return nil end
    for i, v in pairs(folder:GetChildren()) do
        if v.owner.Value == LocalPlayer then
            return v
        end
    end

    return nil
end

local VehicleNames = {}
local function BuildVehicleTable()
    local VehicleInformation = ReplicatedStorage:FindFirstChild("VehicleInformation", true)
    if not VehicleInformation then return end
    for _, Obj in ipairs(VehicleInformation:GetChildren()) do
        if Obj:IsA("Configuration") then
            table.insert(VehicleNames, Obj.Name)
        end
    end
end

local function Levenshtein(A, B)
    local A_Len, B_Len = #A, #B
    if A_Len == 0 then return B_Len end
    if B_Len == 0 then return A_Len end
    local Matrix = {}
    for i = 0, A_Len do Matrix[i] = {[0] = i} end
    for j = 0, B_Len do Matrix[0][j] = j end
    for i = 1, A_Len do
        for j = 1, B_Len do
            local Cost = A:sub(i, i) == B:sub(j, j) and 0 or 1
            Matrix[i][j] = math.min(
                Matrix[i-1][j] + 1,
                Matrix[i][j-1] + 1,
                Matrix[i-1][j-1] + Cost
            )
        end
    end
    return Matrix[A_Len][B_Len]
end

local function FindVehicle(Query)
    local Query_Lower = Query:lower()
    local Best_Match = nil
    local Best_Score = math.huge
    local Partial_Matches = {}

    for _, Name in ipairs(VehicleNames) do
        local Name_Lower = Name:lower()
        if Name_Lower:find(Query_Lower, 1, true) then table.insert(Partial_Matches, Name) end
        local Dist = Levenshtein(Query_Lower, Name_Lower)
        if Dist < Best_Score then
            Best_Score = Dist
            Best_Match = Name
        end
    end

    if #Partial_Matches > 0 then return Partial_Matches[1], Partial_Matches end
    local Threshold = math.floor(#Query_Lower * 0.4)
    if Best_Score <= Threshold then return Best_Match, {Best_Match} end
    return nil, {}
end

local function spawn_any_vehicle(Vehicle)
    local Match = FindVehicle(Vehicle)
    if Match then
        Get("spawn_vehicle", Match)
    else
        notify("Error", "Vehicle not found: "..tostring(Vehicle), 1)
        return 
    end
end

BuildVehicleTable()

function change_vehicle_color(Color, Vehicle)
    if not Send or typeof(Send) ~= "function" then return end
    Send("vehicle_color", Color, Vehicle)
end

function create_kill_part()
    if Workspace:FindFirstChild("Kill_Model_Script(KEEP)") then return end
    task.wait(0.1)
    local Kill_Model_Script = Instance.new("Model")
    Kill_Model_Script.Name = "Kill_Model_Script(KEEP)"
    Kill_Model_Script.Parent = Workspace
    task.wait(0.1)
    local Kill_Part = Instance.new("Part")
    Kill_Part.Name = "SCRIPT_KILLPART_VOID"
    Kill_Part.Anchored = true
    Kill_Part.CanCollide = false
    Kill_Part.Size = Vector3.new(10, 10, 10)
    Kill_Part.CFrame = CFrame.new(0, -470, 0)
    Kill_Part.Transparency = 1
    Kill_Part.Parent = Kill_Model_Script
end

function vehicle_kill_player(TargetPlayer)
    if not TargetPlayer or not TargetPlayer.Character then return end
    local TargetChar = TargetPlayer.Character or get_char(TargetPlayer)
    if not TargetChar then return end
    local Target_HRP = TargetChar:FindFirstChild("HumanoidRootPart") or get_root(TargetPlayer)
    if not Target_HRP or not Target_HRP.Parent then return end
    local Old_CF = myChar():FindFirstChild("HumanoidRootPart").CFrame
    local voidPart = Workspace:FindFirstChild("Kill_Model_Script(KEEP)")
    if not voidPart then create_kill_part(); voidPart = Workspace:FindFirstChild("Kill_Model_Script(KEEP)") end
    local voidCF = voidPart:FindFirstChild("SCRIPT_KILLPART_VOID") and voidPart:FindFirstChild("SCRIPT_KILLPART_VOID").CFrame
    if not voidCF then return end
    local MyChar = myChar() or LocalPlayer.Character or get_char(LocalPlayer)
    local MyHumanoid = myHum() or MyChar:FindFirstChildWhichIsA("Humanoid") or get_human(LocalPlayer)
    local MyBus = nil
    local folder = vehicles_folder_cache or find_vehicles_folder()
    if not folder or not folder:IsA("Folder") then notify("Error", "Folder: Vehicles was not found or does not exist.", 3); return end

    for _, v in ipairs(folder:GetChildren()) do
        if v:IsA("Model") and v:FindFirstChild("owner") and v.owner.Value == LocalPlayer then
            if v:FindFirstChild("VehicleSeat") then
                MyBus = v
                break
            end
        end
    end

    if not MyBus then notify("Error", "No owned SchoolBus found.", 3); return end
    local seat = MyBus:FindFirstChild("VehicleSeat")
    if seat and MyHumanoid then
        MyChar:PivotTo(seat.CFrame)
        task.wait(0.2)
        seat:Sit(MyHumanoid)
    end

    local Max_Tries = 40
    for i = 1, Max_Tries do
        local Target_Humanoid = TargetChar:FindFirstChildOfClass("Humanoid") or get_human(TargetPlayer)
        local Is_Sitting = Target_Humanoid and Target_Humanoid.Sit
        if Is_Sitting then break end
        MyBus:PivotTo(Target_HRP.CFrame + Vector3.new(0, 0.3, 0))
        task.wait(0.2)
    end
    wait(0.1)
    MyBus:PivotTo(voidCF)
    wait(0.4)
    local My_HRP = myRoot() or myChar():FindFirstChild("HumanoidRootPart") or get_root(LocalPlayer)
    local My_Human = myHum() or myChar() and myChar():FindFirstChildWhichIsA("Humanoid") or get_human(LocalPlayer)
    if My_Human and My_Human.Parent and My_Human:IsDescendantOf(game) and My_Human.Sit then
        pcall(function() My_Human:ChangeState(3) end)
        wait(0.1)
        if My_HRP and My_HRP.Parent then My_HRP.CFrame = Old_CF end
        wait(0.5)
        if not get_vehicle() then return end
        spawn_any_vehicle(tostring(get_vehicle().Name))
    end

    if My_HRP and My_HRP.Parent then
        if My_HRP and My_HRP.Parent then My_HRP.CFrame = Old_CF end
        wait(0.5)
        if not get_vehicle() then return end
        spawn_any_vehicle(tostring(get_vehicle().Name))
    end
end

-- ===== rainbow vehicle (main game file, logic verbatim, rewired) =====
local COLORS = {
    Color3.fromRGB(255,255,255),
    Color3.fromRGB(128,128,128),
    Color3.fromRGB(0,0,0),
    Color3.fromRGB(0,0,255),
    Color3.fromRGB(0,255,0),
    Color3.fromRGB(0,255,255),
    Color3.fromRGB(255,165,0),
    Color3.fromRGB(139,69,19),
    Color3.fromRGB(255,255,0),
    Color3.fromRGB(50,205,50),
    Color3.fromRGB(255,0,0),
    Color3.fromRGB(255,155,172),
    Color3.fromRGB(128,0,128),
}

local function RGB_Vehicle(state)
    if state == true then
        if Rainbow_Vehicle then notify("Warning", "GenX | Rainbow Vehicle is already enabled.", 5); return end
        Rainbow_Vehicle = true
        notify("Success", "GenX | Rainbow Vehicle is now enabled.", 5)
        FLIB.spawn("rgb_vehicle", "spawn", function()
            while Rainbow_Vehicle == true do
                -- no car yet? stay ON and wait for one - it never turns off by itself
                local veh = get_vehicle()
                if veh then
                    for _, color in ipairs(COLORS) do
                        if Rainbow_Vehicle ~= true then break end
                        pcall(change_vehicle_color, color, veh)
                        fw(0)
                    end
                    RunService.Heartbeat:Wait()
                else
                    task.wait(0.3)
                end
            end
        end)
    elseif state == false then
        if not Rainbow_Vehicle then
            if notify and typeof(notify) == "function" then notify("Warning", "GenX | Rainbow Vehicle is not enabled.", 5) end
            return
        end
        Rainbow_Vehicle = false
        FLIB.disconnect("rgb_vehicle")
        notify("Success", "GenX | Rainbow Vehicle is now disabled.", 5)
    else
        return 
    end
end

-- ===== free premium (Configuration_API freepay_func, logic verbatim, rewired) =====
local function freepay_func(state)
    if not Data or not Data.initiate then notify("Error", "Data module missing.", 3); return end
    if not debug_ext.getupvalue then notify("Error", "Executor does not support getupvalue.", 3); return end
    if state == nil then state = not Has_Free_LifePremium end
    if state then
        if Has_Free_LifePremium then notify("Error", "FreePay is already enabled.", 3); return end
        local update_datum = debug_ext.getupvalue(Data.initiate, 2)
        if type(update_datum) ~= "function" then notify("Error", "Could not resolve update_datum.", 3); return end
        local u3 = debug_ext.getupvalue(update_datum, 2)
        if type(u3) ~= "table" then notify("Error", "Could not resolve data store.", 3); return end
        local patches = {
            is_verified      = true,
            invisible_bought = true,
            max_outfits      = 99,
        }

        for key, spoof_val in next, patches do
            local current = u3[key]
            local should_patch = false

            if type(current) == "boolean" then
                should_patch = current ~= true
            elseif type(current) == "number" then
                should_patch = current < spoof_val
            else
                should_patch = current == nil
            end

            if should_patch then
                originals[key] = current
                update_datum(key, spoof_val)
                print(string.format("[freepay] patched [%s] %s -> %s", key, tostring(current), tostring(spoof_val)))
            else
                print(string.format("[freepay] skipped [%s] = %s (already sufficient)", key, tostring(current)))
            end
        end

        for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
            local val = v:GetAttribute("IsVerifiedOnly")
            if val ~= nil and val ~= false then
                originals[v] = val
                v:SetAttribute("IsVerifiedOnly", false)
            end
        end

        for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
            local val = v:GetAttribute("IsAirportRestricted")
            if val ~= nil and val ~= false then
                originals[v] = val
                v:SetAttribute("IsAirportRestricted", false)
            end
        end

        Has_Free_LifePremium = true
        notify("Success", "FreePay is now enabled.", 5)
    else
        if not Has_Free_LifePremium then notify("Error", "FreePay is not enabled.", 3); return end
        local update_datum = debug_ext.getupvalue(Data.initiate, 2)
        for key, original_val in next, originals do
            if typeof(key) == "string" then
                if type(update_datum) == "function" then
                    update_datum(key, original_val)
                    print(string.format("[freepay] restored [%s] -> %s", key, tostring(original_val)))
                end
            elseif typeof(key) == "Instance" and key.Parent then
                if key:GetAttribute("IsVerifiedOnly") ~= nil then
                    key:SetAttribute("IsVerifiedOnly", original_val)
                end
                if key:GetAttribute("IsAirportRestricted") ~= nil then
                    key:SetAttribute("IsAirportRestricted", original_val)
                end
            end
        end

        table.clear(originals)
        Has_Free_LifePremium = false
        notify("Success", "FreePay is now disabled.", 5)
    end
end

X.get_vehicle = get_vehicle
X.spawn_any_vehicle = spawn_any_vehicle
X.find_vehicles_folder = find_vehicles_folder
X.vehicle_kill_player = vehicle_kill_player
X.RGB_Vehicle = RGB_Vehicle
X.RGB_Vehicle_state = function() return Rainbow_Vehicle end
X.freepay_func = freepay_func
X.COLORS = COLORS
end
-- ===== v3 feature pack state (outer scope, shared by both blocks) =====
local get_vehicle = X.get_vehicle
local spawn_any_vehicle = X.spawn_any_vehicle
local find_vehicles_folder = X.find_vehicles_folder
local COLORS = X.COLORS
local Every_Job
local Spam_And_Spoof_Survey_Submissions
local Loop_Flinging_Player_Flames_Hub
local Noclip_Enabled
local afEnabled
local antifling_enabled
local Float_Running_In_Flames_Hub
local sp_delay
local spawnpoint
local spawnpos
local Anti_Void_Enabled_Bool
local originalFPDH
local Not_Ever_Sitting
local firehidden
local firemanual
local walkflinging
local WalkFlingRespawnConn
local TouchingWhitelisted
local TrackHasBeenStopped_Watcher_Task
local VehicleDestroyer_Enabled
local LockHomeLoop
local LockHomeToken
local LockHouse_LastState = {}
local PlotMarker
local RGB_Rainbow_Phone
local Rainbow_Tools_FE
local rainbow_skintone_currently_enabled
local original_skintone
local Anti_Invisible_Players_Currently_Active
local ultimate_lag_reducer
local FogEnd
local FogStart
local Seat
local fling_bv
local flingManager
local loopprotect
local invisible_body_parts
local is_invisible_script_toggled
local session_active
local session_original_height
local session_original_width
local session_original_skin
local session_original_depth
local session_original_skin_w
local session_original_width_only
local session_size_active
local session_width_active
local last_height_scale
local last_width_scale
local last_depth_scale
local last_skin_tone
local last_skin_tone_s
local last_skin_tone_w
local last_width_scale_only
local prev_height_scale
local prev_width_scale
local prev_depth_scale
local prev_skin_tone
local prev_skin_tone_s
local prev_skin_tone_w
local prev_width_scale_only
local height_setter_busy
local width_setter_busy
local size_setter_busy
local anti_sit_config
local anti_sit_spam
local anti_sit_registry
local togglergbflows
local NightVisionEnabled
local Invisible_Flash
local NA_GRAB_BODY
local WalkFlingConnections = {}
local noclip_parts = {}
local vehicle_parts_cache = {}
local PlotAreas = {}
local function getHead(char) return char and char:FindFirstChild("Head") end
local function is_whitelisted(_) return false end
local lib = FLIB
local UIS = game:GetService("UserInputService")
local UserInputService = UIS
local genv = { stored_effects_main_tbl = {}, stored_parts_main_tbl = {}, parts_seen = {}, all_street_lights = {} }
local InstanceNew = Instance.new
local lighting = Lighting
local work = Workspace
local Toggleable_Noclip
X.PlotAreas = PlotAreas

do
local DisableAntiFling, EnableAntiFling, Foreach, ToggleNoclip, Toggle_AntiFling_Boolean_Func, anti_car_fling, anti_sit_attr, anti_sit_bind_hv_folder, anti_sit_bind_hv_model, anti_sit_char_valid, anti_sit_cleanup, anti_sit_connect, anti_sit_disable_nearby, anti_sit_eject_any, anti_sit_eject_seat, anti_sit_func, anti_sit_get_char, anti_sit_get_hum, anti_sit_hard_eject, anti_sit_hook_hum, anti_sit_hum_valid, anti_sit_in_hv, anti_sit_spam_start, anti_sit_spam_stop, anti_sit_uid, anti_sit_watch_hv, anti_sit_watch_seats, anti_void, cleanup_fling_resources, clear_all, clear_spawnpoint, destroy_fire_model, disable_fire_object, flush_queue, getHum, getPlrHum, handle_object, hum_vehicle_name, in_humanoid_vehicle, is_fire_class, is_in_vehicle, make_key, noclip_step, process_veh_model, process_veh_part, purge_all_fire, refresh_parts, set_fire_state, set_spawnpoint, setup_vehicles_folder, start_flames_float, stop_flames_float, stop_loopfling
local float_part
local inc = false
local dec = false
local float_name = "GenXFloat_" .. tostring(math.random(1000, 9999))
local isMobile = UIS.TouchEnabled
local Wait = task.wait
local FireClasses = {
   Fire = true,
   Smoke = true,
   Sparkles = true,
   ParticleEmitter = true,
   Beam = true,
}
local OrgDestroyHeight = workspace.FallenPartsDestroyHeight
local _uid = 0
local PendingQueue = {}
local QueueDirty   = false

local attr_name = "InHumanoidVehicle"
local keys = {loop = "anti_sit_loop", char = "anti_sit_char", spam = "anti_sit_spam", hook = "anti_sit_hook", seat = "anti_sit_seat", hv = "anti_sit_hv"}
local cfg = anti_sit_config or {phase_two = 0.75, phase_three = 2, timeout = 5, retry_delay = 0.5}
local spam = anti_sit_spam or {active = false, started = 0, last_send = 0, last_hard = 0, cooldown_until = 0, exits = 0, total = 0, fastest = math.huge}
local registry = anti_sit_registry or {}
seat_cache = {}
local uid = 0
anti_sit_config = cfg
anti_sit_spam = spam
anti_sit_registry = registry
-- [[ Replaced up here but kept down there as well because some scripts reference it after this point. ]] --
in_humanoid_vehicle = function(player_or_name)
   local humanoid_vehicles = Workspace:FindFirstChild("HumanoidVehicles", true)
   if not humanoid_vehicles then return end
   local player = player_or_name
   if typeof(player_or_name) == "string" then
      player = Players:FindFirstChild(player_or_name)
      if not player then return end
   end
   local character = player == LocalPlayer and myChar() or player.Character
   if not character then return end
   local humanoid = character and character:FindFirstChildWhichIsA("Humanoid") or get_human(player, 3)
   if not humanoid then return end
   local vehicle_attr = humanoid:GetAttribute("InHumanoidVehicle")
   if vehicle_attr == nil then return end
   if type(Humanoid_Vehicles) ~= "table" then return end
   if not table.find(Humanoid_Vehicles, vehicle_attr) then return end
   return vehicle_attr
end

hum_vehicle_name = function(plr)
   local hv = in_humanoid_vehicle(plr)
   if not hv then return nil end
   local folder = Workspace:FindFirstChild("HumanoidVehicles", true)
   if not folder or not folder:IsA("Folder") then return nil end
   local inst = folder:FindFirstChild(hv)
   if not inst then return nil end
   return inst.Name
end

anti_sit_uid = function() uid += 1; return uid end
anti_sit_connect = function(name, conn) registry[name] = true; FLIB.connect(name, conn) end
anti_sit_cleanup = function() for name in pairs(registry) do FLIB.disconnect(name) end; table.clear(registry); table.clear(seat_cache) end
anti_sit_get_char = function() return myChar() or LocalPlayer.Character or (get_char and get_char(LocalPlayer)) end
anti_sit_get_hum = function(char) return (char and char:FindFirstChildWhichIsA("Humanoid")) or myHum() or (get_human and get_human(LocalPlayer)) or (CharMod and CharMod.get_hum and CharMod.get_hum()) end
anti_sit_char_valid = function(char) return char ~= nil and char:FindFirstChild("HumanoidRootPart") ~= nil and char:IsDescendantOf(workspace) end
anti_sit_hum_valid = function(hum) return hum ~= nil and hum.Parent ~= nil and hum:IsDescendantOf(game) end
anti_sit_attr = function(hum)
   if not hum then return nil end
   local ok, res = pcall(function() return hum:GetAttribute(attr_name) end)
   if ok and res ~= nil then return res end
   return nil
end

anti_sit_in_hv = function(hum)
   if in_humanoid_vehicle and typeof(in_humanoid_vehicle) == "function" then
      local ok, res = pcall(in_humanoid_vehicle, LocalPlayer)
      if ok and res ~= nil then return res end
   end
   return anti_sit_attr(hum)
end

anti_sit_hard_eject = function(char, hum)
   local hrp = char and char:FindFirstChild("HumanoidRootPart")
   local folder = workspace:FindFirstChild("HumanoidVehicles")
   if folder and hrp then
      for _, group in folder:GetChildren() do
         for _, model in group:GetChildren() do
            if model:IsA("Model") and model:HasTag("HumanoidVehicle") then
               local occupant_val = model:FindFirstChild("occupant")
               local owner_val = model:FindFirstChild("owner")
               local ours = (occupant_val and occupant_val.Value == hum) or (owner_val and owner_val.Value == LocalPlayer)
               if ours then
                  local touch_part = model:FindFirstChild("TouchPart", true)
                  if touch_part then
                        for _, weld in touch_part:GetChildren() do
                           if weld:IsA("WeldConstraint") and (weld.Part0 == hrp or weld.Part1 == hrp) then pcall(function() weld:Destroy() end) end
                        end
                  end
                  if occupant_val then pcall(function() occupant_val.Value = nil end) end
               end
            end
         end
      end
   end
   if hrp and hrp.Parent then
      for _, joint in hrp:GetChildren() do
         if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
            local other = joint.Part0 == hrp and joint.Part1 or joint.Part0
            if other and not other:IsDescendantOf(char) then pcall(function() joint:Destroy() end) end
         end
      end
      pcall(function() hrp.CFrame = hrp.CFrame * CFrame.new(0, 4, -3) end)
   end
   pcall(function() hum:SetAttribute(attr_name, nil) end)
   pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
   if Send and typeof(Send) == "function" then pcall(Send, "stop_sitting") end
end

anti_sit_spam_stop = function(success)
   FLIB.disconnect(keys.spam)
   if success then
      local took = os.clock() - spam.started
      spam.exits += 1
      spam.total += took
      spam.fastest = math.min(spam.fastest, took)
   end
   spam.active = false
   spam.cooldown_until = os.clock() + (success and 0 or cfretry_delay)
end

anti_sit_spam_start = function()
   if spam.active or os.clock() < spam.cooldown_until then return end
   spam.active = true
   spam.started = os.clock()
   spam.last_send = 0
   spam.last_hard = 0
   FLIB.connect(keys.spam, RunService.Heartbeat:Connect(function()
      if not Not_Ever_Sitting then anti_sit_spam_stop(false); return end
      local char = anti_sit_get_char()
      local hum = char and anti_sit_get_hum(char)
      if not anti_sit_char_valid(char) or not anti_sit_hum_valid(hum) then anti_sit_spam_stop(false); return end
      if anti_sit_in_hv(hum) == nil then anti_sit_spam_stop(true); return end
      local now = os.clock()
      local elapsed = now - spam.started
      if elapsed > cftimeout then anti_sit_spam_stop(false); return end
      pcall(function()
         hum.Jump = true
         hum:ChangeState(Enum.HumanoidStateType.Jumping)
      end)
      if elapsed > cfphase_two then
         pcall(function() hum.Sit = false end)
         if now - spam.last_send > 0.15 then
            spam.last_send = now
            if Send and typeof(Send) == "function" then pcall(Send, "stop_sitting") end
         end
      end
      if elapsed > cfphase_three and now - spam.last_hard > 0.4 then
         spam.last_hard = now
         anti_sit_hard_eject(char, hum)
      end
   end))
end

anti_sit_eject_seat = function(hum, seat)
   local target = seat or hum.SeatPart
   if target and target.Parent then
      pcall(function() target:SetAttribute("Disabled", true) end)
      task.delay(0.3, function() pcall(function() if target.Parent then target:SetAttribute("Disabled", false) end end) end)
   end
   pcall(function() hum.Sit = false end)
   pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
   if Send then pcall(Send, "stop_sitting") end
   local char = hum.Parent
   local hrp = char and char:IsDescendantOf(workspace) and char:FindFirstChild("HumanoidRootPart")
   if hrp and hrp.Parent then pcall(function() hrp.CFrame = hrp.CFrame * CFrame.new(0, 3, -2) end) end
end

anti_sit_eject_any = function(char, hum)
   if not anti_sit_char_valid(char) or not anti_sit_hum_valid(hum) then return end
   if anti_sit_in_hv(hum) ~= nil then anti_sit_spam_start(); return end
   local seat_part = hum.SeatPart
   local is_sit = hum.Sit or (CharMod and CharMod.is_sitting and CharMod.is_sittinget())
   if is_sit or seat_part then anti_sit_eject_seat(hum, seat_part) end
end

anti_sit_disable_nearby = function(char)
   local hrp = myRoot() or char and char:FindFirstChild("HumanoidRootPart") or get_root(LocalPlayer)
   if not hrp or not hrp.Parent then return end
   for seat in pairs(seat_cache) do
      if seat.Parent and seat:GetAttribute("Disabled") ~= true and (seat.Position - hrp.Position).Magnitude < 8 then
         pcall(function() seat:SetAttribute("Disabled", true) end)
         task.delay(0.35, function() pcall(function() if seat.Parent then seat:SetAttribute("Disabled", false) end end) end)
      end
   end
end

anti_sit_hook_hum = function(hum, char)
   anti_sit_connect(keys.hook .. "_attr", hum:GetAttributeChangedSignal(attr_name):Connect(function()
      if Not_Ever_Sitting and anti_sit_attr(hum) ~= nil then anti_sit_eject_any(char, hum) end
   end))
   anti_sit_connect(keys.hook .. "_sit", hum:GetPropertyChangedSignal("Sit"):Connect(function()
      if Not_Ever_Sitting and hum.Sit then anti_sit_eject_any(char, hum) end
   end))
   anti_sit_connect(keys.hook .. "_seatpart", hum:GetPropertyChangedSignal("SeatPart"):Connect(function()
      if not Not_Ever_Sitting or not hum.SeatPart then return end
      task.defer(function() if Not_Ever_Sitting then anti_sit_eject_any(char, hum) end end)
   end))
end

anti_sit_watch_seats = function()
   table.clear(seat_cache)
   for _, obj in workspace:GetDescendants() do if obj:IsA("Seat") or obj:IsA("VehicleSeat") then seat_cache[obj] = true end end
   anti_sit_connect(keys.seat .. "_added", workspace.DescendantAdded:Connect(function(obj) if obj:IsA("Seat") or obj:IsA("VehicleSeat") then seat_cache[obj] = true end end))
   anti_sit_connect(keys.seat .. "_removed", workspace.DescendantRemoving:Connect(function(obj) seat_cache[obj] = nil end))
end

anti_sit_bind_hv_model = function(model)
   if not (model:IsA("Model") and model:HasTag("HumanoidVehicle")) then return end
   task.spawn(function()
      local occupant_val = model:WaitForChild("occupant", 5)
      if not occupant_val or not occupant_val:IsA("ObjectValue") or not Not_Ever_Sitting then return end
      anti_sit_connect(keys.hv .. "_occ_" .. anti_sit_uid(), occupant_val:GetPropertyChangedSignal("Value"):Connect(function()
         if not Not_Ever_Sitting or occupant_val.Value == nil then return end
         local char = anti_sit_get_char()
         local hum = char and anti_sit_get_hum(char)
         if occupant_val.Value == hum then anti_sit_spam_start() end
      end))
   end)
end

anti_sit_bind_hv_folder = function(folder)
   if not folder:IsA("Folder") then return end
   for _, model in folder:GetChildren() do anti_sit_bind_hv_model(model) end
   anti_sit_connect(keys.hv .. "_child_" .. anti_sit_uid(), folder.ChildAdded:Connect(function(model)
      if Not_Ever_Sitting then anti_sit_bind_hv_model(model) end
   end))
end

anti_sit_watch_hv = function()
   local root = workspace:FindFirstChild("HumanoidVehicles")
   if not root then return end
   for _, folder in root:GetChildren() do anti_sit_bind_hv_folder(folder) end
   anti_sit_connect(keys.hv .. "_folders", root.ChildAdded:Connect(function(folder) if Not_Ever_Sitting then anti_sit_bind_hv_folder(folder) end end))
end

anti_sit_func = function(toggle)
   local lib = FLIB
   local fw = lib.wait
   if not Seat then
      local ok, res = pcall(function() return require(Game_Folder:FindFirstChild("Seat")) end)
      if not ok or not res then notify("Error", "Seat ModuleScript not found or failed to load!", 3); return end
      Seat = res
   end
   if toggle == true then
      if Not_Ever_Sitting then notify("Warning", "AntiSit is already enabled!", 3); return end
      Not_Ever_Sitting = true
      notify("Success", "Anti-Sit is now enabled!", 3)
      notify("Success:", "Anti-Sit is now enabled.", "Normal")
      local char = anti_sit_get_char()
      local hum = char and anti_sit_get_hum(char)
      if anti_sit_char_valid(char) and anti_sit_hum_valid(hum) then anti_sit_hook_hum(hum, char) end
      anti_sit_watch_seats()
      anti_sit_watch_hv()
      anti_sit_connect(keys.char, LocalPlayer.CharacterAdded:Connect(function(new_char)
         fw(0)
         local new_hum = new_char:WaitForChild("Humanoid", 5)
         if anti_sit_char_valid(new_char) and anti_sit_hum_valid(new_hum) then anti_sit_hook_hum(new_hum, new_char) end
      end))
      lib.spawn(keys.loop, "spawn", function()
         while Not_Ever_Sitting == true do
            Seat.enabled.set(false)
            local cur_char = anti_sit_get_char()
            local cur_hum = cur_char and anti_sit_get_hum(cur_char)
            if anti_sit_char_valid(cur_char) and anti_sit_hum_valid(cur_hum) then
               anti_sit_eject_any(cur_char, cur_hum)
               if cur_hum.Sit or cur_hum.SeatPart then anti_sit_disable_nearby(cur_char) end
            end
            fw(0)
         end
         lib.disconnect(keys.loop)
      end)
   elseif toggle == false then
      if not Not_Ever_Sitting then notify("Warning", "AntiSit is not enabled!", 3); return end
      Not_Ever_Sitting = false
      anti_sit_spam_stop(false)
      anti_sit_cleanup()
      lib.disconnect(keys.loop)
      fw(0.2)
      Seat.enabled.set(true)
      notify("Success", "Anti-Sit is now disabled.", 3)
      pcall(function() PhoneMod.show_notification("Success:", "Anti-Sit is now disabled.", "Normal") end)
   end
end




start_flames_float = function()
   if Float_Running_In_Flames_Hub then notify("Warning", "GenX Float-V1 is already enabled.", 5); return end
   local char = myChar() or LocalPlayer.Character or get_char(LocalPlayer)
   local root = myRoot() or char and char:FindFirstChild("HumanoidRootPart") or get_root(LocalPlayer)
   local hum = myHum() or char and char:FindFirstChildOfClass("Humanoid") or get_human(LocalPlayer)
   if not char or not root or not hum then return end
   Float_Running_In_Flames_Hub = true
   float_part = Instance.new("Part")
   float_part.Name = float_name
   float_part.Parent = workspace
   float_part.Size = Vector3.new(10, 2, 10)
   float_part.Transparency = 1
   float_part.Anchored = true
   float_part.CanCollide = true
   float_part.CastShadow = false

   local controlModule
   if isMobile then
      local ok, cm = pcall(function() return require(LocalPlayer.PlayerScripts:WaitForChild("PlayerModule"):WaitForChild("ControlModule")) end)
      if ok then controlModule = cm end
   end

   if not isMobile then
      FLIB.connect("flames_float_input_began",
         UIS.InputBegan:Connect(function(i, gp)
            if gp then return end
            if i.KeyCode == Enum.KeyCode.E then inc = true end
            if i.KeyCode == Enum.KeyCode.Q then dec = true end
         end)
      )
      FLIB.connect("flames_float_input_ended",
         UIS.InputEnded:Connect(function(i)
            if i.KeyCode == Enum.KeyCode.E then inc = false end
            if i.KeyCode == Enum.KeyCode.Q then dec = false end
         end)
      )
   end

   local offset = 0

   if FLIB.is_alive("flames_float_heartbeat") then
      FLIB.disconnect("flames_float_heartbeat")
   end
   wait(0.1)
   FLIB.connect("flames_float_heartbeat", RunService.RenderStepped:Connect(function()
      if not float_part then return end
      local char_now = myChar() or LocalPlayer.Character
      if not char_now then return end
      local root_now = myRoot() or char_now:FindFirstChild("HumanoidRootPart")
      local hum_now = myHum() or char_now:FindFirstChildOfClass("Humanoid")
      if not root_now or not hum_now then return end
      local hrp_half = (root_now.Size.Y or 2) * 0.5
      local part_half = float_part.Size.Y * 0.5
      local feet_from_root
      if hum_now.RigType == Enum.HumanoidRigType.R6 then
         feet_from_root = hrp_half + (hum_now.HipHeight > 0 and hum_now.HipHeight or 2)
      else
         feet_from_root = hrp_half + (hum_now.HipHeight or 2)
      end

      local base_offset = feet_from_root + part_half
      local moveUp = false
      local moveDown = false
      if isMobile and controlModule then
         local mv = controlModule:GetMoveVector()
         moveUp = hum_now:GetState() == Enum.HumanoidStateType.Jumping
         moveDown = mv.Z > 0.1
      else
         moveUp = inc
         moveDown = dec
      end

      local delta = (moveDown and 1.5) or (moveUp and -1.5) or 0
      offset = math.max(0, base_offset + delta)
      float_part.CFrame = CFrame.new(
         root_now.Position.X,
         root_now.Position.Y - offset,
         root_now.Position.Z
      )
   end))

   if isMobile then
      notify("Success", "GenX Float-V1 enabled (Jump = Up | Move Back = Down)", 5)
   else
      notify("Success", "GenX Float-V1 enabled (Hold E = Up | Hold Q = Down)", 5)
   end
end

stop_flames_float = function()
   if not Float_Running_In_Flames_Hub then notify("Warning", "GenX Float-V1 is not enabled.", 3); return end
   Float_Running_In_Flames_Hub = false
   FLIB.disconnect("flames_float_input_began")
   FLIB.disconnect("flames_float_input_ended")
   FLIB.disconnect("flames_float_heartbeat")
   if float_part then
      float_part:Destroy()
      float_part = nil
   end

   inc = false
   dec = false
   notify("Success", "GenX | Float-V1 is now disabled.", 3)
end

set_spawnpoint = function(delay)
	local hrp = myRoot() or myChar():FindFirstChild("HumanoidRootPart") or get_root(LocalPlayer)
	if not hrp or not hrp.Parent then return end
	spawnpos = hrp.CFrame
	spawnpoint = true
	sp_delay = tonumber(delay) or sp_delay
   notify("Success", "Set SpawnPoint at current Position.", 6)
end

clear_spawnpoint = function()
   if not spawnpos then notify("Error", "You do not have a SpawnPoint set anywhere!", 3); return end
   if not spawnpoint then
      if spawnpos then pcall(function() spawnpos = nil end) end
      notify("Warning", "You do not have SpawnPoint enabled!", 3)
      return
   end

   spawnpoint = false
   spawnpos = nil
   notify("Success", "Cleared SpawnPoint.", 2)
end

ToggleNoclip = function(state)
   local key = "noclip_stepped"
   if state == true then
      if Noclip_Enabled then
         if notify then notify("Warning", "GenX | Noclip is already enabled!", 3) end
         return
      end

      if lib.is_alive(key) then lib.disconnect(key) end
      refresh_parts()
      lib.connect(key, RunService.Stepped:Connect(noclip_step))
      Noclip_Enabled = true
      if notify then notify("Success", "GenX | Noclip has been enabled.", 3) end
   elseif state == false then
      if not Noclip_Enabled then
         if notify then notify("Error", "GenX | Noclip is not enabled!", 3) end
         return
      end

      lib.disconnect(key)
      for i = 1, #noclip_parts do
         local part = noclip_parts[i]
         if part and part.Parent then part.CanCollide = true end
      end

      table.clear(noclip_parts)
      Noclip_Enabled = false
      if notify then notify("Success", "GenX | Noclip has been disabled.", 3) end
   else
      if notify then notify("Error", "Invalid arg, expected true/false", 3); return end
   end
end

EnableAntiFling = function()
	if afEnabled then return end
	afEnabled = true
	antifling_enabled = true
	FLIB.disconnect("antifling")
	FLIB.connect("antifling", RunService.Stepped:Connect(function()
		if not afEnabled then return end
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= Players.LocalPlayer and plr.Character then
				for _, part in ipairs(plr.Character:GetDescendants()) do
					if part:IsA("BasePart") then part.CanCollide = false end
				end
			end
		end
	end))
end

DisableAntiFling = function()
	if not afEnabled then return end
	afEnabled = false
	antifling_enabled = false
	FLIB.disconnect("antifling")
end

Toggle_AntiFling_Boolean_Func = function(flag)
   if flag == true then
      if EnableAntiFling then EnableAntiFling() end
      if ToggleNoclip then ToggleNoclip(true) end
   elseif flag == false then
      if DisableAntiFling then DisableAntiFling() end
      if ToggleNoclip then ToggleNoclip(false) end
   else
      if notify then
         notify("Warning", "Invalid arguments have been provided.", 3)
         return 
      else
         return 
      end
   end
end

anti_void = function(flag)
   local key = "anti_void_stepped"
   if flag == true then
      if Anti_Void_Enabled_Bool then notify("Warning", "GenX | Anti-Void is already enabled.", 3); return end
      if lib.is_alive(key) then notify("Warning", "GenX | Anti-Void is already enabled.", 3); return end
      lib.connect(key, RunService.Stepped:Connect(function()
         local root = myRoot() or myChar() and myChar():FindFirstChild("HumanoidRootPart") or get_root(LocalPlayer)
         if root and root.Position.Y <= originalFPDH + 25 then root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + Vector3.new(0, 300, 0) end
      end))
      Anti_Void_Enabled_Bool = true
      if notify then notify("Success", "GenX | Anti-Void V2 has been enabled.", 5) end
   elseif flag == false then
      if not Anti_Void_Enabled_Bool then notify("Warning", "GenX | Anti-Void is not enabled.", 3); return end
      workspace.FallenPartsDestroyHeight = OrgDestroyHeight
      lib.disconnect(key)
      Anti_Void_Enabled_Bool = false
      if notify then notify("Success", "GenX | Anti-Void V2 has been disabled.", 5) end
   end
end

anti_car_fling = function(state)
   if state == true then
      if VehicleDestroyer_Enabled then
         if notify then notify("Warning", "GenX | Anti Vehicle Fling is already enabled.", 5) end
         return
      end

      VehicleDestroyer_Enabled = true
      table.clear(vehicle_parts_cache)
      local vehicles_folder = Workspace:FindFirstChild("Vehicles")
      if vehicles_folder then setup_vehicles_folder(vehicles_folder) end
      lib.connect("VehicleDestroyer_FolderWatch", Workspace.ChildAdded:Connect(function(child)
         if not VehicleDestroyer_Enabled then return end
         if child.Name == "Vehicles" and child:IsA("Folder") then
            setup_vehicles_folder(child)
         end
      end))
   elseif state == false then
      if not VehicleDestroyer_Enabled then
         if notify then notify("Warning", "Anti Vehicle Fling not enabled.", 5) end
         return
      end

      clear_all()
      if notify then notify("Success", "Anti Vehicle Fling disabled.", 5) end
   end
end

set_fire_state = function(state)
   local da_key  = "anti_fire_descendant_added"
   local hb_key  = "anti_fire_heartbeat"
   if state == true then
      if firehidden then notify("Warning", "GenX | Anti-Fire V2 is already enabled.", 3); return end
      firemanual = true
      firehidden = true
      notify("Success", "GenX | Anti-Fire V2 is now enabled.", 5)
      purge_all_fire()
      if lib.is_alive(da_key) then lib.disconnect(da_key) end
      if lib.is_alive(hb_key) then lib.disconnect(hb_key) end
      task.wait(0.25)
      lib.connect(da_key, workspace.DescendantAdded:Connect(function(obj)
         if not firehidden then return end
         PendingQueue[#PendingQueue + 1] = obj
         QueueDirty = true
      end))
      lib.connect(hb_key, RunService.Heartbeat:Connect(function()
         if not firehidden then return end
         flush_queue()
      end))
   else
      if not firehidden then notify("Warning", "Anti-Fire V2 is not enabled.", 3); return end
      firemanual = false
      firehidden = false
      notify("Success", "Anti-Fire V2 is now disabled.", 5)
      lib.disconnect(da_key)
      lib.disconnect(hb_key)
      PendingQueue = {}
      QueueDirty   = false
   end
end

getHum = function(char, waitSeconds)
	local target
	if char then
		target = NA_GRAB_BODY.asChar(char) or char
	else
		local plr = Players.LocalPlayer
		if plr then target = plr.Character end
	end
	if not target then return nil end
	local hum = target:FindFirstChildOfClass("Humanoid") or target:FindFirstChildOfClass("AnimationController")
	if hum and hum.Parent and hum:IsDescendantOf(game) then return hum end
	local timeout = tonumber(waitSeconds) or 3
	if not timeout or timeout <= 0 then
		local rec = NA_GRAB_BODY.ensure(target)
		return rec and rec.humanoid or nil
	end

	timeout = math.max(0, timeout)
	local deadline = os.clock() + timeout
	local function findHumanoid() return target:FindFirstChildOfClass("Humanoid") or target:FindFirstChildOfClass("AnimationController") end
	while not hum and os.clock() < deadline do
		Wait(0.05)
		hum = findHumanoid()
	end

	if hum and hum.Parent and hum:IsDescendantOf(game) then return hum end
	local rec = NA_GRAB_BODY.ensure(target)
	return rec and rec.humanoid or nil
end

getPlrHum = function(plr) return getHum(plr) end

cleanup_fling_resources = function()
	if loopprotect then
		pcall(function() loopprotect:Destroy() end)
		loopprotect = nil
	end
	if fling_bv then
		pcall(function() fling_bv:Destroy() end)
		fling_bv = nil
	end
end

clear_all = function()
   VehicleDestroyer_Enabled = false
   table.clear(vehicle_parts_cache)
   lib.cleanup_all()
end

flush_queue = function()
   if not QueueDirty then return end
   QueueDirty = false
   local snapshot = PendingQueue
   PendingQueue = {}
   for i = 1, #snapshot do handle_object(snapshot[i]) end
end

noclip_step = function()
   local parts = noclip_parts
   for i = 1, #parts do
      local p = parts[i]
      if p and p.Parent and p.CanCollide then p.CanCollide = false end
   end
end

purge_all_fire = function()
   for _, v in ipairs(workspace:GetDescendants()) do
      if v.ClassName == "Model" and v.Name == "Fire" then
         destroy_fire_model(v)
      elseif is_fire_class(v) then
         disable_fire_object(v)
      end
   end
end

refresh_parts = function()
   table.clear(noclip_parts)
   local Character = myChar() or LocalPlayer.Character or get_char(LocalPlayer, Players.RespawnTime + 1)
   if not Character then return end
   for _, inst in ipairs(Character:GetDescendants()) do if inst:IsA("BasePart") then table.insert(noclip_parts, inst) end end
end

setup_vehicles_folder = function(folder)
   for _, child in ipairs(folder:GetChildren()) do
      if child:IsA("Model") then
         process_veh_model(child)
      elseif child:IsA("BasePart") then
         process_veh_part(child)
      end
   end

   if lib.is_alive("VehicleDestroyer_ChildAdded") then lib.disconnect("VehicleDestroyer_ChildAdded") end
   lib.connect("VehicleDestroyer_ChildAdded", folder.ChildAdded:Connect(function(child)
      if not VehicleDestroyer_Enabled then return end
      if child:IsA("Model") then
         process_veh_model(child)
      elseif child:IsA("BasePart") then
         process_veh_part(child)
      end
   end))

   if notify then notify("Success", "GenX | Anti Vehicle Fling is now enabled.", 5) end
end

destroy_fire_model = function(model)
   for _, v in ipairs(model:GetDescendants()) do
      if is_fire_class(v) then
         disable_fire_object(v)
      end
   end
   pcall(function() model:Destroy() end)
end

disable_fire_object = function(obj)
   pcall(function()
      if obj.ClassName ~= "Beam" then
         obj.Enabled = false
      end
      obj:Destroy()
   end)
end

is_fire_class = function(obj) return FireClasses[obj.ClassName] ~= nil end

handle_object = function(obj)
   if not obj or not obj.Parent then return end
   if obj.ClassName == "Model" and obj.Name == "Fire" then
      destroy_fire_model(obj)
   elseif is_fire_class(obj) then
      disable_fire_object(obj)
   end
end

process_veh_model = function(model)
   if not model or not model.Parent then
      local elapsed = 0
      repeat task.wait(0.5); elapsed = elapsed + 0.5 until (model and model.Parent) or elapsed >= 10
      if not model or not model.Parent then return end
   end

   for _, inst in ipairs(model:GetDescendants()) do if inst:IsA("BasePart") then process_veh_part(inst) end end
   lib.connect(make_key("VehicleDestroyer_DescAdded", model), model.DescendantAdded:Connect(function(desc)
      if not VehicleDestroyer_Enabled then return end
      if desc:IsA("BasePart") then process_veh_part(desc) end
   end))
end

process_veh_part = function(part)
   if not part:IsA("BasePart") then return end
   if vehicle_parts_cache[part] then return end
   local my_vehicle = get_vehicle()
   if my_vehicle and is_in_vehicle(part, my_vehicle) then return end
   part.CanCollide = false
   vehicle_parts_cache[part] = true
   local key = make_key("VehicleDestroyer_PartCleanup", part)
   lib.connect(key, part.AncestryChanged:Connect(function()
      if not part:IsDescendantOf(game) then vehicle_parts_cache[part] = nil; lib.disconnect(key) end
   end))
end

is_in_vehicle = function(obj, vehicle) return vehicle and obj and obj:IsDescendantOf(vehicle) end

make_key = function(prefix, inst) _uid = _uid + 1; return prefix .. "_" .. tostring(inst):gsub("[^%w]", "") .. "_" .. _uid end

Foreach = function(Table, Func, Loop)
	for Index, Value in next, Table do
		pcall(function()
			if Loop and typeof(Value) == 'table' then
				for Index2, Value2 in next, Value do
					Func(Index2, Value2)
				end
			else
				Func(Index, Value)
			end
		end)
	end
end
X.start_flames_float = start_flames_float
X.stop_flames_float = stop_flames_float
X.set_spawnpoint = set_spawnpoint
X.clear_spawnpoint = clear_spawnpoint
X.ToggleNoclip = ToggleNoclip
X.anti_void = anti_void
X.anti_car_fling = anti_car_fling
X.set_fire_state = set_fire_state
X.anti_sit_func = anti_sit_func
X.Toggle_AntiFling_Boolean_Func = Toggle_AntiFling_Boolean_Func
Toggleable_Noclip = ToggleNoclip
end

do
local Anti_Invisible_Players, FlamesLagReducerFunc, RGB_Phone, Spam_Survey_Completions, ToggleNightVision, apply_skin_tone, avgSkin, change_phone_color, change_property, copy_emote_plr, ensureColorCorrection, find_backpack_tool, find_character_tool, find_placed_models_tool, get_plot_of_player, height_func_setter, is_player_invisible, job_spammer, keep_home_locked, night_vision, posteffparts, rainbow_skin, rainbow_tool, saveAndModify, set_invisible, size_func_setter, start_walkfling, stop_walkfling, toggle_house_lock, toggle_rgb_streetlights, update_plot_areas, validWorkspacePart, vehicle_bring_player, width_func_setter
avgSkin = function(bc)
    local skin_tone_colors = {
        bc.HeadColor3,
        bc.LeftArmColor3,
        bc.RightArmColor3,
        bc.TorsoColor3,
        bc.LeftLegColor3,
        bc.RightLegColor3
    }

    local r,g,b = 0,0,0
    for _,c in ipairs(skin_tone_colors) do
        r = r + c.R
        g = g + c.G
        b = b + c.B
    end
    return Color3.new(r/6,g/6,b/6)
end

job_spammer = function(toggle)
    local lib = FLIB
    local key = "job_spammer_loop"
    local fw = lib.wait

    if toggle == true then
        if Every_Job then notify("Warning", "Job spammer is already enabled! disable it first.", 5); return end
        Every_Job = true
        notify("Success", "Job Spammer has been enabled.", 5)
        lib.spawn(key, "spawn", function()
            while Every_Job == true do
            fw(0)
                Send("job", "Police")
                fw(0)
                Send("job", "Firefighter")
                fw(0)
                Send("job", "Baker")
                fw(0)
                Send("job", "Pizza Worker")
                fw(0)
                Send("job", "Barista")
                fw(0)
                Send("job", "Doctor")
                fw(0)
            end
            lib.disconnect(key)
        end)
    elseif toggle == false then
        if not Every_Job then notify("Warning", "Job spammer is not enabled! enable it first.", 5); return end
        Every_Job = false
        lib.disconnect(key)
        notify("Success", "Job Spammer has been disabled.", 5)
    end
end

Spam_Survey_Completions = function(state)
    if state == true then
        Spam_And_Spoof_Survey_Submissions = true
        notify("Success", "GenX | Life Together RP survey spammer is now active.", 3)
        FLIB.spawn("spam_survey_completions", "spawn", function()
            while Spam_And_Spoof_Survey_Submissions == true do
            task.wait(0)
                local Survey_Args = {
                    "survey_completed",
                    "5",
                    {
                        {
                            questionKey = "question_1",
                            answerKeys = {"question_5"}
                        },
                        {
                            answerKey = "question_2",
                            questionKey = "question_2"
                        },
                        {
                            questionKey = "question_3",
                            answerKeys = {"question_2"}
                        },
                        {
                            answerKey = "answer_2",
                            questionKey = "question_4"
                        },
                        {
                            answerKey = "answer_1",
                            questionKey = "question_5"
                        }
                    },
                    {
                        platform = spoofed_platforms[math.random(1, #spoofed_platforms)],
                        localeId = locale_ids[math.random(1, #locale_ids)],
                        sdkVersion = matrix_ids[math.random(1, #matrix_ids)]
                    }
                }
                Send(unpack(Survey_Args))
            end
        end)
    elseif state == false then
        Spam_And_Spoof_Survey_Submissions = false
        FLIB.disconnect("spam_survey_completions")
        notify("Success", "GenX | Life Together RP survey spammer is now disabled.", 3)
    else
        return 
    end
end

copy_emote_plr = function(player)
    local targetChar = player.Character or get_char(player)
    local targetHum = targetChar and targetChar:FindFirstChildWhichIsA("Humanoid") or get_human(player, Players.RespawnTime + 1)
    local myChar = myChar() or LocalPlayer.Character or get_char(LocalPlayer, Players.RespawnTime + 1)
    local myHum = myHum() or myChar and myChar:FindFirstChildWhichIsA("Humanoid") or get_human(LocalPlayer, Players.RespawnTime + 1)
    if not (targetHum and myHum) then return end
    for _, track in ipairs(myHum:GetPlayingAnimationTracks()) do pcall(function() track:Stop() end) end
    wait(0.05)
    for _, tTrack in ipairs(targetHum:GetPlayingAnimationTracks()) do
        local animObj = tTrack.Animation
        if animObj and animObj:IsA("Animation") then
            local id = tostring(animObj.AnimationId)
            if id and id ~= "" and id ~= "0" and not id:find("507768375") then
                local newAnim = Instance.new("Animation")
                newAnim.AnimationId = id
                local myTrack = nil
                pcall(function() myTrack = myHum:LoadAnimation(newAnim) end)
                if myTrack and myTrack:IsA("Animation") then
                    myTrack:Play(0.1, 1, tTrack.Speed)
                    myTrack.TimePosition = tTrack.TimePosition
                    TrackHasBeenStopped_Watcher_Task = TrackHasBeenStopped_Watcher_Task or task.spawn(function()
                        tTrack.Stopped:Wait()
                        pcall(function() myTrack:Stop() end)
                        pcall(function() myTrack:Destroy() end)
                        pcall(function() newAnim:Destroy() end)
                    end)
                else
                    newAnim:Destroy()
                end
            end
        end
    end
end

rainbow_skin = function(state)
    local lib = FLIB
    local name = "rainbow_skin"
    local char = myChar() or LocalPlayer.Character or get_char(LocalPlayer, Players.RespawnTime + 1)
    if not char or not char:IsDescendantOf(game) then return end
    local bodycolors = char and char:FindFirstChildOfClass("BodyColors")
    if not bodycolors then return end
    if state == true then
        if rainbow_skintone_currently_enabled then notify("Warning", "GenX - Rainbow Skin is already enabled.", 5); return end
        original_skintone = {
            HeadColor3 = bodycolors.HeadColor3,
            LeftArmColor3 = bodycolors.LeftArmColor3,
            RightArmColor3 = bodycolors.RightArmColor3,
            LeftLegColor3 = bodycolors.LeftLegColor3,
            RightLegColor3 = bodycolors.RightLegColor3,
            TorsoColor3 = bodycolors.TorsoColor3
        }

        notify("Success", "GenX | Rainbow Skin is now enabled.", 5)
        lib.spawn(name, "spawn", function()
            while true do
                for _, c in ipairs(COLORS) do
                    Send("skin_tone", c)
                    wait(.1)
                end
            end
        end)
    elseif state == false then
        if not lib.is_alive(name) then return end
        lib.disconnect(name)
        fw(0.2)
        if original_skintone then
            local old = original_skintone
            Send("skin_tone", old.HeadColor3)
            wait()
            Send("skin_tone", old.LeftArmColor3)
            wait()
            Send("skin_tone", old.RightArmColor3)
            wait()
            Send("skin_tone", old.LeftLegColor3)
            wait()
            Send("skin_tone", old.RightLegColor3)
            wait()
            Send("skin_tone", old.TorsoColor3)
            notify("Success", "Reset SkinTone back to your old SkinTone.", 3)
        end
        notify("Success", "GenX | Rainbow Skin is now disabled.", 5)
    end
end

local RGB_KEY = "rgb_phone_loop"
RGB_Phone = function(Boolean)
    local lib = FLIB

    if Boolean == true then
        if RGB_Rainbow_Phone then notify("Warning", "RGB/Rainbow Phone is already enabled.", 3); return end
        RGB_Rainbow_Phone = true
        notify("Success", "Started RGB/Rainbow Phone.", 3)
        lib.spawn(RGB_KEY, "spawn", function()
            while RGB_Rainbow_Phone == true do
                for _, color in ipairs(COLORS) do
                    if RGB_Rainbow_Phone ~= true then return end
                    change_phone_color(color)
                    fw(0)
                end
            end
        end)
    elseif Boolean == false then
        if not RGB_Rainbow_Phone then notify("Warning", "RGB/Rainbow Phone is not enabled.", 3); return end
        RGB_Rainbow_Phone = false
        lib.disconnect(RGB_KEY)
        notify("Success", "Stopped RGB/Rainbow Phone.", 3)
        fw(0.1)
        change_phone_color(Color3.fromRGB(255, 255, 255))
    end
end

change_phone_color = function(New_Color) Send("phone_color", New_Color) end

rainbow_tool = function(toggled)
    if toggled then
        notify("Success", "GenX | RGB Tools is now enabled.", 5)
        local tool = find_character_tool() or find_backpack_tool() or find_placed_models_tool()
        if not tool then
            Send("get_tool", "Gift")
            notify("Warning", "Wait! We're giving you a colorable Tool...", 5)
            fw(0.2)
            tool = find_character_tool() or find_backpack_tool() or find_placed_models_tool()
            if not tool then notify("Error", "Tool still not found after giving you the Gift Tool.", 5); return end
            if tool.Parent == (LocalPlayer:FindFirstChildOfClass("Backpack")) then
                fw(0.1)
                tool.Parent = myChar()
            end

            for _, color in ipairs(COLORS) do
                Send("tool_color", tool, "color1", color)
                wait()
            end
        end

        if tool.Parent == (LocalPlayer:FindFirstChildOfClass("Backpack")) then
            fw(0.1)
            tool.Parent = myChar()
        end

        Rainbow_Tools_FE = true
        while Rainbow_Tools_FE do
            tool = find_character_tool() or find_backpack_tool() or find_placed_models_tool()
            if not tool then
                Rainbow_Tools_FE = false
                notify("Error", "Tool unexpectedly disappeared or was destroyed.", 5)
                return 
            end
            if tool.Parent == (LocalPlayer:FindFirstChildOfClass("Backpack")) then
                fw(0.1)
                tool.Parent = myChar()
            end
            for _, color in ipairs(COLORS) do
                if not Rainbow_Tools_FE then break end
                Send("tool_color", tool, "color1", color)
                wait()
            end
        end
    else
        if not Rainbow_Tools_FE then notify("Warning", "GenX | RGB Tools is not enabled!", 5); return end
        Rainbow_Tools_FE = false
        notify("Success", "GenX | RGB Tools is now disabled.", 5)
    end
end

height_func_setter = function(height_input)
    if height_setter_busy then return end
    height_setter_busy = true
    local player = LocalPlayer
    local char = myChar() or player and player.Character
    local hum = myHum() or char and char:FindFirstChildOfClass("Humanoid")
    if not hum then
        height_setter_busy = false
        return
    end

    local desc = hum:GetAppliedDescription()
    if not desc then
        height_setter_busy = false
        notify("Error", "Failed to grab HumanoidDescription.", 3)
        return 
    end

    local bodyColors = char and char:FindFirstChildOfClass("BodyColors")
    local current_skin = bodyColors and avgSkin(bodyColors)
    if not session_active then
        session_original_height = desc.HeightScale or 1
        session_original_width = desc.WidthScale or 1
        session_original_skin = current_skin
        session_active = true
    end

    if current_skin then
        prev_skin_tone = last_skin_tone or current_skin
        last_skin_tone = current_skin
    end

    local height = tonumber(height_input) or desc.HeightScale or 1
    prev_height_scale = last_height_scale or desc.HeightScale or 1
    last_height_scale = height
    local properties = {
        Head = desc.Head or 0,
        Torso = desc.Torso or 0,
        LeftArm = desc.LeftArm or 0,
        RightArm = desc.RightArm or 0,
        LeftLeg = desc.LeftLeg or 0,
        RightLeg = desc.RightLeg or 0,
        Face = desc.Face or 0,
        Shirt = desc.Shirt or 0,
        Pants = desc.Pants or 0,
        GraphicTShirt = desc.GraphicTShirt or 0,
        RunAnimation = desc.RunAnimation or 0,
        WalkAnimation = desc.WalkAnimation or 0,
        JumpAnimation = desc.JumpAnimation or 0,
        FallAnimation = desc.FallAnimation or 0,
        ClimbAnimation = desc.ClimbAnimation or 0,
        IdleAnimation = desc.IdleAnimation or 0,
        SwimAnimation = desc.SwimAnimation or 0,
        HeightScale = height,
        WidthScale = desc.WidthScale or 1,
        DepthScale = desc.DepthScale or 1,
        HeadScale = desc.HeadScale or 1,
        BodyTypeScale = desc.BodyTypeScale or 0,
        ProportionScale = desc.ProportionScale or 0,
    }

    local accessories = {}
    for _, acc in ipairs(desc:GetAccessories(true)) do
        table.insert(accessories,{
            Rotation = "  ",
            Position = "  ",
            Scale = "1 1 1",
            IsLayered = acc.IsLayered,
            AccessoryType = acc.AccessoryType.Name,
            AssetId = acc.AssetId,
            Order = acc.Order,
            Puffiness = acc.Puffiness
        })
    end

    pcall(function()
        Send("wear_outfit_from_desc", {
            accessories = accessories,
            properties = properties
        })
    end)

    task.delay(0.10, function()
        apply_skin_tone(session_original_skin)
        height_setter_busy = false
    end)
end

width_func_setter = function(width_input)
    if width_setter_busy then return end
    width_setter_busy = true
    local char = myChar() or LocalPlayer.Character or get_char(LocalPlayer) or CharMod:get()
    local hum = myHum() or char and char:FindFirstChildOfClass("Humanoid") or get_human(LocalPlayer) or CharMod:get_human()
    if not hum then
        width_setter_busy = false
        return
    end

    local desc = hum:GetAppliedDescription()
    if not desc then
        width_setter_busy = false
        notify("Error", "Failed to grab HumanoidDescription.", 3)
        return
    end

    local body_colors = char and char:FindFirstChildOfClass("BodyColors")
    local current_skin = body_colors and avgSkin(body_colors)
    if not session_width_active then
        session_original_width_only = desc.WidthScale or 1
        session_original_skin_w = current_skin
        session_width_active = true
    end

    if current_skin then
        prev_skin_tone_w = last_skin_tone_w or current_skin
        last_skin_tone_w = current_skin
    end

    local width = tonumber(width_input) or desc.WidthScale or 1
    prev_width_scale_only = last_width_scale_only or desc.WidthScale or 1
    last_width_scale_only = width
    local properties = {
        Head = desc.Head or 0,
        Torso = desc.Torso or 0,
        LeftArm = desc.LeftArm or 0,
        RightArm = desc.RightArm or 0,
        LeftLeg = desc.LeftLeg or 0,
        RightLeg = desc.RightLeg or 0,
        Face = desc.Face or 0,
        Shirt = desc.Shirt or 0,
        Pants = desc.Pants or 0,
        GraphicTShirt = desc.GraphicTShirt or 0,
        RunAnimation = desc.RunAnimation or 0,
        WalkAnimation = desc.WalkAnimation or 0,
        JumpAnimation = desc.JumpAnimation or 0,
        FallAnimation = desc.FallAnimation or 0,
        ClimbAnimation = desc.ClimbAnimation or 0,
        IdleAnimation = desc.IdleAnimation or 0,
        SwimAnimation = desc.SwimAnimation or 0,
        HeightScale = desc.HeightScale or 1,
        WidthScale = width,
        DepthScale = desc.DepthScale or 1,
        HeadScale = desc.HeadScale or 1,
        BodyTypeScale = desc.BodyTypeScale or 0,
        ProportionScale = desc.ProportionScale or 0,
    }

    local accessories = {}
    for _, acc in ipairs(desc:GetAccessories(true)) do
        table.insert(accessories, {
            Rotation = "  ",
            Position = "  ",
            Scale = "1 1 1",
            IsLayered = acc.IsLayered,
            AccessoryType = acc.AccessoryType.Name,
            AssetId = acc.AssetId,
            Order = acc.Order,
            Puffiness = acc.Puffiness
        })
    end

    pcall(function()
        Send("wear_outfit_from_desc", {
            accessories = accessories,
            properties = properties
        })
    end)

    task.delay(0.10, function()
        if session_original_skin_w then
            apply_skin_tone(session_original_skin_w)
        end
        width_setter_busy = false
    end)
end

size_func_setter = function(width_input, depth_input)
    if size_setter_busy then return end
    size_setter_busy = true
    local char = myChar() or LocalPlayer.Character or get_char(LocalPlayer) or CharMod:get()
    local hum = myHum() or char and char:FindFirstChildOfClass("Humanoid") or get_human(LocalPlayer)
    if not hum then size_setter_busy = false; return end
    local desc = hum:GetAppliedDescription()
    if not desc then
        size_setter_busy = false
        notify("Error", "Failed to grab HumanoidDescription.", 3)
        return
    end

    local body_colors = char and char:FindFirstChildOfClass("BodyColors")
    local current_skin = body_colors and avgSkin(body_colors)
    if not session_size_active then
        session_original_width = desc.WidthScale or 1
        session_original_depth = desc.DepthScale or 1
        session_original_skin = session_original_skin or current_skin
        session_size_active = true
    end

    if current_skin then
        prev_skin_tone_s = last_skin_tone_s or current_skin
        last_skin_tone_s = current_skin
    end

    local width = tonumber(width_input) or desc.WidthScale or 1
    local depth = tonumber(depth_input) or desc.DepthScale or 1
    prev_width_scale = last_width_scale or desc.WidthScale or 1
    prev_depth_scale = last_depth_scale or desc.DepthScale or 1
    last_width_scale = width
    last_depth_scale = depth
    local properties = {
        Head = desc.Head or 0,
        Torso = desc.Torso or 0,
        LeftArm = desc.LeftArm or 0,
        RightArm = desc.RightArm or 0,
        LeftLeg = desc.LeftLeg or 0,
        RightLeg = desc.RightLeg or 0,
        Face = desc.Face or 0,
        Shirt = desc.Shirt or 0,
        Pants = desc.Pants or 0,
        GraphicTShirt = desc.GraphicTShirt or 0,
        RunAnimation = desc.RunAnimation or 0,
        WalkAnimation = desc.WalkAnimation or 0,
        JumpAnimation = desc.JumpAnimation or 0,
        FallAnimation = desc.FallAnimation or 0,
        ClimbAnimation = desc.ClimbAnimation or 0,
        IdleAnimation = desc.IdleAnimation or 0,
        SwimAnimation = desc.SwimAnimation or 0,
        HeightScale = desc.HeightScale or 1,
        WidthScale = width,
        DepthScale = depth,
        HeadScale = desc.HeadScale or 1,
        BodyTypeScale = desc.BodyTypeScale or 0,
        ProportionScale = desc.ProportionScale or 0,
    }

    local accessories = {}
    for _, acc in ipairs(desc:GetAccessories(true)) do
        table.insert(accessories, {
            Rotation = "  ",
            Position = "  ",
            Scale = "1 1 1",
            IsLayered = acc.IsLayered,
            AccessoryType = acc.AccessoryType.Name,
            AssetId = acc.AssetId,
            Order = acc.Order,
            Puffiness = acc.Puffiness
        })
    end

    pcall(function()
        Send("wear_outfit_from_desc", {
            accessories = accessories,
            properties = properties
        })
    end)

    task.delay(0.10, function()
        apply_skin_tone(session_original_skin)
        size_setter_busy = false
    end)
end

apply_skin_tone = function(color) if not color then return end; pcall(function() Send("skin_tone", color) end) end

change_property = function(property, new_property_value)
    local properties_allowed_to_be_changed = {
        WalkSpeed = true,
        JumpHeight = true,
        HipHeight = true
    }

    if properties_allowed_to_be_changed[property] and myHum() then myHum()[property] = new_property_value end
end

FlamesLagReducerFunc = function(toggle)
    if toggle then
        if ultimate_lag_reducer then notify("Warning", "GenX | Lag Reducer : is already enabled.", 3); return end
        ultimate_lag_reducer = true
        notify("Success", "GenX | Lag Reducer : is now enabled.", 5)
        pcall(function() Send("hide_other_names", true) end)
        pcall(function() Send("hide_map_icon", true) end)
        if togglergbflows and typeof(togglergbflows) == "function" then pcall(togglergbflows, false) end
        posteffparts(true)
    else
        if not ultimate_lag_reducer then notify("Warning", "GenX | Lag Reducer : is not enabled.", 3); return end
        ultimate_lag_reducer = false
        notify("Success", "GenX | Lag Reducer : is now disabled.", 5)
        pcall(function() Send("hide_other_names", false) end)
        pcall(function() Send("hide_map_icon", false) end)
        posteffparts(false)
    end
end

posteffparts = function(toggle)

    if toggle then
        if genv.post_effects_off_main then return end
        genv.post_effects_off_main = true
        table.clear(genv.stored_effects_main_tbl)
        table.clear(genv.stored_parts_main_tbl)
        table.clear(genv.parts_seen)
        for _, v in ipairs(lighting:GetDescendants()) do
            if v:IsA("PostEffect") then
                table.insert(genv.stored_effects_main_tbl, {inst = v, enabled = v.Enabled})
                v.Enabled = false
            end
        end

        for _, v in ipairs(work:GetDescendants()) do
            if validWorkspacePart(v) then
                saveAndModify(v)
            end
        end

        genv._saved_fog_start = lightinFogStart
        genv._saved_fog_end = lightinFogEnd
        lightinFogStart = 1e5
        lightinFogEnd = 1e5

        if genv.parts_disabler_conn then genv.parts_disabler_conn:Disconnect() end
        genv.parts_disabler_conn = work.DescendantAdded:Connect(function(child)
            if not genv.post_effects_off_main then return end
            if not validWorkspacePart(child) then return end
            task.defer(function()
                if child.Parent then
                    saveAndModify(child)
                end
            end)
        end)
    else
        if not genv.post_effects_off_main then return end
        genv.post_effects_off_main = false

        for _, v in ipairs(genv.stored_effects_main_tbl) do
            if v.inst and v.inst.Parent then
                v.inst.Enabled = v.enabled
            end
        end

        for _, data in ipairs(genv.stored_parts_main_tbl) do
            if data.inst and data.inst.Parent then
                if data.prop == "cast" then
                    data.inst.CastShadow = data.val
                elseif data.prop == "decal" then
                    data.inst.Transparency = data.transp
                    data.inst.Texture = data.tex
                elseif data.prop == "particle" then
                    data.inst.Enabled = data.enabled
                    data.inst.Rate = data.rate
                elseif data.prop == "trail" then
                    data.inst.Enabled = data.enabled
                end
            end
        end

        if genv.parts_disabler_conn then
            genv.parts_disabler_conn:Disconnect()
            genv.parts_disabler_conn = nil
        end

        if genv._saved_fog_start then lightinFogStart = genv._saved_fog_start end
        if genv._saved_fog_end then lightinFogEnd = genv._saved_fog_end end
        table.clear(genv.stored_effects_main_tbl)
        table.clear(genv.stored_parts_main_tbl)
        table.clear(genv.parts_seen)
    end
end

toggle_rgb_streetlights = function(toggle)
    if toggle == true then
        if genv.RGB_Street_Lights_NightTime_Loop or genv.StreetLightRainbowConnection then notify("Warning", "RGB/Rainbow StreetLights is already running!", 5); return end
        local Map = workspace:FindFirstChild("Map", true)
        if not Map then notify("Error", "Map Folder not found inside of Workspace!", 5); return end
        local StreetLs = Map:FindFirstChild("StreetLights", true)
        if not StreetLs then notify("Error", "StreetLights not found inside of Map Folder!", 5); return end
        if typeof(genv.all_street_lights) ~= "table" then genv.all_street_lights = {} end
        if next(genv.all_street_lights) == nil then
            for _, v in ipairs(StreetLs:GetDescendants()) do
                if v:IsA("PointLight") then
                table.insert(genv.all_street_lights, v)
                end
            end
        end

        local hue = 0
        genv.RGB_Street_Lights_NightTime_Loop = true
        notify("Success", "RGB/Rainbow StreetLights enabled, they will only animate at night.", 10)
        genv.StreetLightRainbowConnection = RunService.Heartbeat:Connect(function(dt)
            local clock_time = LightinClockTime
            if clock_time < 18.5 and clock_time > 7.5 then return end
            hue = (hue + dt * 0.0833) % 1
            local color = Color3.fromHSV(hue, 1, 1)
            for i = #genv.all_street_lights, 1, -1 do
                local light = genv.all_street_lights[i]
                if not light or not light.Parent then
                    table.remove(genv.all_street_lights, i)
                else
                    light.Color = color
                end
            end
        end)
    elseif toggle == false then
        if not genv.RGB_Street_Lights_NightTime_Loop then notify("Warning", "RGB/Rainbow StreetLights is not enabled!", 5); return end
        genv.RGB_Street_Lights_NightTime_Loop = false
        if genv.StreetLightRainbowConnection then
            genv.StreetLightRainbowConnection:Disconnect()
            genv.StreetLightRainbowConnection = nil
        end
        notify("Success", "RGB/Rainbow StreetLights disabled.", 10)
    end
end

toggle_house_lock = function(player)
    local plotInstance = select(1, get_plot_of_player(player))
    if not plotInstance then return end
    Send("lock_home", plotInstance)
end

keep_home_locked = function(toggle)
    if toggle then
        if LockHomeLoop then notify("Warning", "GenX | Auto Lock Home is already enabled.", 5); return end
        LockHomeLoop = true
        LockHomeToken = (LockHomeToken or 0) + 1
        local myToken = LockHomeToken
        notify("Success", "GenX | Auto Lock Home is now enabled.", 5)
        task.spawn(function()
            while LockHomeLoop and myToken == LockHomeToken do
                fw(0.2)
                local plot_list = PlotMarker and PlotMarker.class and PlotMarker.class.objects
                if plot_list then
                    for _, plot in pairs(plot_list) do
                        if myToken ~= LockHomeToken then return end
                        local okOwner, owner = pcall(function() return plot.states.owner.get() end)
                        if okOwner and owner == LocalPlayer then
                            local id = plot.instance:GetDebugId()
                            if LockHouse_LastState[id] == nil then LockHouse_LastState[id] = plot.states.locked.get() end
                            local locked = plot.states.locked.get()
                            local last = LockHouse_LastState[id]
                            if locked == false and last == true then
                                toggle_house_lock(LocalPlayer)
                                LockHouse_LastState[id] = true
                            else
                                LockHouse_LastState[id] = locked
                            end
                        end
                    end
                end
            end
        end)
    else
        if not LockHomeLoop then notify("Warning", "GenX | Auto Lock Home is not enabled.", 5); return end
        LockHomeLoop = false
        LockHomeToken = (LockHomeToken or 0) + 1
        table.clear(LockHouse_LastState)
        notify("Success", "GenX | Auto Lock Home is now disabled.", 5)
    end
end

Anti_Invisible_Players = function(state)
    Anti_Invisible_Players_Currently_Active = state
    if not state then
        FLIB.disconnect("anti_invis_player_added")
        FLIB.disconnect("anti_invis_char_added")
        FLIB.disconnect("anti_invis_loop")
        return
    end

    local function fix_invisible(plr)
        if not Anti_Invisible_Players_Currently_Active then return end
        local char = plr.Character or get_char(plr)
        if not char then return end
        if not is_player_invisible(plr) then return end
        pcall(function()
            for _, v in ipairs(char:GetDescendants()) do
                if v:IsA("MeshPart") then
                    v.Transparency = 0
                end
            end
        end)
    end

    for _, plr in ipairs(Players:GetPlayers()) do fix_invisible(plr) end
    FLIB.connect("anti_invis_player_added", Players.PlayerAdded:Connect(function(plr)
        if not Anti_Invisible_Players_Currently_Active then return end
        fix_invisible(plr)
    end))

    FLIB.connect("anti_invis_char_added", Players.PlayerAdded:Connect(function(plr)
        plr.CharacterAdded:Connect(function()
            if not Anti_Invisible_Players_Currently_Active then return end
            task.wait(0.5)
            fix_invisible(plr)
        end)
    end))

    FLIB.spawn("anti_invis_loop", "spawn", function()
        while Anti_Invisible_Players_Currently_Active == true do
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then
                    fix_invisible(plr)
                end
            end
            fw(3)
        end
    end)
end

set_invisible = function(state)
    is_invisible_script_toggled = state and true or false
    if is_invisible_script_toggled then
        notify("Info", "You can still use the chat, but people won't be able to see it directly above your head.", 10)
    end

    for part, original in pairs(invisible_body_parts) do
        if part and part.Parent then
            part.Transparency = is_invisible_script_toggled and 0.5 or original
        end
    end
end

is_player_invisible = function(plr)
    local char = plr.Character or get_char(plr)
    if not char then return false end
    local parts = {}
    for _, v in ipairs(char:GetDescendants()) do
        if v:IsA("MeshPart") then
            table.insert(parts, v)
        end
    end

    if #parts == 0 then return false end
    for _, v in ipairs(parts) do if v.Transparency ~= 1 then return false end end
    return true
end

update_plot_areas = function()
    table.clear(PlotAreas)
    fw(0.2)
    for _, v in ipairs(Workspace:GetDescendants()) do
        if v:IsA("BasePart") and v.Name == "PlotArea" then
            PlotAreas[v] = v
        end
    end
end

find_backpack_tool = function()
    for _, v in ipairs((LocalPlayer:FindFirstChildOfClass("Backpack")):GetChildren()) do
        if v:IsA("Tool") and (v:GetAttribute("color1") or v:GetAttribute("Color1")) then
            return v
        end
    end
    return nil
end

find_character_tool = function()
    for _, v in ipairs(myChar():GetChildren()) do
        if v:IsA("Tool") and (v:GetAttribute("color1") or v:GetAttribute("Color1")) then
            return v
        end
    end
    return nil
end

find_placed_models_tool = function()
    for _, v in ipairs(Workspace:FindFirstChild("PlacedModels"):GetChildren()) do
        if v:IsA("Model") and (v:GetAttribute("color1") or v:GetAttribute("Color1")) then
            if v:GetAttribute("owner_id") == LocalPlayer.UserId then
                return v
            end
        end
    end
    return nil
end

get_plot_of_player = function(player)
    if not player then return nil, "No player provided" end
    local plotList = PlotMarker and PlotMarker.class and PlotMarker.class.objects
    if type(plotList) ~= "table" then return nil, "Plots not available" end
    for _, plot in pairs(plotList) do
        if plot and plot.states and plot.states.owner and typeof(plot.states.owner.get) == "function" and plot.instance then
            local ok, owner = pcall(function() return plot.states.owner.get() end)
            if ok and owner == player then  return plot.instance, plot end
        end
    end

    return nil, "Player has no plot"
end

validWorkspacePart = function(inst)
    if not inst or not inst.Parent then return false end
    if inst:IsDescendantOf(lighting) then return false end
    if inst:IsDescendantOf(LocalPlayer.Character or Instance.new("Folder")) then return false end
    return true
end

saveAndModify = function(inst)
    if parts_seen[inst] then return end
    parts_seen[inst] = true
    if inst:IsA("BasePart") then
        table.insert(stored_parts_main_tbl, {inst = inst, prop = "cast", val = inst.CastShadow})
        inst.CastShadow = false
    elseif inst:IsA("Decal") then
        table.insert(stored_parts_main_tbl, {inst = inst, prop = "decal", tex = inst.Texture, transp = inst.Transparency})
        inst.Transparency = 1
        inst.Texture = ""
    elseif inst:IsA("ParticleEmitter") then
        table.insert(stored_parts_main_tbl, {inst = inst, prop = "particle", enabled = inst.Enabled, rate = inst.Rate})
        inst.Enabled = false
        inst.Rate = 0
    elseif inst:IsA("Trail") then
        table.insert(stored_parts_main_tbl, {inst = inst, prop = "trail", enabled = inst.Enabled})
        inst.Enabled = false
    end
end

stop_walkfling = function()
    if not walkflinging then notify("Error", "GenX | WalkFling-V3.5 is not enabled.", 5); return end
    walkflinging = false
    TouchingWhitelisted = {}
    FLIB.disconnect("walkflinger")
    for _, conn in pairs(WalkFlingConnections) do conn:Disconnect() end
    WalkFlingConnections = {}
    if WalkFlingRespawnConn then
        WalkFlingRespawnConn:Disconnect()
        WalkFlingRespawnConn = nil
    end

    if Noclip_Enabled then Toggleable_Noclip(false) end
    local root = myRoot()
    if root then root.Velocity = Vector3.zero end
    local hum = myHum() or myChar():FindFirstChildOfClass("Humanoid") or get_human(LocalPlayer or Players.LocalPlayer)
    if hum then hum.PlatformStand = false; hum:ChangeState(Enum.HumanoidStateType.GettingUp) end
    notify("Success", "GenX | WalkFling-V3.5 has been stopped/disabled.", 5)
end

start_walkfling = function()
    if walkflinging then notify("Warning", "GenX | WalkFling-V3.5 is already enabled!", 5); return end
    walkflinging = true
    TouchingWhitelisted = {}
    if not Noclip_Enabled then Toggleable_Noclip(true) end
    notify("Success", "GenX | WalkFling-V3.5 is now enabled.", 5)
    local function connect_touch_fling(character)
        for _, conn in pairs(WalkFlingConnections) do conn:Disconnect() end
        WalkFlingConnections = {}
        TouchingWhitelisted = {}
        for _, part in ipairs(character:GetChildren()) do
            if part:IsA("BasePart") then
                local touch_conn = part.Touched:Connect(function(hit)
                    if not walkflinging then return end
                    local hit_char = hit.Parent
                    while hit_char and not Players:GetPlayerFromCharacter(hit_char) and hit_char.Parent ~= workspace do hit_char = hit_char.Parent end
                    local hit_player = Players:GetPlayerFromCharacter(hit_char)
                    if not hit_player or hit_player == LocalPlayer then return end
                    if is_whitelisted(hit_player) then
                        TouchingWhitelisted[hit_player.UserId] = true
                        return
                    end

                    if next(TouchingWhitelisted) then return end
                    local hit_root = hit_char:FindFirstChild("HumanoidRootPart")
                    if not hit_root then return end
                    local root = myRoot()
                    local v = root and root.CFrame.LookVector or Vector3.zero
                    local power = 10000
                    hit_root.Velocity = v * power + Vector3.new(0, power, 0)
                    RunService.RenderStepped:Wait()
                    if hit_root then hit_root.Velocity = v * power end
                    RunService.RenderStepped:Wait()
                    if hit_root then hit_root.Velocity = v * power + Vector3.new(0, 0.1, 0) end
                end)

                local untouch_conn = part.TouchEnded:Connect(function(hit)
                    local hit_char = hit.Parent
                    while hit_char and not Players:GetPlayerFromCharacter(hit_char) and hit_char.Parent ~= workspace do hit_char = hit_char.Parent end
                    local hit_player = Players:GetPlayerFromCharacter(hit_char)
                    if hit_player and is_whitelisted(hit_player) then TouchingWhitelisted[hit_player.UserId] = nil end
                end)
                table.insert(WalkFlingConnections, touch_conn)
                table.insert(WalkFlingConnections, untouch_conn)
            end
        end
    end

    local char = myChar() or LocalPlayer.Character or get_char(LocalPlayer, 3)
    if char then connect_touch_fling(char) end
    if WalkFlingRespawnConn then
        WalkFlingRespawnConn:Disconnect()
        WalkFlingRespawnConn = nil
    end
    wait(0.25)
    WalkFlingRespawnConn = LocalPlayer.CharacterAdded:Connect(function(new_char) if walkflinging then connect_touch_fling(new_char) end end)
    FLIB.disconnect("walkflinger")
    FLIB.connect("walkflinger", RunService.Heartbeat:Connect(function()
        if not walkflinging then return end
        local m = myChar() or get_char(LocalPlayer, 3)
        local r = m and (myRoot() or m:FindFirstChild("HumanoidRootPart"))
        if not r then return end
        local v = r.Velocity
        r.Velocity = v * 10000 + Vector3.new(0, 10000, 0)
        RunService.RenderStepped:Wait()
        if r then r.Velocity = v end
        RunService.RenderStepped:Wait()
        if r then r.Velocity = v + Vector3.new(0, 0.1, 0) end
    end))
end

vehicle_bring_player = function(TargetPlayer)
    if not TargetPlayer or not TargetPlayer.Character then return end
    local TargetChar = TargetPlayer.Character
    local Target_HRP = TargetChar:FindFirstChild("HumanoidRootPart")
    if not Target_HRP then return end
    local Old_CF = myChar():FindFirstChild("HumanoidRootPart").CFrame
    local MyChar = myChar() or LocalPlayer.Character or get_char(LocalPlayer)
    if not MyChar then return end
    local MyHumanoid = myHum() or MyChar and MyChar:FindFirstChildWhichIsA("Humanoid") or get_human(LocalPlayer)
    if not MyHumanoid or not MyHumanoid.Parent or not MyHumanoid:IsDescendantOf(game) then return end
    local MyBus = nil
    local folder = vehicles_folder_cache or find_vehicles_folder()
    if not folder or not folder:IsA("Folder") then return end

    for _, v in ipairs(folder:GetChildren()) do
        if v:IsA("Model") and v:FindFirstChild("owner") and v.owner.Value == LocalPlayer then
            if v:FindFirstChildOfClass("VehicleSeat") then
                MyBus = v
                break
            end
        end
    end

    if not MyBus then notify("Error", "No spawned vehicle found.", 3); return end
    local seat = MyBus and MyBus:FindFirstChildOfClass("VehicleSeat")
    if seat and seat:IsA("VehicleSeat") and MyHumanoid and MyHumanoid.Parent then
        MyChar:PivotTo(seat.CFrame)
        task.wait(0.2)
        seat:Sit(MyHumanoid)
    end

    local max_tries = 40
    for i = 1, max_tries do
        local TargetHumanoid = TargetChar:FindFirstChildOfClass("Humanoid") or get_human(TargetPlayer)
        local Is_Sitting = TargetHumanoid and TargetHumanoid.Sit
        if Is_Sitting then break end
        MyBus:PivotTo(Target_HRP.CFrame + Vector3.new(0, 0.3, 0))
        task.wait(0.4)
    end
    wait(0.1)
    MyBus:PivotTo(Old_CF)
    wait(0.4)
    local My_HRP = myRoot() or myChar():FindFirstChild("HumanoidRootPart") or get_root(LocalPlayer)
    if MyHumanoid and My_HRP.Parent and My_HRP:IsDescendantOf(game) and MyHumanoid.Sit then
        pcall(function() MyHumanoid:ChangeState(3) end)
        wait(0.1)
        My_HRP.CFrame = Old_CF
        wait(0.5)
        if not get_vehicle() then return end
        spawn_any_vehicle(tostring(get_vehicle().Name))
    end

    if My_HRP and My_HRP.Parent then
        My_HRP.CFrame = Old_CF
        wait(0.5)
        if not get_vehicle() then return end
        spawn_any_vehicle(tostring(get_vehicle().Name))
    end
end


NightVisionEnabled = NightVisionEnabled or false
ensureColorCorrection = function(name, props)
    local effect = Lighting:FindFirstChild(name)
    if not effect then
        effect = Instance.new("ColorCorrectionEffect")
        effect.Name = name
        effect.Parent = Lighting or cloneref and cloneref(game:GetService("Lighting")) or game:GetService("Lighting")
    end
    for prop, value in pairs(props) do
        effect[prop] = value
    end
    return effect
end

local ccEffects = {
    NightVisionColorCorrection = ensureColorCorrection("NightVisionColorCorrection", {
        Enabled = false,
        Brightness = 0,
        Contrast = -0.1,
        Saturation = -1,
        TintColor = Color3.new(0.6, 1, 0.815686)
    })
}

local vignetteGui = CoreGui:FindFirstChild("VignetteEffect") or PlayerGui:FindFirstChild("VignetteEffect")
if not vignetteGui then
    vignetteGui = Instance.new("ScreenGui")
    vignetteGui.Name = "VignetteEffect"
    vignetteGui.IgnoreGuiInset = true
    vignetteGui.Enabled = false
    vignetteGui.ResetOnSpawn = false
    vignetteGui.Parent = CoreGui
end

local vignetteImage = vignetteGui:FindFirstChildOfClass("ImageLabel")
if not vignetteImage then
    vignetteImage = Instance.new("ImageLabel")
    vignetteImage.Name = "ImageLabel"
    vignetteImage.Active = false
    vignetteImage.BackgroundColor3 = Color3.new(1, 1, 1)
    vignetteImage.BackgroundTransparency = 1
    vignetteImage.BorderColor3 = Color3.new(0, 0, 0)
    vignetteImage.BorderSizePixel = 0
    vignetteImage.Position = UDim2.new(0, 0, 0, 0)
    vignetteImage.Size = UDim2.new(1, 0, 1, 0)
    vignetteImage.Visible = true
    vignetteImage.Image = "rbxassetid://123500368394738"
    vignetteImage.ImageColor3 = Color3.new(1, 1, 1)
    vignetteImage.ImageTransparency = 0
    vignetteImage.ImageRectOffset = Vector2.new(0, 0)
    vignetteImage.ImageRectSize = Vector2.new(0, 0)
    vignetteImage.TileSize = UDim2.new(1, 0, 1, 0)
    vignetteImage.SliceScale = 1
    vignetteImage.SliceCenter = Rect.new(0, 0, 0, 0)
    vignetteImage.ScaleType = Enum.ScaleType.Stretch
    vignetteImage.Parent = vignetteGui
end

ToggleNightVision = function(state)
    NightVisionEnabled = state
    for _, effect in pairs(ccEffects) do
        effect.Enabled = state
    end
    vignetteGui.Enabled = state
end

night_vision = function(toggle)
    if toggle == true then
        if NightVisionEnabled then notify("Warning", "Night Vision is already enabled.", 5); return end
        ToggleNightVision(true)
        notify("Success", "Night Vision has been enabled.", 5)
    elseif toggle == false then
        if not NightVisionEnabled then notify("Warning", "Night Vision is already enabled.", 5); return end
        ToggleNightVision(false)
        notify("Success", "Night Vision has been disabled.", 5)
    else
        return 
    end
end
X.job_spammer = job_spammer
X.Spam_Survey_Completions = Spam_Survey_Completions
X.copy_emote_plr = copy_emote_plr
X.rainbow_skin = rainbow_skin
X.RGB_Phone = RGB_Phone
X.rainbow_tool = rainbow_tool
X.height_func_setter = height_func_setter
X.width_func_setter = width_func_setter
X.size_func_setter = size_func_setter
X.change_property = change_property
X.FlamesLagReducerFunc = FlamesLagReducerFunc
X.night_vision = night_vision
X.toggle_rgb_streetlights = toggle_rgb_streetlights
X.keep_home_locked = keep_home_locked
X.vehicle_bring_player = vehicle_bring_player
X.update_plot_areas = update_plot_areas
X.Anti_Invisible_Players = Anti_Invisible_Players
X.start_walkfling = start_walkfling
X.stop_walkfling = stop_walkfling
end

-- ===== inline features (adapted from Flames' UI-block logic) =====
local ANTIHOUSEBAN_ON = false
local BLOCKCALLS_ON = false
local blockcalls_hooks = nil
local FLASHINVIS_ON = false

local function view_player(target)
    if not target then notify("Error", "Player not found.") return end
    local char = target.Character or get_char(target)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then notify("Error", "Target has no humanoid.") return end
    workspace.CurrentCamera.CameraSubject = hum
    notify("Success", "Viewing: " .. target.Name)
end

local function unview_player()
    local hum = myHum()
    if hum then
        workspace.CurrentCamera.CameraSubject = hum
    end
    notify("Success", "Camera back to you.")
end

local function block_calls(state)
    if state then
        if BLOCKCALLS_ON then notify("Warning", "Block Calls is already enabled!") return end
        BLOCKCALLS_ON = true
        if Net and type(Net.hook) == "function" then
            local function deny(plr)
                pcall(function() Send("end_call", plr) end)
                return false
            end
            blockcalls_hooks = {
                Net.hook("incoming_call", deny),
                Net.hook("incoming_emergency_call", deny),
            }
        else
            -- fallback: watch your GettingCalledBy value and hang up instantly
            FLIB.connect("calls_blocker_watch", LocalPlayer:GetAttributeChangedSignal("GettingCalledBy"):Connect(function()
                local caller = LocalPlayer:GetAttribute("GettingCalledBy")
                if caller then pcall(function() Send("end_call", caller) end) end
            end))
        end
        notify("Success", "Block Calls enabled.")
    else
        if not BLOCKCALLS_ON then notify("Warning", "Block Calls is not enabled!") return end
        BLOCKCALLS_ON = false
        if blockcalls_hooks then
            for _, v in pairs(blockcalls_hooks) do
                pcall(function()
                    if typeof(v) == "RBXScriptConnection" then
                        v:Disconnect()
                    elseif type(v) == "function" then
                        v()
                    end
                end)
            end
            blockcalls_hooks = nil
        end
        FLIB.disconnect("calls_blocker_watch")
        notify("Success", "Block Calls disabled.")
    end
end

local function anti_house_ban(state)
    if state then
        if ANTIHOUSEBAN_ON then notify("Error", "Anti House Ban is already enabled.") return end
        X.update_plot_areas()
        if not X.PlotAreas or not next(X.PlotAreas) then
            notify("Error", "PlotAreas missing or patched.")
            return
        end
        ANTIHOUSEBAN_ON = true
        local char = myChar()
        local hrp = myRoot()
        if not hrp then notify("Error", "No HumanoidRootPart yet.") ANTIHOUSEBAN_ON = false return end
        local safe_cframe = hrp.CFrame
        local last_position = hrp.Position
        local latch_until = 0
        local function rebind()
            char = myChar()
            hrp = myRoot()
            if not hrp then return end
            safe_cframe = hrp.CFrame
            last_position = hrp.Position
            latch_until = 0
        end
        FLIB.connect("AntiHouseBan_CharAdded", LocalPlayer.CharacterAdded:Connect(function()
            fw(0.1)
            rebind()
        end))
        FLIB.connect("AntiHouseBan_Heartbeat", RunService.Heartbeat:Connect(function()
            if not ANTIHOUSEBAN_ON then return end
            if not hrp or not hrp.Parent then return end
            local now = os.clock()
            local current_position = hrp.Position
            local delta = (current_position - last_position).Magnitude
            if delta > 12 then
                latch_until = now + 0.4
                hrp.CFrame = safe_cframe
                last_position = safe_cframe.Position
            elseif latch_until > now then
                hrp.CFrame = safe_cframe
                last_position = safe_cframe.Position
            else
                safe_cframe = hrp.CFrame
                last_position = hrp.Position
            end
        end))
        FLIB.spawn("AntiHouseBan_PlotLoop", "spawn", function()
            while ANTIHOUSEBAN_ON do
                fw()
                for v in pairs(X.PlotAreas) do
                    if v then v.CanCollide = false end
                end
            end
        end)
        notify("Success", "Anti House Ban is now enabled.")
    else
        if not ANTIHOUSEBAN_ON then notify("Warning", "Anti House Ban is not enabled.") return end
        ANTIHOUSEBAN_ON = false
        FLIB.disconnect("AntiHouseBan_CharAdded")
        FLIB.disconnect("AntiHouseBan_Heartbeat")
        FLIB.disconnect("AntiHouseBan_PlotLoop")
        notify("Success", "Anti House Ban is now disabled.")
    end
end

local function bring_vehicle_to_me()
    -- mirrors their implementation: own-vehicle search in Workspace.Vehicles,
    -- sit via the seat, then the game's Util.tween_model brings it to you
    local Util = UtilMod
    if not Util then
        notify("Error", "ModuleScript: 'Util' does not seem to exist.")
        return
    end
    local hrp = myRoot()
    if not hrp then notify("Error", "Could not find HumanoidRootPart!") return end
    local vehiclesFolder = workspace:WaitForChild("Vehicles", 3)
    if not vehiclesFolder then notify("Error", "No Vehicles folder found!") return end
    local myVehicle = nil
    for _, v in ipairs(vehiclesFolder:GetChildren()) do
        if v:IsA("Model") and v:FindFirstChild("owner") and v.owner.Value == LocalPlayer then
            if v:FindFirstChild("VehicleSeat") then
                myVehicle = v
                break
            end
        end
    end
    if not myVehicle then notify("Error", "No owned vehicle found!") return end
    local seat = myVehicle:FindFirstChild("VehicleSeat", true)
    local savedCF = hrp.CFrame
    local hum = myHum()
    local char = myChar()
    if seat and hum and char then
        char:PivotTo(seat.CFrame)
        fw(0.2)
        seat:Sit(hum)
    end
    fw(0.1)
    local targetCF = savedCF * CFrame.new(0, 10, 0)
    if type(Util.tween_model) == "function" then
        local tween = Util.tween_model(myVehicle, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), targetCF)
        if tween then tween.Completed:Wait() end
    else
        myVehicle:PivotTo(targetCF)
    end
    notify("Success", "Brought your Vehicle to you!")
end

local function rejoin()
    local placeId = game.PlaceId
    local jobId = game.JobId
    if queueRelaunchOrHint then queueRelaunchOrHint() end
    if #Players:GetPlayers() > 1 then
        TeleportService:TeleportToPlaceInstance(placeId, jobId, LocalPlayer)
    else
        TeleportService:Teleport(placeId, LocalPlayer)
    end
    notify("Success", "Rejoining...")
end

local function flash_invisible(state)
    if not InvisibleMode or not InvisibleMode.enabled then
        notify("Error", "InvisibleMode module not available.")
        return
    end
    if state then
        if FLASHINVIS_ON then return end
        FLASHINVIS_ON = true
        if InvisibleMode.enabled.get() then InvisibleMode.enabled.set(false) end
        fw(0.1)
        task.spawn(function()
            while FLASHINVIS_ON do
                InvisibleMode.enabled.set(true)
                fw(0.05)
                InvisibleMode.enabled.set(false)
                fw(0.05)
            end
            InvisibleMode.enabled.set(false)
        end)
    else
        FLASHINVIS_ON = false
    end
end

-- Anti Steal: wears Flames Hub's own anti-stealer marker as your bio.
-- Their copy-avatar refuses (with their own warning notification) any target
-- whose bio attribute equals this exact string -- so their users cannot copy
-- you, while this script's copy has no such check and copies them anyway.
local anti_outfit_stealer = false
local ToggleAntiFit_Stealer = nil

-- Flames Hub's anti_outfit_copier, line for line (their FlamesLibrary calls
-- map to this script's FLIB shim; their g. names map to Send/notify and the
-- LocalPlayer). One behaviour of theirs worth knowing: turning it off does
-- NOT put your old bio back - the marker stays in your bio until you change
-- it yourself. That is exactly how theirs works too.
local function anti_steal(toggle)
    if toggle == true then
        if anti_outfit_stealer then notify("Error", "Anti Outfit Stealer is already enabled!", 5); return end
        if FLIB.is_alive("AntiFitStealerConn") then notify("Error", "Anti Outfit Stealer is already enabled! [connection].", 5); return end
        notify("Success", "Flames Hub | Anti Outfit Stealer is now active.", 7)
        ToggleAntiFit_Stealer = ToggleAntiFit_Stealer or function(state)
            if not state then
                anti_outfit_stealer = false
                FLIB.disconnect("AntiFitStealerConn")
                local hide_outfit_toggle = LocalPlayer:GetAttribute("hide_view_outfit")
                if hide_outfit_toggle and hide_outfit_toggle == false then
                    Send("hide_view_outfit", true)
                    notify("Success", "hide_view_outfit setting changed, reverted change (keep it on).", 3)
                end
            else
                anti_outfit_stealer = true
                Send("bio", "`~ Flames Hub Anti Stealer Is Enabled ~`")
            end

            local last_check = 0
            local target_bio = "`~ Flames Hub Anti Stealer Is Enabled ~`"
            FLIB.connect("AntiFitStealerConn", RunService.Heartbeat:Connect(function()
                local now = tick()
                if now - last_check < 0.4 then return end
                last_check = now
                local hide_outfit_toggle = LocalPlayer:GetAttribute("hide_view_outfit")
                if hide_outfit_toggle and hide_outfit_toggle == false then
                    Send("hide_view_outfit", true)
                    notify("Success", "hide_view_outfit setting changed, reverted change (keep it on).", 3)
                end

                if anti_outfit_stealer then
                    local current_bio = LocalPlayer:GetAttribute("bio")
                    if current_bio ~= target_bio then
                        Send("bio", target_bio)
                        notify("Success", "Bio was changed, reverted back.", 3)
                    end
                end
            end))
        end
        task.wait(0.1)
        ToggleAntiFit_Stealer(true)
    elseif toggle == false then
        if not anti_outfit_stealer then notify("Error", "Anti Outfit Copier is not enabled!", 5); return end
        anti_outfit_stealer = false
        FLIB.disconnect("AntiFitStealerConn")
        ToggleAntiFit_Stealer(false)
        notify("Success", "Disabled Anti Outfit Stealer.", 5)
    else
        return
    end
end
-- ===== end inline features =====

-- ===== v4 exports: the Dreamville-GUI pages live outside engineMain and reach these through X =====
X.view_player = view_player
X.unview_player = unview_player
X.block_calls = block_calls
X.anti_house_ban = anti_house_ban
X.bring_vehicle_to_me = bring_vehicle_to_me
X.flash_invisible = flash_invisible
X.rejoin = rejoin
X.anti_steal = anti_steal

-- ===== SchoolBus bring / kill with honest verification (never fake success) =====
local function gxMyRoot()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function gxOwnedBus()
	local folder = X.find_vehicles_folder()
	if not folder then return nil end
	for _, v in ipairs(folder:GetChildren()) do
		if v:IsA("Model") and v.Name == "SchoolBus"
			and v:FindFirstChild("owner") and v.owner.Value == LocalPlayer then
			return v
		end
	end
	return nil
end

local function gxEnsureBus()
	if gxOwnedBus() then return true end
	local current = X.get_vehicle()
	if not current or current.Name ~= "SchoolBus" then
		X.spawn_any_vehicle("SchoolBus")
	end
	local t = 0
	while t < 5 do
		if gxOwnedBus() then return true end
		fw(0.2)
		t = t + 0.2
	end
	return gxOwnedBus() ~= nil
end

local function gxVerifyBrought(target)
	local myroot = gxMyRoot()
	local tchar = target.Character
	local troot = tchar and tchar:FindFirstChild("HumanoidRootPart")
	local thum = tchar and tchar:FindFirstChildOfClass("Humanoid")
	if thum and thum.Sit then return true end
	if myroot and troot then
		return (troot.Position - myroot.Position).Magnitude < 45
	end
	return false
end

local function gxVerifyKilled(target, startChar)
	if startChar and target.Character ~= startChar then return true end
	local tchar = target.Character
	if not tchar then return true end
	local thum = tchar:FindFirstChildOfClass("Humanoid")
	local troot = tchar:FindFirstChild("HumanoidRootPart")
	if thum and thum.Health <= 0 then return true end
	if troot and troot.Position.Y < -150 then return true end
	return false
end

local function gxBusAction(fn, verb, verify, target, windowSecs)
	if not target then return end
	local startChar = target.Character
	local tchar = target.Character
	local troot = tchar and tchar:FindFirstChild("HumanoidRootPart")
	if not troot then
		notify("Error", target.Name .. " hasn't loaded in for you yet - get closer and try again.")
		return
	end
	if not gxEnsureBus() then
		notify("Error", "Failed to spawn/find your SchoolBus.")
		return
	end
	fn(target)
	local okv = false
	local waited = 0
	local window = windowSecs or 4
	while waited < window do
		fw(0.15)
		waited = waited + 0.15
		if verify(target, startChar) then okv = true break end
	end
	if okv then
		notify("Success", verb .. ": " .. target.Name)
	else
		notify("Error", verb .. " didn't go through for " .. target.Name .. " - they may not be fully streamed in. Try again.")
	end
end

-- Annoy: Flames Hub's annoyance loop, their exact sends - flood the target
-- with carry requests and call / end-call requests until switched off.
-- One target at a time, like theirs; picking another player retargets it.
local annoyOn, annoyTarget, annoyThread = false, nil, nil
X.annoy_player = function(plr, on)
	if on then
		if not plr then return end
		annoyOn, annoyTarget = true, plr
		if not annoyThread then
			annoyThread = task.spawn(function()
				while annoyOn and annoyTarget and annoyTarget.Parent do
					local t = annoyTarget
					task.wait()
					Send("request_carry", t.Name)
					task.wait()
					Send("request_call", t.Name)
					task.wait()
					Send("end_call", t.Name)
				end
				annoyThread = nil
				annoyOn = false
			end)
		end
		notify("Success", "Annoying " .. plr.Name, 3)
	else
		annoyOn, annoyTarget = false, nil
	end
end
X.annoy_state = function() return annoyOn, annoyTarget end
X.bring_player = function(plr) gxBusAction(X.vehicle_bring_player, "Bringing player", gxVerifyBrought, plr, 4) end
X.kill_player = function(plr) gxBusAction(X.vehicle_kill_player, "Killing player", gxVerifyKilled, plr, 7) end
end
GXEngineMain()


onClean(function() AV.stopAll() end)

local Feat, myHum, myRoot, rootOf, studsTo
do

-- ============================================================================
-- 13. PER-PLAYER FEATURES (logic only, UI lives further down)
-- ============================================================================
Feat = { changed = function() end } -- UI sets Feat.changed(plr, key)
local PS = {} -- per-player toggle state, dropped when they leave
local function pstate(plr)
	local s = PS[plr]
	if not s then s = { esp = false, spec = false, hide = false, mute = "Off", follow = false } PS[plr] = s end
	return s
end
Feat.state = pstate

local function myChar() return LP.Character end
function myHum() local c = LP.Character return c and c:FindFirstChildOfClass("Humanoid") end
function myRoot() local c = LP.Character return c and c:FindFirstChild("HumanoidRootPart") end
function rootOf(plr) local c = plr.Character return c and c:FindFirstChild("HumanoidRootPart") end
function studsTo(plr)
	local a, b = myRoot(), rootOf(plr)
	if a and b then return (a.Position - b.Position).Magnitude end
end

-- ---------------------------------------------------------------- ESP
-- outline-only white highlight, same as ";hl <player> white white 1" without typing
local ESP = { single = {}, all = false, hl = {}, cc = {} }
Feat.ESP = ESP

local function espDrop(plr)
	local h = ESP.hl[plr]
	if h then pcall(function() h:Destroy() end) ESP.hl[plr] = nil end
end

local function espRefresh(plr)
	if dead or plr == LP then return end
	local want = ESP.single[plr] or (ESP.all and plr.Parent == Players)
	if not want then
		espDrop(plr)
		if ESP.cc[plr] then ESP.cc[plr]:Disconnect() ESP.cc[plr] = nil end
		return
	end
	local char = plr.Character
	local h = ESP.hl[plr]
	if char then
		if not h or not h.Parent then
			h = mk("Highlight", {
				Name = "GenXHL", FillColor = Color3.new(1, 1, 1), OutlineColor = Color3.new(1, 1, 1),
				FillTransparency = 1, OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
			}, gui)
			ESP.hl[plr] = h
		end
		h.Adornee = char
	end
	if not ESP.cc[plr] then
		ESP.cc[plr] = plr.CharacterAdded:Connect(function() task.defer(espRefresh, plr) end)
	end
end

function Feat.setESP(plr, on)
	ESP.single[plr] = on or nil
	pstate(plr).esp = on
	espRefresh(plr)
	Feat.changed(plr, "esp")
end

function Feat.setESPAll(on)
	ESP.all = on
	for _, p in ipairs(Players:GetPlayers()) do espRefresh(p) end
end
keep(Players.PlayerAdded:Connect(function(p) if ESP.all then espRefresh(p) end end))

-- ---------------------------------------------------------------- SPECTATE
local spec = { plr = nil, conn = nil }

local function specStop(silent)
	local p = spec.plr
	if spec.conn then spec.conn:Disconnect() spec.conn = nil end
	spec.plr = nil
	local h = myHum()
	local c = workspace.CurrentCamera
	if c and h then pcall(function() c.CameraSubject = h end) end
	if p then
		pstate(p).spec = false
		Feat.changed(p, "spec")
	end
end

function Feat.setSpectate(plr, on)
	if not on then
		if spec.plr == plr then specStop() else pstate(plr).spec = false Feat.changed(plr, "spec") end
		return true
	end
	local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	local d = studsTo(plr)
	if not hum or not d or d > SPECTATE_MAX_DISTANCE then
		log("warn", string.format("spectate refused for %s: loaded=%s dist=%s", plr.Name, tostring(hum ~= nil), d and string.format("%.0f", d) or "n/a"))
		toast("warn", "Out of Range", plr.DisplayName .. " is too far", { userId = plr.UserId })
		pstate(plr).spec = false
		Feat.changed(plr, "spec")
		return false
	end
	if spec.plr and spec.plr ~= plr then specStop() end
	spec.plr = plr
	pstate(plr).spec = true
	pcall(function() workspace.CurrentCamera.CameraSubject = hum end)
	if spec.conn then spec.conn:Disconnect() end
	spec.conn = RunService.Heartbeat:Connect(function()
		local h = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if plr.Parent ~= Players or not h or h.Health <= 0 then
			specStop()
			return
		end
		local cam2 = workspace.CurrentCamera
		if cam2 and cam2.CameraSubject ~= h then pcall(function() cam2.CameraSubject = h end) end
	end)
	Feat.changed(plr, "spec")
	return true
end

-- ---------------------------------------------------------------- HIDE
local HIDE = { map = {}, conn = nil }

local function hideCollect(plr, rec)
	local char = plr.Character
	rec.parts, rec.guis = {}, rec.guis or {}
	if not char then return end
	local function take(d)
		if d:IsA("BasePart") then
			rec.parts[#rec.parts + 1] = d
		elseif d:IsA("BillboardGui") then
			if rec.guis[d] == nil then rec.guis[d] = d.Enabled end
			d.Enabled = false
		end
	end
	for _, d in ipairs(char:GetDescendants()) do take(d) end
	if rec.dconn then rec.dconn:Disconnect() end
	rec.dconn = char.DescendantAdded:Connect(take)
end

local function hideTick()
	for _, rec in pairs(HIDE.map) do
		for _, p in ipairs(rec.parts) do
			if p.Parent then p.LocalTransparencyModifier = 1 end
		end
	end
end

local function hideRestore(rec)
	if rec.dconn then rec.dconn:Disconnect() end
	if rec.cconn then rec.cconn:Disconnect() end
	for _, p in ipairs(rec.parts) do
		if p.Parent then p.LocalTransparencyModifier = 0 end
	end
	for g, was in pairs(rec.guis) do
		if g.Parent then g.Enabled = was end
	end
end

function Feat.setHide(plr, on)
	local rec = HIDE.map[plr]
	if on and not rec then
		rec = { parts = {}, guis = {} }
		HIDE.map[plr] = rec
		hideCollect(plr, rec)
		rec.cconn = plr.CharacterAdded:Connect(function()
			task.wait(0.3)
			if HIDE.map[plr] == rec then hideCollect(plr, rec) end
		end)
		if not HIDE.conn then HIDE.conn = RunService.RenderStepped:Connect(hideTick) end
	elseif not on and rec then
		hideRestore(rec)
		HIDE.map[plr] = nil
		if next(HIDE.map) == nil and HIDE.conn then HIDE.conn:Disconnect() HIDE.conn = nil end
	end
	pstate(plr).hide = on and true or false
	Feat.changed(plr, "hide")
end

-- ---------------------------------------------------------------- MUTE
-- Chat: three layers so it works whichever chat the game uses. (1) the OnIncomingMessage callback, (2) the new chat window rows are
-- found by message id and hidden, (3) bubbles over heads and the legacy chat window are swept every half second.
-- Voice: every AudioDeviceInput of the player is muted and the wires carrying it are cut, plus Roblox's own per-user block.
local MUTE = { chat = {}, voice = {}, prevCb = nil, installed = false, hadPrev = false, hidden = {}, names = {}, conns = {}, rbx = {}, warned = false }

-- Roblox's own mute (the one behind the Mute button in the main Roblox menu). Going through the same VoiceChatServiceManager the
-- menu uses is what actually silences a player; the older layers below stay as a backup.
function MUTE.mgr()
	if MUTE._mgr ~= nil then return MUTE._mgr or nil end
	local ok, m = pcall(function() return require(CoreGui.RobloxGui.Modules.VoiceChat.VoiceChatServiceManager) end)
	local found = false
	if ok and type(m) == "table" then
		if type(m.ToggleMutePlayer) == "function" then
			found = m
		elseif type(m.VoiceChatServiceManager) == "table" and type(m.VoiceChatServiceManager.ToggleMutePlayer) == "function" then
			found = m.VoiceChatServiceManager
		end
	end
	MUTE._mgr = found
	return found or nil
end

function MUTE.isRbx(uid)
	local m = MUTE.mgr()
	if m and type(m.mutedPlayers) == "table" then return m.mutedPlayers[uid] and true or false end
	return MUTE.rbx[uid] and true or false -- state not readable: trust our own record
end

-- on = true mutes, false unmutes. Only toggles when the menu's current state differs, so it never flips the wrong way.
function MUTE.setRbx(plr, on)
	local uid = plr.UserId
	local m = MUTE.mgr()
	if not m then
		if on and not MUTE.warned then
			MUTE.warned = true
			log("warn", "Roblox voice menu not reachable (require on CoreGui is blocked here), using the backup mute layers")
		end
		return false
	end
	if MUTE.isRbx(uid) ~= on then
		local ok, err = pcall(function() m:ToggleMutePlayer(uid) end)
		if not ok then log("fail", "Roblox mute toggle failed: " .. tostring(err)) return false end
		task.wait(0.25)
	end
	MUTE.rbx[uid] = on and true or nil
	local good = MUTE.isRbx(uid) == on
	log(good and "ok" or "warn", string.format("Roblox menu mute %s -> %s (%s)", plr.Name, on and "ON" or "OFF", good and "confirmed" or "not confirmed"))
	if on and not MUTE.watching then
		-- Roblox rebuilds its voice state when someone rejoins voice: keep the mute applied
		MUTE.watching = true
		task.spawn(function()
			while not dead and next(MUTE.rbx) do
				task.wait(2)
				for id in pairs(MUTE.rbx) do
					if not MUTE.isRbx(id) then
						local p = Players:GetPlayerByUserId(id)
						if p then MUTE.setRbx(p, true) else MUTE.rbx[id] = nil end
					end
				end
			end
			MUTE.watching = false
		end)
	end
	return good
end

local function hideRow(id)
	local ec = CoreGui:FindFirstChild("ExperienceChat")
	if not ec then return end
	for _, d in ipairs(ec:GetDescendants()) do
		if d.Name == id and d:IsA("GuiObject") then pcall(function() d.Visible = false end) end
	end
end

local function sweepChat()
	-- new chat window: hide rows of messages we flagged
	if next(MUTE.hidden) then
		local ec = CoreGui:FindFirstChild("ExperienceChat")
		if ec then
			for _, d in ipairs(ec:GetDescendants()) do
				if MUTE.hidden[d.Name] and d:IsA("GuiObject") and d.Visible then pcall(function() d.Visible = false end) end
			end
		end
	end
	-- chat bubbles over heads
	local bc = CoreGui:FindFirstChild("BubbleChat")
	if bc then
		for _, g in ipairs(bc:GetDescendants()) do
			if g:IsA("BillboardGui") and g.Enabled then
				local owner
				local ad = g.Adornee
				local model = ad and ad:FindFirstAncestorOfClass("Model")
				if model then owner = Players:GetPlayerFromCharacter(model) end
				local byName = false
				for uid in pairs(MUTE.chat) do if g.Name:find(tostring(uid), 1, true) then byName = true break end end
				if (owner and MUTE.chat[owner.UserId]) or byName then pcall(function() g.Enabled = false end) end
			end
		end
	end
	-- legacy chat window: rows start with a "[Name]:" button
	local pg = LP:FindFirstChild("PlayerGui")
	local lc = pg and pg:FindFirstChild("Chat")
	if lc and next(MUTE.names) then
		for _, d in ipairs(lc:GetDescendants()) do
			if d:IsA("TextButton") and d.Visible and #d.Text < 60 then
				local n = d.Text:gsub("[%[%]:]", ""):gsub("^%s+", ""):gsub("%s+$", "")
				if MUTE.names[n:lower()] then
					local row = d.Parent and d.Parent.Parent
					if row and row:IsA("GuiObject") and not row:IsA("ScrollingFrame") then pcall(function() row.Visible = false end) end
				end
			end
		end
	end
end

local function onChatMessage(message)
	local src = message.TextSource
	if src and MUTE.chat[src.UserId] then
		local id = message.MessageId
		MUTE.hidden[id] = true
		for _, dl in ipairs({ 0, 0.04, 0.12, 0.3, 0.7 }) do
			task.delay(dl, function() if not dead then hideRow(id) end end)
		end
	end
end

local function installChatMute()
	if MUTE.installed then return end
	MUTE.installed = true
	local okp, prev = pcall(function() return TextChatService.OnIncomingMessage end)
	MUTE.prevCb = okp and prev or nil
	pcall(function()
		TextChatService.OnIncomingMessage = function(message)
			local props
			if MUTE.prevCb then
				local ok, r = pcall(MUTE.prevCb, message)
				if ok then props = r end
			end
			local src = message.TextSource
			if src and MUTE.chat[src.UserId] then
				props = props or Instance.new("TextChatMessageProperties")
				props.Text = ""
				props.PrefixText = ""
			end
			return props
		end
	end)
	local okc = pcall(function() MUTE.conns[#MUTE.conns + 1] = TextChatService.MessageReceived:Connect(onChatMessage) end)
	if not okc then
		pcall(function()
			for _, ch in ipairs(TextChatService:GetDescendants()) do
				if ch:IsA("TextChannel") then MUTE.conns[#MUTE.conns + 1] = ch.MessageReceived:Connect(onChatMessage) end
			end
		end)
	end
	local acc = 0
	MUTE.conns[#MUTE.conns + 1] = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.5 then return end
		acc = 0
		pcall(sweepChat)
	end)
end

local function uninstallChatMute()
	if not MUTE.installed then return end
	MUTE.installed = false
	for _, c in ipairs(MUTE.conns) do pcall(function() c:Disconnect() end) end
	MUTE.conns = {}
	pcall(function() TextChatService.OnIncomingMessage = MUTE.prevCb end)
	MUTE.prevCb = nil
	MUTE.hidden, MUTE.names = {}, {}
end

-- ----- voice
local function isTheirInput(plr, inst)
	local okp, owner = pcall(function() return inst.Player end)
	if okp and owner == plr then return true end
	return inst:IsDescendantOf(plr) or (plr.Character ~= nil and inst:IsDescendantOf(plr.Character))
end

-- Roblox's own per-user voice block / pause
local function voiceBlock(plr, on)
	local any = false
	pcall(function()
		local vci = game:GetService("VoiceChatInternal")
		local a = pcall(function() if on then vci:SubscribeBlock(plr.UserId) else vci:SubscribeUnblock(plr.UserId) end end)
		local b = pcall(function() if on then vci:SubscribePause(plr.UserId) else vci:SubscribeUnpause(plr.UserId) end end)
		any = a or b
	end)
	return any
end

local function voiceTouch(plr, rec, d)
	if d:IsA("AudioDeviceInput") then
		if isTheirInput(plr, d) then
			if rec.orig[d] == nil then rec.orig[d] = { d.Muted, d.Volume } end
			pcall(function() d.Muted = true d.Volume = 0 end)
			rec.found += 1
		end
	elseif d:IsA("Wire") then
		local function check()
			local src = d.SourceInstance
			if src and src:IsA("AudioDeviceInput") and isTheirInput(plr, src) and rec.wires[d] == nil then
				rec.wires[d] = d.Enabled
				pcall(function() d.Enabled = false end)
				rec.found += 1
			end
		end
		pcall(check)
		rec.conns[#rec.conns + 1] = d:GetPropertyChangedSignal("SourceInstance"):Connect(function() pcall(check) end)
	end
end

local function voiceOn(plr)
	if MUTE.voice[plr] then return true, true end
	local rec = { orig = {}, wires = {}, conns = {}, found = 0 }
	MUTE.voice[plr] = rec
	task.spawn(function() if not dead then MUTE.setRbx(plr, true) end end) -- Roblox's own mute first
	rec.block = voiceBlock(plr, true)
	-- everything that shows up later (they join voice after us, or the game rebuilds the audio graph)
	rec.conns[#rec.conns + 1] = game.DescendantAdded:Connect(function(d)
		if d:IsA("AudioDeviceInput") or d:IsA("Wire") then task.defer(voiceTouch, plr, rec, d) end
	end)
	-- one pass over what already exists, in small slices so the game never hitches
	task.spawn(function()
		local ok, all = pcall(function() return game:GetDescendants() end)
		if not ok then return end
		for i, d in ipairs(all) do
			if dead or MUTE.voice[plr] ~= rec then return end
			if d:IsA("AudioDeviceInput") or d:IsA("Wire") then pcall(voiceTouch, plr, rec, d) end
			if i % 4000 == 0 then task.wait() end
		end
	end)
	return true, rec.block
end

local function voiceOff(plr)
	local rec = MUTE.voice[plr]
	if not rec then return end
	MUTE.voice[plr] = nil
	MUTE.rbx[plr.UserId] = nil
	task.spawn(function() MUTE.setRbx(plr, false) end) -- hand the player back to Roblox's menu unmuted
	for _, c in ipairs(rec.conns) do pcall(function() c:Disconnect() end) end
	if rec.block then voiceBlock(plr, false) end
	for d, o in pairs(rec.orig) do
		if d.Parent then pcall(function() d.Muted = o[1] d.Volume = o[2] end) end
	end
	for w, en in pairs(rec.wires) do
		if w.Parent then pcall(function() w.Enabled = en end) end
	end
end

-- mode: "Off" | "Voice" | "Chat" | "Both"
function Feat.setMute(plr, mode)
	local wantChat = (mode == "Chat" or mode == "Both")
	local wantVoice = (mode == "Voice" or mode == "Both")
	if wantVoice then
		local _, blocked = voiceOn(plr)
		task.delay(1.2, function()
			local rec = MUTE.voice[plr]
			if dead or not rec then return end
			log("info", string.format("voice mute %s: inputs/wires cut=%d block=%s", plr.Name, rec.found, tostring(blocked)))
			if rec.found == 0 and not blocked then
				toast("info", "Voice Mute", "Armed for " .. plr.DisplayName, { userId = plr.UserId, silent = true })
			end
		end)
	else
		voiceOff(plr)
	end
	if wantChat then
		MUTE.chat[plr.UserId] = true
		MUTE.names[plr.Name:lower()] = true
		MUTE.names[plr.DisplayName:lower()] = true
		installChatMute()
		pcall(sweepChat)
	else
		MUTE.chat[plr.UserId] = nil
		MUTE.names[plr.Name:lower()] = nil
		MUTE.names[plr.DisplayName:lower()] = nil
		if next(MUTE.chat) == nil then uninstallChatMute() end
	end
	pstate(plr).mute = mode
	log("info", string.format("mute %s -> %s (chat=%s voice=%s)", plr.Name, mode, tostring(wantChat), tostring(wantVoice)))
	Feat.changed(plr, "mute")
end

-- ---------------------------------------------------------------- TELEPORT / AUTO FOLLOW
function Feat.teleport(plr)
	local mine, theirs = myRoot(), rootOf(plr)
	if not mine or not theirs then
		toast("err", "Teleport Failed", "Target not loaded", { userId = plr.UserId })
		return false
	end
	mine.CFrame = theirs.CFrame * CFrame.new(0, 0, 3)
	toast("ok", "Teleported", "At " .. plr.DisplayName, { userId = plr.UserId, silent = true })
	return true
end

local FOL = { plr = nil, conn = nil }
local function folStop()
	local p = FOL.plr
	if FOL.conn then FOL.conn:Disconnect() FOL.conn = nil end
	FOL.plr = nil
	local h, r = myHum(), myRoot()
	if h and r then pcall(function() h:MoveTo(r.Position) end) end
	if p and PS[p] then PS[p].follow = false Feat.changed(p, "follow") end
end

function Feat.setFollow(plr, on)
	if not on then
		if FOL.plr == plr then folStop() else pstate(plr).follow = false Feat.changed(plr, "follow") end
		return
	end
	if FOL.plr and FOL.plr ~= plr then folStop() end
	FOL.plr = plr
	pstate(plr).follow = true
	if FOL.conn then FOL.conn:Disconnect() end
	FOL.conn = RunService.Heartbeat:Connect(function()
		if plr.Parent ~= Players then folStop() return end
		local mh, mr, tr = myHum(), myRoot(), rootOf(plr)
		if not mh or not mr or not tr then return end -- they are respawning or out of range: keep waiting
		local d = (mr.Position - tr.Position).Magnitude
		if d > 5 then
			mh:MoveTo(tr.Position)
			if tr.Position.Y > mr.Position.Y + 3 and d < 14 then mh.Jump = true end
		else
			mh:MoveTo(mr.Position)
		end
	end)
	Feat.changed(plr, "follow")
end

-- ---------------------------------------------------------------- LIFECYCLE
function Feat.dropPlayer(plr)
	ESP.single[plr] = nil
	espDrop(plr)
	if ESP.cc[plr] then ESP.cc[plr]:Disconnect() ESP.cc[plr] = nil end
	local s = PS[plr]
	if not s then return end
	if spec.plr == plr then specStop(true) end
	if FOL.plr == plr then folStop() end
	if HIDE.map[plr] then hideRestore(HIDE.map[plr]) HIDE.map[plr] = nil end
	if HIDE.conn and next(HIDE.map) == nil then HIDE.conn:Disconnect() HIDE.conn = nil end
	voiceOff(plr)
	MUTE.chat[plr.UserId] = nil
	MUTE.names[plr.Name:lower()] = nil
	MUTE.names[plr.DisplayName:lower()] = nil
	if next(MUTE.chat) == nil then uninstallChatMute() end
	if AV.syncTarget() == plr then AV.setSync(plr, false) end
	PS[plr] = nil
end

function Feat.stopAll()
	specStop(true)
	folStop()
	for plr, rec in pairs(HIDE.map) do hideRestore(rec) HIDE.map[plr] = nil end
	if HIDE.conn then HIDE.conn:Disconnect() HIDE.conn = nil end
	for plr in pairs(MUTE.voice) do voiceOff(plr) end
	MUTE.chat = {}
	uninstallChatMute()
	ESP.all = false
	ESP.single = {}
	for plr, c in pairs(ESP.cc) do c:Disconnect() ESP.cc[plr] = nil end
	for plr in pairs(ESP.hl) do espDrop(plr) end
end
onClean(Feat.stopAll)

-- my character respawned while spectating: the camera snaps back to us, so re-point it
keep(LP.CharacterAdded:Connect(function()
	if spec.plr then task.wait(0.5) local p = spec.plr if p then Feat.setSpectate(p, true) end end
end))

end



-- ============================================================================
-- 14. UI WIDGET LIBRARY
-- ============================================================================
function UI.isPress(i) return i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 end

-- press-scale on any control: UI.press(hitInstance, 0.94, scaledInstance?)
function UI.press(inst, amt, target)
	target = target or inst
	local sc = target:FindFirstChildOfClass("UIScale") or mk("UIScale", { Scale = 1 }, target)
	local function up() tw(sc, 0.25, { Scale = 1 }, Enum.EasingStyle.Back) end
	inst.InputBegan:Connect(function(i) if UI.isPress(i) then tw(sc, 0.08, { Scale = amt or 0.94 }) end end)
	inst.InputEnded:Connect(function(i) if UI.isPress(i) then up() end end)
	inst.MouseLeave:Connect(up)
	return sc
end

-- soft top-left light, safe on CanvasGroups (a UIGradient on the group itself would tint the children)
function UI.sheen(p)
	local s = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 0 }, p)
	if p:IsA("Frame") then mk("UICorner", { CornerRadius = UDim.new(0, 16) }, s) end -- a Frame card does not round-clip its children like a CanvasGroup did
	mk("UIGradient", { Rotation = 35, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 1) }) }, s)
	return s
end

-- ONE shared per-frame loop for every animation (emblem, skeletons). fn(t, dt); returns an unsubscribe function
do
	local fns = {}
	function UI.onFrame(fn)
		fns[#fns + 1] = fn
		return function() local i = table.find(fns, fn) if i then table.remove(fns, i) end end
	end
	keep(RunService.RenderStepped:Connect(function(dt)
		local t = os.clock()
		for i = #fns, 1, -1 do
			local f = fns[i]
			if f and not pcall(f, t, dt) then table.remove(fns, i) end
		end
	end))
end

local function glassReg(inst, base)
	UI.glass[#UI.glass + 1] = { inst = inst, base = base }
	inst.BackgroundTransparency = 1 - (1 - base) * cfg.opacity
end
local function applyOpacity()
	local alive = {}
	for _, g in ipairs(UI.glass) do
		if g.inst and g.inst.Parent then
			alive[#alive + 1] = g
			g.inst.BackgroundTransparency = 1 - (1 - g.base) * cfg.opacity
		end
	end
	UI.glass = alive
end

local function label(parent, text, size, key, props)
	local l = mk("TextLabel", {
		BackgroundTransparency = 1, Text = text, TextSize = size or 14, Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = false,
	}, parent)
	for k, v in pairs(props or {}) do l[k] = v end
	themed(l, { TextColor3 = key or "text" })
	return l
end

local function card(parent, size, props)
	local f = mk("Frame", { Size = size or UDim2.new(1, 0, 0, 80), BorderSizePixel = 0 }, parent)
	for k, v in pairs(props or {}) do f[k] = v end
	themed(f, { BackgroundColor3 = "card" })
	glassReg(f, 0.14)
	round(f, 16)
	local s = mk("UIStroke", { Thickness = 1, Transparency = 0.25 }, f)
	themed(s, { Color = "stroke" })
	mk("UIGradient", { Rotation = 35, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.22) }) }, f)
	UI.cards[#UI.cards + 1] = f
	return f
end

-- primary = accent fill, otherwise ghost. 44px minimum height unless noMin. returns the TextButton
local function button(parent, text, primary, size, onClick, noMin)
	size = size or UDim2.new(1, 0, 0, 44)
	if not noMin and size.Y.Scale == 0 and size.Y.Offset > 0 and size.Y.Offset < 44 then size = UDim2.new(size.X.Scale, size.X.Offset, 0, 44) end
	local b = mk("TextButton", { Size = size, AutoButtonColor = false, Text = text, Font = Enum.Font.GothamBold, TextSize = 14, BorderSizePixel = 0 }, parent)
	round(b, 12)
	local s = mk("UIStroke", { Thickness = 1, Transparency = 0.15 }, b)
	if primary then
		themed(b, { BackgroundColor3 = "accent" })
		b.TextColor3 = Color3.new(1, 1, 1)
		themed(s, { Color = "accent2" })
		local g = mk("UIGradient", { Rotation = 25 }, b)
		onTheme(function(th) g.Color = ColorSequence.new(th.accent, th.accent2) end, b)
		b.BackgroundTransparency = 0.05
		-- a UIGradient tints the button's own text with the fill colour (red on red). Show the text on a child label, which the gradient does not touch
		b.TextTransparency = 1
		local lbl = mk("TextLabel", { Name = "Label", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = b.Text, Font = b.Font,
			TextSize = b.TextSize, TextColor3 = Color3.new(1, 1, 1), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = b.ZIndex + 1 }, b)
		for _, prop in ipairs({ "Text", "Font", "TextSize" }) do
			b:GetPropertyChangedSignal(prop):Connect(function() lbl[prop] = b[prop] end)
		end
		b:GetPropertyChangedSignal("TextColor3"):Connect(function() lbl.TextColor3 = b.TextColor3 end)
	else
		themed(b, { BackgroundColor3 = "bg", TextColor3 = "text" })
		themed(s, { Color = "stroke" })
		b.BackgroundTransparency = 0.35
	end
	UI.press(b, 0.95)
	if onClick then b.Activated:Connect(function() haptic(0.2) onClick() end) end
	return b
end
UI.button = button
UI.tutRef = {} -- real controls the tutorial spotlights

-- animated switch: returns obj { set(on, silent), get(), setEnabled(bool), frame }
local function switch(parent, initial, onChange)
	local on = initial and true or false
	local sw = mk("TextButton", { Size = UDim2.fromOffset(54, 30), Text = "", AutoButtonColor = false, BorderSizePixel = 0 }, parent)
	round(sw, 15)
	local st = mk("UIStroke", { Thickness = 1, Transparency = 0.4 }, sw)
	local knob = mk("Frame", { Size = UDim2.fromOffset(24, 24), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, sw)
	round(knob, 12)
	mk("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(212, 218, 235)) }, knob)
	local hit = mk("TextButton", { Size = UDim2.new(1, 18, 1, 18), Position = UDim2.fromOffset(-9, -9), BackgroundTransparency = 1, Text = "", ZIndex = 5 }, sw) -- 44px touch area
	UI.press(hit, 0.92, sw)
	local obj = { frame = sw }
	local function paint(animate)
		local th = T()
		local col = on and th.accent or th.stroke
		local scol = on and th.accent2 or th.stroke
		local pos = on and UDim2.new(1, -27, 0.5, -12) or UDim2.new(0, 3, 0.5, -12)
		if animate then
			tw(sw, 0.2, { BackgroundColor3 = col })
			tw(st, 0.2, { Color = scol })
			tw(knob, 0.3, { Position = pos }, Enum.EasingStyle.Back)
		else
			sw.BackgroundColor3, st.Color, knob.Position = col, scol, pos
		end
	end
	function obj.set(v, silent)
		v = v and true or false
		if v == on then return end
		on = v
		paint(true)
		if not silent and onChange then onChange(on) end
	end
	function obj.get() return on end
	function obj.setEnabled(e) hit.Active = e sw.BackgroundTransparency = e and 0 or 0.6 end
	hit.Activated:Connect(function() haptic(0.25) obj.set(not on) end)
	onTheme(function() if sw.Parent then paint(false) end end, sw)
	paint(false)
	return obj
end

-- slider with touch dragging; cb(value) fires while dragging. returns { frame, set(v) }
local function slider(parent, min, max, value, cb, size)
	local holder = mk("Frame", { Size = size or UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1 }, parent)
	local track = mk("Frame", { Size = UDim2.new(1, -20, 0, 6), Position = UDim2.new(0, 10, 0.5, -3), BorderSizePixel = 0 }, holder)
	themed(track, { BackgroundColor3 = "stroke" })
	round(track, 3)
	local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0 }, track)
	themed(fill, { BackgroundColor3 = "accent" })
	round(fill, 3)
	local knob = mk("Frame", { Size = UDim2.fromOffset(22, 22), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BorderSizePixel = 0 }, track)
	themed(knob, { BackgroundColor3 = "text" })
	round(knob, 11)
	local ks = mk("UIScale", { Scale = 1 }, knob)
	local hit = mk("TextButton", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "" }, holder)
	local obj = { frame = holder }
	local function setFrac(f, fire)
		f = math.clamp(f, 0, 1)
		fill.Size = UDim2.fromScale(f, 1)
		knob.Position = UDim2.fromScale(f, 0.5)
		if fire then cb(min + (max - min) * f) end
	end
	function obj.set(v) setFrac((v - min) / (max - min), false) end
	obj.set(value)
	local dragging = false
	local function fromInput(pos)
		local w = track.AbsoluteSize.X
		if w <= 0 then return end
		setFrac((pos.X - track.AbsolutePosition.X) / w, true)
	end
	hit.InputBegan:Connect(function(i)
		if UI.isPress(i) then
			dragging = true
			tw(ks, 0.12, { Scale = 1.25 })
			fromInput(i.Position)
		end
	end)
	keep(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then fromInput(i.Position) end
	end))
	keep(UIS.InputEnded:Connect(function(i)
		if UI.isPress(i) and dragging then
			dragging = false
			tw(ks, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end))
	return obj
end

-- draggable handle that moves `target` (absolute pixels). onTap fires when the move was tiny.
local function makeDraggable(handle, target, onTap, onDone)
	local dragging, startIn, startPos, moved, activeInput = false, nil, nil, 0, nil
	handle.InputBegan:Connect(function(i)
		if dragging then return end
		if UI.isPress(i) then
			dragging, moved, activeInput = true, 0, i
			startIn = i.Position
			startPos = Vector2.new(target.Position.X.Offset, target.Position.Y.Offset)
		end
	end)
	keep(UIS.InputChanged:Connect(function(i)
		if not dragging then return end
		if i == activeInput or i.UserInputType == Enum.UserInputType.MouseMovement then
			local d = Vector2.new(i.Position.X - startIn.X, i.Position.Y - startIn.Y)
			moved = math.max(moved, d.Magnitude)
			if moved > 6 then
				local vp = viewport()
				local sz = target.AbsoluteSize
				target.Position = UDim2.fromOffset(
					math.clamp(startPos.X + d.X, 0, vp.X - sz.X), math.clamp(startPos.Y + d.Y, 0, vp.Y - sz.Y))
			end
		end
	end))
	keep(UIS.InputEnded:Connect(function(i)
		if dragging and (i == activeInput or i.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			if moved <= 6 then if onTap then onTap() end elseif onDone then onDone() end
		end
	end))
end

-- ---------------------------------------------------------------- extras (all on UI.*, no top-level locals)
do
	-- skeleton shimmer while something loads: sk.stop() fades it out
	function UI.skeleton(parent, radius)
		local f = mk("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = (parent.ZIndex or 1) + 3 }, parent)
		themed(f, { BackgroundColor3 = "stroke" })
		if radius then round(f, radius) end
		local g = mk("UIGradient", { Rotation = 15, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(0.5, 0.2), NumberSequenceKeypoint.new(1, 0.6) }) }, f)
		local off = UI.onFrame(function(t)
			if not f.Parent then error("gone") end
			g.Offset = Vector2.new((t * 1.1) % 2 - 1, 0)
		end)
		local sk = { frame = f }
		function sk.stop()
			off()
			tw(f, 0.25, { BackgroundTransparency = 1 })
			task.delay(0.3, function() pcall(function() f:Destroy() end) end)
		end
		return sk
	end

	-- round headshot with shimmer while loading. returns frame, imageLabel
	function UI.avatarImg(parent, userId, size, circle)
		local fr = mk("Frame", { Size = UDim2.fromOffset(size, size), BorderSizePixel = 0 }, parent)
		themed(fr, { BackgroundColor3 = "bg" })
		round(fr, circle and size / 2 or 10)
		local img = mk("ImageLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ImageTransparency = 1 }, fr)
		round(img, circle and size / 2 or 10)
		local sk = UI.skeleton(fr, circle and size / 2 or 10)
		thumb(userId, "HeadShot", function(c)
			if not img.Parent then return end
			img.Image = c
			tw(img, 0.3, { ImageTransparency = 0 })
			sk.stop()
		end)
		return fr, img
	end

	-- list row with headshot: UI.playerRow(parent, player, height?, onTap?)
	function UI.playerRow(parent, plr, h, onTap)
		h = math.max(h or 48, 44)
		local row = mk("TextButton", { Size = UDim2.new(1, 0, 0, h), AutoButtonColor = false, Text = "", BorderSizePixel = 0 }, parent)
		themed(row, { BackgroundColor3 = "bg" })
		row.BackgroundTransparency = 0.45
		round(row, 12)
		local st = mk("UIStroke", { Thickness = 1, Transparency = 0.5 }, row)
		themed(st, { Color = "stroke" })
		local av = UI.avatarImg(row, plr.UserId, h - 12, true)
		av.Position = UDim2.fromOffset(6, 6)
		label(row, plr.DisplayName, 13, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(h, 6), Size = UDim2.new(1, -h - 28, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd })
		label(row, "@" .. plr.Name, 11, "muted", { Position = UDim2.fromOffset(h, h - 22), Size = UDim2.new(1, -h - 28, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
		local ch = Icon.new(row, "chevR", 16, "muted")
		ch.frame.AnchorPoint = Vector2.new(1, 0.5)
		ch.frame.Position = UDim2.new(1, -10, 0.5, 0)
		UI.press(row, 0.97)
		if onTap then row.Activated:Connect(function() haptic(0.2) onTap(plr) end) end
		return row
	end

	-- animated number: UI.animNum(label, 128, "%d" | "%.1f", seconds)
	function UI.animNum(lbl, to, fmt, dur)
		local nv = lbl:FindFirstChild("_n")
		if not nv then
			nv = mk("NumberValue", { Name = "_n", Value = 0 }, lbl)
			nv.Changed:Connect(function(v)
				local f = lbl:GetAttribute("fmt") or "%d"
				lbl.Text = string.format(f, f:find("%%d") and math.floor(v + 0.5) or v)
			end)
		end
		lbl:SetAttribute("fmt", fmt or "%d")
		tw(nv, dur or 0.6, { Value = to })
	end

	-- animated progress bar: bar.set(0..1, instant?)
	function UI.bar(parent, size, key)
		local track = mk("Frame", { Size = size or UDim2.new(1, 0, 0, 6), BorderSizePixel = 0 }, parent)
		themed(track, { BackgroundColor3 = "stroke" })
		round(track, 3)
		local fill = mk("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0 }, track)
		themed(fill, { BackgroundColor3 = key or "accent" })
		round(fill, 3)
		return { frame = track, set = function(f, instant)
			f = math.clamp(f, 0, 1)
			if instant then fill.Size = UDim2.fromScale(f, 1) else tw(fill, 0.5, { Size = UDim2.fromScale(f, 1) }) end
		end }
	end

	-- live search box: UI.search(parent, "Search", function(text) end, size?) -> { frame, box, get() }
	function UI.search(parent, placeholder, onChange, size)
		local f = mk("Frame", { Size = size or UDim2.new(1, 0, 0, 44), BorderSizePixel = 0 }, parent)
		themed(f, { BackgroundColor3 = "bg" })
		f.BackgroundTransparency = 0.35
		round(f, 12)
		local s = mk("UIStroke", { Thickness = 1, Transparency = 0.4 }, f)
		themed(s, { Color = "stroke" })
		local ic = Icon.new(f, "search", 16, "muted")
		ic.frame.AnchorPoint = Vector2.new(0, 0.5)
		ic.frame.Position = UDim2.new(0, 12, 0.5, 0)
		local box = mk("TextBox", {
			Size = UDim2.new(1, -78, 1, 0), Position = UDim2.fromOffset(36, 0), BackgroundTransparency = 1, Text = "",
			PlaceholderText = placeholder or "Search", Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
		}, f)
		themed(box, { TextColor3 = "text", PlaceholderColor3 = "muted" })
		local clr = mk("TextButton", { Size = UDim2.fromOffset(40, 40), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -2, 0.5, 0), BackgroundTransparency = 1, Text = "", Visible = false }, f)
		local cx = Icon.new(clr, "cross", 14, "muted")
		cx.frame.AnchorPoint = Vector2.new(0.5, 0.5)
		cx.frame.Position = UDim2.fromScale(0.5, 0.5)
		box:GetPropertyChangedSignal("Text"):Connect(function()
			clr.Visible = box.Text ~= ""
			if onChange then onChange(box.Text) end
		end)
		clr.Activated:Connect(function() box.Text = "" end)
		box.Focused:Connect(function() tw(s, 0.15, { Transparency = 0 }) end)
		box.FocusLost:Connect(function() tw(s, 0.2, { Transparency = 0.4 }) end)
		return { frame = f, box = box, get = function() return box.Text end }
	end

	-- chips for sort / filter: UI.chips(parent, { {key="all", text="All"}, ... }, "all", function(key) end, height?)
	function UI.chips(parent, opts, initial, onPick, h)
		h = h or 38
		local row = mk("Frame", { Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1 }, parent)
		mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, row)
		local cur, btns = initial or opts[1].key, {}
		local function paint(animate)
			local th = T()
			for k, b in pairs(btns) do
				local on = k == cur
				local props = { BackgroundColor3 = on and th.accent or th.bg, TextColor3 = on and Color3.new(1, 1, 1) or th.muted, BackgroundTransparency = on and 0.08 or 0.45 }
				if animate then tw(b, 0.2, props) else for p, v in pairs(props) do b[p] = v end end
			end
		end
		for _, o in ipairs(opts) do
			local b = mk("TextButton", { Size = UDim2.fromOffset(math.max(46, #o.text * 8 + 22), h - 6), AutoButtonColor = false, Text = o.text, Font = Enum.Font.GothamBold, TextSize = 11, BorderSizePixel = 0 }, row)
			round(b, 14)
			UI.press(b, 0.93)
			btns[o.key] = b
			b.Activated:Connect(function()
				if cur == o.key then return end
				cur = o.key
				haptic(0.15)
				paint(true)
				if onPick then onPick(cur) end
			end)
		end
		onTheme(function() paint(false) end, row)
		paint(false)
		return { frame = row, get = function() return cur end, set = function(k) cur = k paint(true) end }
	end

	-- empty state: icon + title + one line
	function UI.empty(parent, icon, title, sub, size)
		local f = mk("Frame", { Size = size or UDim2.new(1, 0, 0, 92), BackgroundTransparency = 1 }, parent)
		local ic = Icon.new(f, icon or "info", 26, "muted")
		ic.frame.AnchorPoint = Vector2.new(0.5, 0)
		ic.frame.Position = UDim2.new(0.5, 0, 0, 8)
		label(f, title or "Nothing here", 13, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 18), TextXAlignment = Enum.TextXAlignment.Center })
		label(f, sub or "", 11, "muted", { Position = UDim2.fromOffset(8, 60), Size = UDim2.new(1, -16, 0, 28), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true })
		return f
	end

	-- tooltip: press and hold 0.45s
	local tipF, tipL
	function UI.tip(inst, text)
		inst.InputBegan:Connect(function(i)
			if not UI.isPress(i) then return end
			local my = os.clock()
			inst:SetAttribute("tipT", my)
			task.delay(0.45, function()
				if dead or not inst.Parent or inst:GetAttribute("tipT") ~= my then return end
				if not tipF then
					tipF = mk("Frame", { Size = UDim2.fromOffset(120, 26), AnchorPoint = Vector2.new(0.5, 1), BorderSizePixel = 0, Visible = false, ZIndex = 120 }, gui)
					themed(tipF, { BackgroundColor3 = "card" })
					round(tipF, 8)
					local ts = mk("UIStroke", { Thickness = 1 }, tipF)
					themed(ts, { Color = "stroke" })
					tipL = label(tipF, "", 11, "text", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, ZIndex = 121 })
				end
				tipL.Text = text
				tipF.Size = UDim2.fromOffset(#text * 6.5 + 22, 26)
				local p = inst.AbsolutePosition + Vector2.new(inst.AbsoluteSize.X / 2, -4)
				tipF.Position = UDim2.fromOffset(p.X, p.Y)
				tipF.Visible = true
				haptic(0.1)
			end)
		end)
		inst.InputEnded:Connect(function() inst:SetAttribute("tipT", nil) if tipF then tipF.Visible = false end end)
	end
end

-- ---------------------------------------------------------------- widget registry (hide / collapse / reorder, saved in cfg.wLayout)
do
	local COLLAPSED_H = 40
	local function save(rec)
		cfg.wLayout[rec.id] = { o = rec.wrap.LayoutOrder, h = rec.hidden or nil, c = rec.collapsed or nil }
		cfgSave()
	end
	local function paintState(rec, animate)
		local h = rec.collapsed and COLLAPSED_H or rec.h
		if animate then tw(rec.wrap, 0.28, { Size = UDim2.new(1, 0, 0, h) }) else rec.wrap.Size = UDim2.new(1, 0, 0, h) end
		rec.wrap.Visible = (not rec.hidden) or UI.editing
		if rec.w.Parent == rec.wrap then rec.w.Visible = true end
	end
	function UI.moveWidget(rec, dir)
		local sib = {}
		for _, r in ipairs(UI.reg) do if r.col == rec.col and r.wrap.Parent then sib[#sib + 1] = r end end
		table.sort(sib, function(a, b) return a.wrap.LayoutOrder < b.wrap.LayoutOrder end)
		local idx = table.find(sib, rec)
		local other = idx and sib[idx + dir]
		if not other then return end
		for n, r in ipairs(sib) do r.wrap.LayoutOrder = n * 10 end
		rec.wrap.LayoutOrder, other.wrap.LayoutOrder = other.wrap.LayoutOrder, rec.wrap.LayoutOrder
		for _, r in ipairs(sib) do save(r) end
	end
	local function buildEdit(rec)
		local ov = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, Visible = false, ZIndex = 50, BorderSizePixel = 0 }, rec.w)
		local row = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(190, 44), BackgroundTransparency = 1, ZIndex = 51 }, ov)
		mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, row)
		local function btn(icon, fn)
			local b = mk("TextButton", { Size = UDim2.fromOffset(42, 42), AutoButtonColor = false, Text = "", BorderSizePixel = 0, ZIndex = 52 }, row)
			themed(b, { BackgroundColor3 = "card" })
			round(b, 21)
			UI.press(b, 0.9)
			local ic = Icon.new(b, icon, 18, "text", 53)
			ic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
			ic.frame.Position = UDim2.fromScale(0.5, 0.5)
			b.Activated:Connect(function() haptic(0.25) fn() end)
		end
		btn("chevU", function() UI.moveWidget(rec, -1) end)
		btn("chevD", function() UI.moveWidget(rec, 1) end)
		btn("eye", function() rec.hidden = not rec.hidden paintState(rec, true) save(rec) end)
		btn("minus", function() rec.collapsed = not rec.collapsed paintState(rec, true) save(rec) end)
		rec.ov = ov
	end
	function UI.setEdit(on)
		if on == UI.editing then return end
		if on and UI.state ~= "open" then return end
		UI.editing = on
		for _, rec in ipairs(UI.reg) do
			if rec.w.Parent then
				if on and not rec.ov then buildEdit(rec) end
				if rec.ov then rec.ov.Visible = on end
				paintState(rec, true)
			end
		end
		if H.editBar then pcall(H.editBar, on) end
	end
	function UI.resetLayout()
		cfg.wLayout = {}
		for _, rec in ipairs(UI.reg) do
			rec.hidden, rec.collapsed, rec.wrap.LayoutOrder = false, false, rec.defOrder
			paintState(rec, true)
		end
		cfgSave()
		toast("ok", "Layout Reset", "Defaults restored", { silent = true })
	end

	-- UI.widget(column, height, id, { order = n }) -> card (Frame), wrap, uiScale, record
	function UI.widget(col, height, id, opts)
		opts = opts or {}
		id = id or ("w" .. (#UI.reg + 1))
		local lay = cfg.wLayout[id] or {}
		local def = opts.order or (#UI.reg + 1) * 10
		local wrap = mk("Frame", { Name = id, Size = UDim2.new(1, 0, 0, height), BackgroundTransparency = 1, LayoutOrder = lay.o or def }, col)
		local w = mk("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, wrap)
		themed(w, { BackgroundColor3 = "card" })
		glassReg(w, 0.16)
		round(w, 16)
		local s = mk("UIStroke", { Thickness = 1, Transparency = 0.2 }, w)
		themed(s, { Color = "stroke" })
		UI.sheen(w)
		local sc = mk("UIScale", { Scale = 1 }, w)
		local rec = { id = id, wrap = wrap, w = w, sc = sc, h = height, col = col, page = col:GetAttribute("page"), hidden = lay.h == true, collapsed = lay.c == true, defOrder = def }
		UI.reg[#UI.reg + 1] = rec
		w.InputBegan:Connect(function(i) -- long press (0.55s, finger still) enters edit mode
			if not UI.isPress(i) then return end
			local p0 = i.Position
			task.delay(0.55, function()
				if dead or UI.editing or UI.state ~= "open" then return end
				if i.UserInputState ~= Enum.UserInputState.End and i.UserInputState ~= Enum.UserInputState.Cancel and (i.Position - p0).Magnitude < 10 then
					haptic(0.6)
					UI.setEdit(true)
				end
			end)
		end)
		paintState(rec, false)
		return w, wrap, sc, rec
	end

	-- error boundary: a widget whose builder throws shows a small error card instead of killing the tab
	function UI.mount(col, id, height, builder, opts)
		local w, wrap, sc, rec = UI.widget(col, height, id, opts)
		local ok, err = xpcall(builder, function(e) return tostring(e) end, w, rec)
		if not ok then
			for _, c in ipairs(w:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
			label(w, (id or "Widget") .. " failed to load", 13, "err", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 12), Size = UDim2.new(1, -28, 0, 18) })
			label(w, tostring(err):sub(1, 90), 11, "muted", { Position = UDim2.fromOffset(14, 34), Size = UDim2.new(1, -28, 0, 30), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
			toast("err", tostring(id), tostring(err):sub(1, 60), { silent = true })
		end
		return w, rec
	end

	-- standard widget header: icon + title (+ right text)
	function UI.header(w, title, icon, right)
		local x = 14
		if icon then
			local ic = Icon.new(w, icon, 16, "accent")
			ic.frame.Position = UDim2.fromOffset(14, 12)
			x = 36
		end
		local t = label(w, title, 13, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(x, 10), Size = UDim2.new(1, -x - 14, 0, 20) })
		local r = right and label(w, right, 11, "muted", { Position = UDim2.new(1, -90, 0, 10), Size = UDim2.fromOffset(76, 20), TextXAlignment = Enum.TextXAlignment.Right })
		return t, r
	end
end

local applyScale, pages, steppers, paintHap, introWidgets
introWidgets = UI.reg
do
-- ============================================================================
-- Shared GUI row helpers (same shapes as this GUI's own toggle rows), used by
-- the Home widgets, the Features tab and the Settings cards built for GenX.
-- ============================================================================
function GXRow(parent, y, icon, title, desc, initial, onChange)
	local row = mk("Frame", { Size = UDim2.new(1, -20, 0, 44), Position = UDim2.fromOffset(10, y), BackgroundTransparency = 1 }, parent)
	local tic = Icon.new(row, icon, 22, "text")
	tic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
	tic.frame.Position = UDim2.fromOffset(21, 22)
	label(row, title, 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(44, 5), Size = UDim2.new(1, -110, 0, 18) })
	label(row, desc, 11, "muted", { Position = UDim2.fromOffset(44, 24), Size = UDim2.new(1, -110, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
	local sw = switch(row, initial, function(v) onChange(v) end)
	sw.frame.AnchorPoint = Vector2.new(1, 0.5)
	sw.frame.Position = UDim2.new(1, -2, 0.5, 0)
	return sw
end

function GXBtn(parent, y, text, primary, onClick)
	local b = button(parent, text, primary, UDim2.new(1, -28, 0, 44), onClick)
	b.Position = UDim2.fromOffset(14, y)
	return b
end

function GXInput(parent, y, placeholder)
	local box = mk("TextBox", {
		Size = UDim2.new(1, -28, 0, 40), Position = UDim2.fromOffset(14, y),
		PlaceholderText = placeholder, Text = "", Font = Enum.Font.Gotham, TextSize = 13,
		ClearTextOnFocus = false, BorderSizePixel = 0, ZIndex = 5,
	}, parent)
	themed(box, { BackgroundColor3 = "bg", TextColor3 = "text", PlaceholderColor3 = "muted" })
	round(box, 10)
	return box
end

-- ============================================================================
-- 15. WINDOW SHELL (fullscreen glass overlay)
-- ============================================================================
local backdrop = mk("Frame", { Name = "Backdrop", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false, ZIndex = 1 }, gui)

-- winHolder fills the screen; its UIScale is compensated by the size so layout works in "virtual pixels"
local winHolder = mk("Frame", {
	Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 2,
}, gui)
local winScale = mk("UIScale", { Scale = UI.scaleNow() }, winHolder)
UI.winHolder, UI.winScale = winHolder, winScale -- the tutorial spotlight is built inside this chain
local shakeLayer = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, winHolder)
UI.shakeLayer = shakeLayer
-- widgets fly through this layer (below the nav bar, above the pages) so they are never clipped by a scrolling column
local flyLayer = mk("Frame", { Name = "Fly", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 8 }, shakeLayer)

-- the haptic fallback: a tiny overlay shake
function H.shake(strength)
	if not winHolder.Visible then return end
	local a = 1.5 + 2.5 * (strength or 0.5)
	task.spawn(function()
		for i = 1, 4 do
			if dead then return end
			local dx = (i % 2 == 0 and 1 or -1) * a / i
			shakeLayer.Position = UDim2.fromOffset(dx, -dx * 0.5)
			task.wait(0.03)
		end
		shakeLayer.Position = UDim2.new()
	end)
end

function applyScale()
	local s = UI.scaleNow()
	winScale.Scale = s
	winHolder.Size = UDim2.fromScale(1 / s, 1 / s)
	N.scale.Scale = math.clamp(fitScale() * 0.95, 0.7, 1.3)
	if UI.layoutTop then UI.layoutTop() end
	if UI.placeFloat then UI.placeFloat(false) end
end
do
	local vpConn
	local function hook()
		if vpConn then vpConn:Disconnect() end
		cam = workspace.CurrentCamera
		if cam then vpConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale) end
		applyScale()
	end
	hook()
	keep(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook))
	onClean(function() if vpConn then vpConn:Disconnect() end end)
end

-- client-side blur behind the overlay (settings slider cfg.blur), pcall-wrapped and cleaned up
do
	local fx
	function UI.blur(on)
		pcall(function()
			if not fx then
				fx = Instance.new("BlurEffect")
				fx.Name = "GenXBlur"
				fx.Size = 0
				fx.Parent = Lighting
				onClean(function() pcall(function() fx:Destroy() end) end)
			end
			tw(fx, 0.45, { Size = on and (cfg.blur * 22) or 0 })
		end)
	end
end

-- ============================================================================
-- 16. TOP BAR (greeting pill, server pill, executor + clock pills, steppers row, notification history)
-- ============================================================================
local topBar = mk("Frame", { Name = "TopBar", Size = UDim2.new(1, 0, 0, 104), BackgroundTransparency = 1, ZIndex = 5 }, shakeLayer)
local P = {} -- top bar parts (a table keeps the local count down)

local function pill(name, w, h, anchor, pos, glass)
	local hold = mk("Frame", { Name = name, Size = UDim2.fromOffset(w, h), AnchorPoint = anchor, Position = pos, BackgroundTransparency = 1, ZIndex = 6 }, topBar)
	local p = mk("CanvasGroup", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, hold)
	themed(p, { BackgroundColor3 = "card" })
	glassReg(p, glass or 0.12)
	round(p, h / 2)
	local s = mk("UIStroke", { Thickness = 1, Transparency = 0.2 }, p)
	themed(s, { Color = "stroke" })
	H.fadeStroke(p, s, 0.2)
	UI.sheen(p)
	UI.chrome[#UI.chrome + 1] = { inst = p, home = UDim2.new(), dy = -64 }
	return hold, p
end
local function timeLine()
	local h = tonumber(os.date("%H"))
	if h >= 5 and h < 11 then return "Morning light, make it a good one"
	elseif h >= 11 and h < 17 then return "Afternoon stretch, keep going"
	elseif h >= 17 and h < 20 then return "It's sunset, wind down a little"
	else return "Late night, the town never sleeps" end
end
local function rbtn(name, icon, tipText)
	local hold, p = pill(name, 44, 44, Vector2.new(0, 0), UDim2.fromOffset(12, 8))
	local ic = Icon.new(p, icon, 20, "text")
	ic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.frame.Position = UDim2.fromScale(0.5, 0.5)
	local hit = mk("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 8 }, hold)
	UI.chrome[#UI.chrome].hit = hit
	UI.press(hit, 0.9, p)
	UI.tip(hit, tipText)
	return hit, hold, ic
end

-- greeting pill (top-left) + notification bell + layout edit button
P.gHold, P.gp = pill("Greeting", 212, 44, Vector2.new(0, 0), UDim2.fromOffset(12, 8), 0.02)
do
	local av = UI.avatarImg(P.gp, LP.UserId, 30, true)
	av.Position = UDim2.fromOffset(7, 7)
	label(P.gp, "Welcome back, " .. LP.DisplayName, 12, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(44, 6), Size = UDim2.new(1, -52, 0, 17), TextTruncate = Enum.TextTruncate.AtEnd })
	P.gSub = label(P.gp, timeLine(), 10, "muted", { Position = UDim2.fromOffset(44, 23), Size = UDim2.new(1, -52, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd })
end
local bellHit, bellHold = rbtn("Bell", "bell", "Notifications")
local editHit, editHold = rbtn("Edit", "grid", "Edit widgets")
P.badge = mk("TextLabel", { Size = UDim2.fromOffset(18, 18), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 2, 0, -2), Text = "0", Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 9 }, bellHold)
themed(P.badge, { BackgroundColor3 = "err" })
round(P.badge, 9)
function H.badge()
	P.badge.Visible = N.unread > 0 and UI.state == "open"
	P.badge.Text = N.unread > 9 and "9+" or tostring(N.unread)
	if P.badge.Visible then P.badge.Size = UDim2.fromOffset(24, 24) tw(P.badge, 0.35, { Size = UDim2.fromOffset(18, 18) }, Enum.EasingStyle.Back) end
end

-- server pill (top-center): players, ping, fps
P.sHold, P.sp = pill("Server", 204, 44, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 8))
P.sv = {}
for i, ic in ipairs({ "users", "signal", "bolt" }) do
	local cell = mk("Frame", { Size = UDim2.new(1 / 3, 0, 1, 0), Position = UDim2.new((i - 1) / 3, 0, 0, 0), BackgroundTransparency = 1 }, P.sp)
	local icon = Icon.new(cell, ic, 14, "accent")
	icon.frame.AnchorPoint = Vector2.new(0, 0.5)
	icon.frame.Position = UDim2.new(0, 10, 0.5, 0)
	P.sv[i] = label(cell, "-", 12, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -30, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
end

-- clock pill + executor pill (top-right)
P.cHold, P.cp = pill("Clock", 108, 44, Vector2.new(1, 0), UDim2.new(1, -12, 0, 8))
P.sun = Icon.new(P.cp, "sun", 16, "warn")
P.moon = Icon.new(P.cp, "moon", 16, "accent2")
for _, ic in ipairs({ P.sun, P.moon }) do ic.frame.AnchorPoint = Vector2.new(0, 0.5) ic.frame.Position = UDim2.new(0, 12, 0.5, 0) end
P.clock = label(P.cp, fmtClock(), 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(36, 5), Size = UDim2.new(1, -40, 0, 18) })
P.date = label(P.cp, os.date("%a %d"), 10, "muted", { Position = UDim2.fromOffset(36, 23), Size = UDim2.new(1, -40, 0, 14) })

P.eHold, P.ep = pill("Executor", 104, 44, Vector2.new(1, 0), UDim2.new(1, -126, 0, 8))
do
	local badge = mk("Frame", { Size = UDim2.fromOffset(28, 28), Position = UDim2.fromOffset(8, 8), BorderSizePixel = 0 }, P.ep)
	themed(badge, { BackgroundColor3 = "accent" })
	round(badge, 14)
	local g = mk("UIGradient", { Rotation = 40 }, badge)
	onTheme(function(th) g.Color = ColorSequence.new(th.accent, th.accent2) end, badge)
	local ic = Icon.new(badge, "chip", 16, Color3.new(1, 1, 1))
	ic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.frame.Position = UDim2.fromScale(0.5, 0.5)
	label(P.ep, EXECUTOR, 12, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(42, 6), Size = UDim2.new(1, -46, 0, 17), TextTruncate = Enum.TextTruncate.AtEnd })
	label(P.ep, "Executor", 10, "muted", { Position = UDim2.fromOffset(42, 23), Size = UDim2.new(1, -46, 0, 14) })
end

-- speed / jump / FOV steppers row (Part 3 fills it; same name and role as before, now always visible on every tab)
steppers = mk("CanvasGroup", { Name = "Steppers", Size = UDim2.fromOffset(372, 44), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 58), BackgroundTransparency = 1, ZIndex = 6 }, topBar)
mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, steppers)
UI.chrome[#UI.chrome + 1] = { inst = steppers, home = steppers.Position, dy = -26 }

-- layout edit bar (replaces the steppers while editing)
P.edit = card(topBar, UDim2.fromOffset(330, 44), { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 58), Visible = false, ZIndex = 7 })
round(P.edit, 22)
label(P.edit, "Editing layout", 12, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(16, 0), Size = UDim2.fromOffset(100, 44) })
do
	local rb = button(P.edit, "Reset", false, UDim2.fromOffset(78, 36), function() UI.resetLayout() end, true)
	rb.Position = UDim2.new(1, -176, 0.5, -18)
	local db = button(P.edit, "Done", true, UDim2.fromOffset(78, 36), function() UI.setEdit(false) end, true)
	db.Position = UDim2.new(1, -92, 0.5, -18)
end
function H.editBar(on)
	P.edit.Visible = on
	steppers.Visible = not on
	if on then P.edit.Position = UDim2.new(0.5, 0, 0, 40) tw(P.edit, 0.35, { Position = UDim2.new(0.5, 0, 0, 58) }, Enum.EasingStyle.Back) end
end
editHit.Activated:Connect(function() haptic(0.3) UI.setEdit(not UI.editing) end)

-- notification history panel: filters, do-not-disturb, clear
P.panel = card(shakeLayer, UDim2.fromOffset(300, 262), { Position = UDim2.fromOffset(12, 58), Visible = false, ZIndex = 30 })
do
	local bp = P.panel
	label(bp, "Notifications", 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(120, 22) })
	local mi = Icon.new(bp, "moon", 14, "muted")
	mi.frame.Position = UDim2.new(1, -116, 0, 17)
	label(bp, "DND", 11, "muted", { Font = Enum.Font.GothamBold, Position = UDim2.new(1, -98, 0, 12), Size = UDim2.fromOffset(30, 22) })
	local dnd = switch(bp, cfg.dnd, function(v)
		cfg.dnd = v
		cfgSave()
		toast("info", "Do Not Disturb", v and "Alerts muted" or "Alerts active", { silent = true, noHistory = true })
	end)
	dnd.frame.Position = UDim2.new(1, -66, 0, 9)
	P.dnd = dnd
	local filt = "all"
	local list = mk("ScrollingFrame", { Position = UDim2.fromOffset(8, 86), Size = UDim2.new(1, -16, 1, -134), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y }, bp)
	mk("UIListLayout", { Padding = UDim.new(0, 4) }, list)
	local function rebuild()
		for _, c in ipairs(list:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
		local n = 0
		for _, h in ipairs(N.history) do
			local k = (h.kind == "join" or h.kind == "leave" or h.kind == "friend") and "info" or h.kind
			if filt == "all" or filt == k then
				n += 1
				local row = mk("Frame", { Size = UDim2.new(1, -4, 0, 44), BorderSizePixel = 0 }, list)
				themed(row, { BackgroundColor3 = "bg" })
				row.BackgroundTransparency = 0.45
				round(row, 10)
				local stl = KIND_STYLE[h.kind] or KIND_STYLE.info
				local dot = mk("Frame", { Size = UDim2.fromOffset(6, 6), Position = UDim2.new(0, 9, 0.5, -3), BorderSizePixel = 0 }, row)
				themed(dot, { BackgroundColor3 = stl.key })
				round(dot, 3)
				label(row, (h.title or "") .. ((h.count or 1) > 1 and ("  x" .. h.count) or ""), 12, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(24, 5), Size = UDim2.new(1, -72, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
				label(row, h.body or "", 11, "muted", { Position = UDim2.fromOffset(24, 23), Size = UDim2.new(1, -72, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
				label(row, os.date("%H:%M", h.at), 10, "muted", { Position = UDim2.new(1, -46, 0, 5), Size = UDim2.fromOffset(40, 16), TextXAlignment = Enum.TextXAlignment.Right })
			end
		end
		if n == 0 then UI.empty(list, "bell", "All quiet", "New alerts show up here", UDim2.new(1, 0, 0, 92)) end
	end
	P.rebuildBell = rebuild
	UI.chips(bp, { { key = "all", text = "All" }, { key = "info", text = "Info" }, { key = "ok", text = "OK" }, { key = "warn", text = "Warn" }, { key = "err", text = "Err" } }, "all", function(k) filt = k rebuild() end, 38).frame.Position = UDim2.fromOffset(10, 44)
	local clear = button(bp, "Clear history", false, UDim2.new(1, -20, 0, 36), function() N.history, N.unread = {}, 0 H.badge() rebuild() end, true)
	clear.Position = UDim2.new(0, 10, 1, -44)
	N.onNew = function() if P.panel.Visible then rebuild() end end
end
bellHit.Activated:Connect(function()
	haptic(0.25)
	P.panel.Visible = not P.panel.Visible
	if P.panel.Visible then
		P.panel.Position = UDim2.fromOffset(12, 70)
		tw(P.panel, 0.3, { Position = UDim2.fromOffset(12, 58) }, Enum.EasingStyle.Back)
		P.rebuildBell()
		N.unread = 0
		H.badge()
	end
end)

-- haptics indicator lives on the emblem's status dot (see section 18)
function paintHap() if UI.hapDot then UI.hapDot.BackgroundColor3 = cfg.haptics and T().ok or T().stroke end end

-- narrow screens: smaller greeting + server pill so nothing overlaps
function UI.layoutTop()
	local W = viewport().X / winScale.Scale
	local gw = W < 800 and 150 or 212
	P.gHold.Size = UDim2.fromOffset(gw, 44)
	bellHold.Position = UDim2.fromOffset(12 + gw + 6, 8)
	editHold.Position = UDim2.fromOffset(12 + gw + 56, 8)
	P.sHold.Size = UDim2.fromOffset(W < 760 and 180 or 204, 44)
end

-- top bar refresh: 1s, paused while the overlay is hidden
do
	local frames, fps, last = 0, 60, os.clock()
	UI.onFrame(function()
		frames += 1
		local now = os.clock()
		if now - last >= 1 then fps, frames, last = frames / (now - last), 0, now UI.fps = fps end
	end)
	local lastMin
	task.spawn(function()
		while not dead do
			if UI.state ~= "closed" and winHolder.Visible then
				pcall(function()
					P.sv[1].Text = #Players:GetPlayers() .. "/" .. Players.MaxPlayers
					local ok, ping = pcall(function() return LP:GetNetworkPing() * 1000 end)
					P.sv[2].Text = ok and string.format("%dms", ping) or "n/a"
					P.sv[3].Text = cfg.fps and string.format("%d", fps) or "off"
					local t = fmtClock()
					if t ~= lastMin then
						lastMin = t
						P.clock.Text = t
						P.date.Text = os.date("%a %d")
						P.gSub.Text = timeLine()
						local h = tonumber(os.date("%H"))
						local day = h >= 6 and h < 19
						P.sun.frame.Visible, P.moon.frame.Visible = day, not day
					end
				end)
			end
			task.wait(1)
		end
	end)
end

-- ============================================================================
-- 17. PAGES + NAV PILL
-- ============================================================================
local pagesHolder = mk("Frame", { Name = "Pages", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 3 }, shakeLayer)

local function makePage(name)
	return mk("Frame", { Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 3 }, pagesHolder)
end
pages = { Home = makePage("Home"), Avatar = makePage("Avatar"), Troll = makePage("Troll"), Settings = makePage("Settings") }

-- two scrolling side columns per page, the screen center stays empty and touch-through:
--   local colL, colR = UI.columns(pages.Home)   then   UI.mount(colL, "profile", 220, function(w) ... end)
function UI.columns(page)
	local function col(side)
		-- the scrolling column sits inside ONE rounded CanvasGroup: whatever scrolls past the top or bottom edge is cut along a curve. The cards inside are plain Frames now (CanvasGroup inside CanvasGroup made phones drop the inner layer after Copy Avatar: blank cards, outline only)
		local holder = mk("CanvasGroup", {
			Name = side .. "Holder", AnchorPoint = Vector2.new(side == "R" and 1 or 0, 0), Position = UDim2.new(side == "R" and 1 or 0, side == "R" and -12 or 12, 0, 108),
			Size = UDim2.new(0.34, 0, 1, -128), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 3,
		}, page)
		mk("UICorner", { CornerRadius = UDim.new(0, 36) }, holder)
		mk("UISizeConstraint", { MinSize = Vector2.new(210, 0), MaxSize = Vector2.new(310, 99999) }, holder)
		local c = mk("ScrollingFrame", {
			Name = side, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 0, CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, ZIndex = 3,
		}, holder)
		mk("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, c)
		mk("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 16), PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 2) }, c)
		c:SetAttribute("page", page.Name)
		UI.cols = UI.cols or {}
		UI.cols[#UI.cols + 1] = { holder = holder, c = c, page = page }
		c.ScrollBarThickness = 3
		c.ScrollBarImageTransparency = 0.35
		themed(c, { ScrollBarImageColor3 = "accent" })
		return c
	end
	return col("L"), col("R")
end

local PAGE_META = {
	Home = { title = "Home", sub = "Welcome back", icon = "navHome" },
	Avatar = { title = "Avatar", sub = "Copy any look", icon = "navAvatar" },
	Troll = { title = "Features", sub = "Life Together features", icon = "navTroll" },
	Settings = { title = "Settings", sub = "Make it yours", icon = "navSettings" },
}
local TAB_ORDER = { "Home", "Avatar", "Troll", "Settings" }

local navH = mk("Frame", { Name = "NavHolder", Size = UDim2.fromOffset(296, 54), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10), BackgroundTransparency = 1, ZIndex = 10 }, shakeLayer)
local nav = mk("CanvasGroup", { Name = "Nav", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, navH)
themed(nav, { BackgroundColor3 = "card" })
glassReg(nav, 0.08)
round(nav, 27)
do
	local s = mk("UIStroke", { Thickness = 1.2, Transparency = 0.1 }, nav)
	themed(s, { Color = "stroke" })
	H.fadeStroke(nav, s, 0.1)
	UI.sheen(nav)
	-- the tab buttons live in their own row: the sheen is a full-size child of nav, and sitting in the same list layout it took the first slot and pushed the tabs out of view
	UI.navRow = mk("Frame", { Name = "Row", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 10 }, nav)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, UI.navRow)
	UI.chrome[#UI.chrome + 1] = { inst = nav, home = UDim2.new(), dy = 40, nav = true }
end

local navBtns, navX = {}, {}
local function paintNav(animate)
	local th = T()
	for _, name in ipairs(TAB_ORDER) do
		local b, nx = navBtns[name], navX[name]
		local active = UI.curTab == name
		local w = active and 108 or 46
		nx.tl.Visible = active
		nx.ic.color(active and Color3.new(1, 1, 1) or th.text)
		nx.ic.frame.Position = active and UDim2.fromOffset(26, 22) or UDim2.fromScale(0.5, 0.5)
		nx.g.Color = ColorSequence.new(th.accent, th.accent2)
		b.TextColor3 = active and Color3.new(1, 1, 1) or th.muted
		b.BackgroundColor3 = active and th.accent or th.bg
		if animate then
			tw(b, 0.32, { Size = UDim2.fromOffset(w, 44), BackgroundTransparency = active and 0.05 or 0.5 }, Enum.EasingStyle.Quint)
		else
			b.Size = UDim2.fromOffset(w, 44)
			b.BackgroundTransparency = active and 0.05 or 0.5
		end
	end
end

-- in-place entrance for one page: slide + fade + scale, staggered
function UI.enter(name, dir)
	local i = 0
	for _, rec in ipairs(UI.reg) do
		if rec.page == name and not rec.hidden then
			if rec.w.Parent ~= rec.wrap then UI.settle(rec) end
			i += 1
			rec.tok = (rec.tok or 0) + 1
			rec.busy = os.clock() + (i - 1) * 0.04 + 0.8
			local my = rec.tok
			rec.w.Position = UDim2.new(0.5, (dir or 1) * 34, 0.5, 0)
			rec.w.Visible = false
			rec.sc.Scale = 0.94
			task.delay((i - 1) * 0.04, function()
				if rec.tok ~= my or not rec.w.Parent then return end
				rec.w.Visible = true
				tw(rec.w, 0.45, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Quint)
				tw(rec.sc, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
			end)
		end
	end
end

-- which tab to start on (remember last tab setting)
function UI.startTab() return (cfg.rememberTab and pages[cfg.lastTab]) and cfg.lastTab or "Home" end

UI.tabEntered = {} -- tabs whose entrance animation has already played once
local function showTab(name, instant)
	if not pages[name] then name = "Home" end
	if UI.curTab == name and pages[name].Visible then return end
	local prev = UI.curTab
	local dir = (prev and (table.find(TAB_ORDER, name) or 1) < (table.find(TAB_ORDER, prev) or 1)) and -1 or 1
	UI.curTab = name
	P.panel.Visible = false
	if UI.editing then UI.setEdit(false) end
	for n, p in pairs(pages) do if n ~= name then p.Visible = false end end
	pages[name].Visible = true
	if cfg.rememberTab then cfg.lastTab = name cfgSave() end
	paintNav(not instant)
	if not instant and UI.state == "open" and not UI.tabEntered[name] then
		UI.tabEntered[name] = true
		UI.enter(name, dir)
	end
	if H.onTab then pcall(H.onTab, name, prev) end
	if UI.burst then UI.burst() end
end
UI.showTab = showTab

for ti, name in ipairs(TAB_ORDER) do
	local b = mk("TextButton", { Name = name, LayoutOrder = ti, Size = UDim2.fromOffset(46, 44), AutoButtonColor = false, Text = "", BorderSizePixel = 0, ZIndex = 11 }, UI.navRow)
	round(b, 22)
	local g = mk("UIGradient", { Rotation = 25 }, b)
	UI.press(b, 0.93)
	b.Activated:Connect(function()
		haptic(0.25)
		showTab(name)
		if UI.state == "docked" then UI.setDock(false) end
	end)
	UI.tip(b, PAGE_META[name].title)
	local nic = Icon.new(b, PAGE_META[name].icon, 20, Color3.new(1, 1, 1), 12)
	nic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
	nic.frame.Position = UDim2.fromScale(0.5, 0.5)
	local ntl = mk("TextLabel", { BackgroundTransparency = 1, Text = PAGE_META[name].title, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -48, 1, 0), Position = UDim2.fromOffset(44, 0), ZIndex = 12 }, b)
	navX[name] = { ic = nic, tl = ntl, g = g }
	navBtns[name] = b
end
onTheme(function() if nav.Parent then paintNav(false) end end, nav)

-- ============================================================================
-- 18. TOGGLE BUTTON (premium emblem) + OPEN / CLOSE / DOCK
-- ============================================================================
-- top bar + nav slide in / out. topOnly keeps the nav bar visible (dock mode)
function UI.chromeShow(on, instant, topOnly)
	P.badge.Visible = on and N.unread > 0 -- the badge lives outside the pills, so it follows the top bar by hand
	for i, e in ipairs(UI.chrome) do
		if not (topOnly and e.nav) then
			local away = e.home + UDim2.fromOffset(0, e.dy)
			local target, gt = on and e.home or away, on and 0 or 1
			-- a CanvasGroup keeps drawing its own outline at full transparency: switch the whole thing off once it has slid away
			e.tok = (e.tok or 0) + 1
			local my = e.tok
			local canHide = e.inst ~= steppers
			if e.hit then e.hit.Visible = on end
			if on and canHide then e.inst.Visible = true end
			local snap = instant or (on and e.nav) -- the bottom nav bar never animates in: it is simply there
			if snap then
				e.inst.Position, e.inst.GroupTransparency = target, gt
				if not on and canHide then e.inst.Visible = false end
			else
				if on then e.inst.Position, e.inst.GroupTransparency = away, 1 end
				task.delay((i - 1) * 0.035, function()
					if not e.inst.Parent then return end
					tw(e.inst, on and 0.55 or 0.35, { Position = target }, on and Enum.EasingStyle.Back or Enum.EasingStyle.Quint)
					tw(e.inst, 0.3, { GroupTransparency = gt }, Enum.EasingStyle.Sine)
				end)
				if not on and canHide then
					task.delay(0.45 + (i - 1) * 0.035, function()
						if e.tok == my and e.inst.Parent then e.inst.Visible = false end
					end)
				end
			end
		end
	end
end

-- widget fly engine: widgets leave their column, travel through flyLayer and shrink into the nav bar (and back out)
do
	local function navPoint() return (navH.AbsolutePosition + navH.AbsoluteSize / 2 - flyLayer.AbsolutePosition) / winScale.Scale end
	local function geom(rec)
		local sc = winScale.Scale
		return (rec.wrap.AbsolutePosition + rec.wrap.AbsoluteSize / 2 - flyLayer.AbsolutePosition) / sc, rec.wrap.AbsoluteSize / sc
	end
	local function inView(rec)
		local a, s, ca, cs = rec.wrap.AbsolutePosition, rec.wrap.AbsoluteSize, rec.col.AbsolutePosition, rec.col.AbsoluteSize
		local cx, cy = a.X + s.X / 2, a.Y + s.Y / 2
		return cy > ca.Y and cy < ca.Y + cs.Y and cx > ca.X and cx < ca.X + cs.X
	end
	-- a card cut by the column's top or bottom edge must not fly on the unclipped layer (it would show its full size, then snap when it lands)
	local function fullyInside(rec)
		local a, s, ca, cs = rec.wrap.AbsolutePosition, rec.wrap.AbsoluteSize, rec.col.AbsolutePosition, rec.col.AbsoluteSize
		return a.Y >= ca.Y - 1 and a.Y + s.Y <= ca.Y + cs.Y + 1
	end
	function UI.settle(rec) -- back into its column, resting
		if rec.w.Parent ~= rec.wrap then rec.w.Parent = rec.wrap end
		rec.w.Position, rec.w.Size, rec.sc.Scale = UDim2.fromScale(0.5, 0.5), UDim2.fromScale(1, 1), 1
		rec.w.Visible = true
	end
	local function stash(rec, delay)
		rec.tok = (rec.tok or 0) + 1
		rec.busy = os.clock() + delay + 0.95
		local my = rec.tok
		if rec.w.Parent == rec.wrap then
			if not inView(rec) then rec.w.Visible, rec.sc.Scale = false, 0.2 return end
			local c, sz = geom(rec)
			rec.w.Size = UDim2.fromOffset(sz.X, sz.Y)
			rec.w.Position = UDim2.fromOffset(c.X, c.Y)
			rec.w.Parent = flyLayer
		end
		local nx = navPoint()
		task.delay(delay, function()
			if rec.tok ~= my or not rec.w.Parent then return end
			tw(rec.w, 0.5, { Position = UDim2.fromOffset(nx.X, nx.Y) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
			tw(rec.sc, 0.5, { Scale = 0.12 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
			task.delay(0.55, function() if rec.tok == my and rec.w.Parent then rec.w.Visible = false end end)
		end)
	end
	local function rise(rec, delay, k)
		rec.tok = (rec.tok or 0) + 1
		rec.busy = os.clock() + delay + 0.8 * k + 0.1
		local my = rec.tok
		local c, sz = geom(rec)
		local nx = navPoint()
		rec.w.Visible, rec.sc.Scale = false, 0.12
		if inView(rec) and fullyInside(rec) then
			rec.w.Size = UDim2.fromOffset(sz.X, sz.Y)
			rec.w.Position = UDim2.fromOffset(nx.X, nx.Y)
			rec.w.Parent = flyLayer
		else
			rec.w.Parent, rec.w.Size, rec.w.Position = rec.wrap, UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5)
		end
		task.delay(delay, function()
			if rec.tok ~= my or not rec.w.Parent then return end
			rec.w.Visible = true
			if rec.w.Parent == flyLayer then tw(rec.w, 0.6 * k, { Position = UDim2.fromOffset(c.X, c.Y) }, Enum.EasingStyle.Quint) end
			tw(rec.sc, 0.65 * k, { Scale = 1 }, Enum.EasingStyle.Back)
			task.delay(0.68 * k, function() if rec.tok == my then UI.settle(rec) end end)
		end)
	end
	function UI.hideWidgets()
		local i = 0
		for _, rec in ipairs(UI.reg) do
			if rec.page == UI.curTab and not rec.hidden then i += 1 stash(rec, (i - 1) * 0.05) end
		end
	end
	function UI.showWidgets(slow)
		local i = 0
		for _, rec in ipairs(UI.reg) do
			if rec.page == UI.curTab and not rec.hidden then i += 1 rise(rec, (i - 1) * (slow and 0.12 or 0.055), slow and 3 or 1) end
		end
	end
	-- cancel any flight and put everything where the current state says it belongs
	function UI.assembleSnap()
		for _, rec in ipairs(UI.reg) do
			rec.tok = (rec.tok or 0) + 1
			if rec.page == UI.curTab and UI.state == "open" then UI.settle(rec) end
		end
	end
	function UI.assemble(slow) UI.showWidgets(slow) end
end

-- the emblem: layered core, rotating gradient ring, breathing halo. Frames + UIGradient + UIStroke only
local floatBtn = mk("TextButton", { Name = "GenXButton", Size = UDim2.fromOffset(58, 58), Text = "", AutoButtonColor = false, BackgroundTransparency = 1, ZIndex = 100 }, gui)
do
	local function circ(size, z, parent)
		local f = mk("Frame", { Size = UDim2.fromOffset(size, size), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BorderSizePixel = 0, ZIndex = z }, parent or floatBtn)
		mk("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
		return f
	end
	local arc = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.25, 1), NumberSequenceKeypoint.new(0.55, 0), NumberSequenceKeypoint.new(0.8, 0.7), NumberSequenceKeypoint.new(1, 1) })
	local halo = circ(78, 100)
	themed(halo, { BackgroundColor3 = "accent" })
	halo.BackgroundTransparency = 0.86
	local haloS = mk("UIScale", { Scale = 1 }, halo)
	local ring = circ(58, 101)
	ring.BackgroundTransparency = 1
	local ringStroke = mk("UIStroke", { Thickness = 3, Color = Color3.new(1, 1, 1) }, ring)
	local ringG = mk("UIGradient", { Transparency = arc }, ringStroke)
	local ring2 = circ(40, 101)
	ring2.BackgroundTransparency = 1
	local ring2Stroke = mk("UIStroke", { Thickness = 1.5, Color = Color3.new(1, 1, 1) }, ring2)
	local ring2G = mk("UIGradient", { Transparency = arc }, ring2Stroke)
	local body = circ(48, 102)
	themed(body, { BackgroundColor3 = "bg" })
	body.BackgroundTransparency = 0.08
	local bs = mk("UIStroke", { Thickness = 1, Transparency = 0.3 }, body)
	themed(bs, { Color = "stroke" })
	local core = circ(24, 103)
	core.BackgroundColor3 = Color3.new(1, 1, 1)
	local coreG = mk("UIGradient", { Rotation = 0 }, core)
	local glint = circ(9, 104)
	glint.BackgroundColor3 = Color3.new(1, 1, 1)
	glint.Position = UDim2.new(0.5, -4, 0.5, -4)
	UI.hapDot = circ(9, 105)
	UI.hapDot.AnchorPoint = Vector2.new(1, 1)
	UI.hapDot.Position = UDim2.new(1, -4, 1, -4)
	local hs = mk("UIStroke", { Thickness = 1.5, Color = Color3.new(0, 0, 0), Transparency = 0.5 }, UI.hapDot)
	local pulseS = mk("UIScale", { Scale = 1 }, floatBtn)
	onTheme(function(th)
		local seq = ColorSequence.new({ ColorSequenceKeypoint.new(0, th.accent2), ColorSequenceKeypoint.new(0.5, th.accent:Lerp(Color3.new(1, 1, 1), 0.6)), ColorSequenceKeypoint.new(1, th.accent) })
		ringG.Color, ring2G.Color = seq, seq
		coreG.Color = ColorSequence.new(th.accent2, th.accent)
		paintHap()
	end, floatBtn)
	UI.onFrame(function(t)
		ringG.Rotation = (t * 140) % 360
		ring2G.Rotation = (-t * 95) % 360
		coreG.Rotation = (t * 60) % 360
		local b = math.sin(t * 2.4)
		haloS.Scale = 1 + 0.09 * b
		halo.BackgroundTransparency = 0.86 - 0.05 * b
		glint.BackgroundTransparency = 0.3 + 0.2 * b
	end)
	-- haptic visual fallback + state change flash
	function H.pulse()
		if not floatBtn.Parent then return end
		pulseS.Scale = 1.16
		tw(pulseS, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

local function placeFloat(reset)
	local vp = viewport()
	if reset or cfg.btnX < 0 then cfg.btnX, cfg.btnY = 0.03, 0.4 end
	floatBtn.Position = UDim2.fromOffset(
		math.clamp(cfg.btnX * vp.X, 0, vp.X - 58), math.clamp(cfg.btnY * vp.Y, 0, vp.Y - 58))
end
UI.placeFloat = placeFloat
placeFloat(false)

-- ---------------------------------------------------------------- Roblox's own HUD
-- hidden while the full menu is open, put back exactly as it was the instant the menu is docked or closed.
-- (no new top-level locals on purpose: this file sits close to Lua's 200-local limit, so state lives on H)
H.hudS = { on = false, core = {}, chat = {}, guis = {}, locks = {}, topbar = nil, added = nil, addedCore = nil }

function H.hudLock(g)
	local HUD = H.hudS
	if not g:IsA("ScreenGui") or g == gui or g.Name == "TouchGui" then return end -- TouchGui = thumbstick + jump, stays so you can still walk
	if HUD.guis[g] == nil then HUD.guis[g] = g.Enabled end
	pcall(function() g.Enabled = false end)
	if not HUD.locks[g] then
		HUD.locks[g] = g:GetPropertyChangedSignal("Enabled"):Connect(function()
			if HUD.on and g.Enabled then pcall(function() g.Enabled = false end) end -- the game turned it back on, push it off again
		end)
	end
end

H.hudTopSaved = {}
function H.hudTop(on)
	if not on then
		for inst, v in pairs(H.hudTopSaved) do
			if inst.Parent then pcall(function() inst.Visible = v end) end
		end
		H.hudTopSaved = {}
		return
	end
	local saved, roots = H.hudTopSaved, {}
	for _, g in ipairs(CoreGui:GetChildren()) do
		if g:IsA("ScreenGui") and g.Name:lower():find("topbar") then roots[#roots + 1] = g end
	end
	local rg = CoreGui:FindFirstChild("RobloxGui")
	if rg then
		for _, g in ipairs(rg:GetChildren()) do
			if g:IsA("GuiObject") and g.Name:lower():find("topbar") then roots[#roots + 1] = g end
		end
	end
	-- the left cluster (logo / menu / mic) can sit deeper than 3 levels or in a gui not named like the top bar: find it by name, throttled
	H.hudScanT = (H.hudScanT or 0) + 1
	if H.hudScanT % 5 == 1 then
		local ok, desc = pcall(function() return CoreGui:GetDescendants() end)
		if ok then
			for _, d in ipairs(desc) do
				local n = d.Name:lower()
				if (n:find("unibar", 1, true) or n:find("topbarapp", 1, true) or n:find("topbarleft", 1, true)) and d ~= gui then
					if d:IsA("ScreenGui") then H.hudLock(d)
					elseif d:IsA("GuiObject") and d.Visible then
						if saved[d] == nil then saved[d] = true end
						d.Visible = false
					end
				end
			end
		end
	end
	for _, r in ipairs(roots) do
		if r:IsA("ScreenGui") then H.hudLock(r)
		elseif r.Visible then
			if saved[r] == nil then saved[r] = true end
			r.Visible = false
		end
		for _, c in ipairs(r:GetChildren()) do
			if c:IsA("GuiObject") then
				if c.Visible then if saved[c] == nil then saved[c] = true end c.Visible = false end
				for _, d in ipairs(c:GetChildren()) do
					if d:IsA("GuiObject") and d.Visible then if saved[d] == nil then saved[d] = true end d.Visible = false end
				end
			end
		end
	end
end

function UI.hud(hide)
	local HUD = H.hudS
	hide = (hide and cfg.hideHud ~= false) and true or false
	if hide == HUD.on then return end
	HUD.on = hide
	-- what Roblox looked like BEFORE we touched it. These calls change each other's state (turning the chat core gui off also turns the
	-- chat window config off, turning the top bar off disables its gui), so everything is read first, and kept across quick open/close
	H.hudOrig = H.hudOrig or { core = {}, chat = {}, gui = setmetatable({}, { __mode = "k" }), topbar = nil }
	local O = H.hudOrig
	if hide then
		local fresh = (os.clock() - (H.hudRestoreT or -10)) > 2
		HUD.core, HUD.chat, HUD.guis, HUD.locks = {}, {}, {}, {}
		-- 1) read
		for _, t in ipairs(Enum.CoreGuiType:GetEnumItems()) do
			if t ~= Enum.CoreGuiType.All then
				local ok, was = pcall(function() return StarterGui:GetCoreGuiEnabled(t) end)
				if ok then
					if O.core[t] == nil or fresh then O.core[t] = was end
					HUD.core[t] = O.core[t]
				end
			end
		end
		local okT, tb = pcall(function() return StarterGui:GetCore("TopbarEnabled") end)
		if okT then
			if O.topbar == nil or fresh then O.topbar = tb end
			HUD.topbar = O.topbar
		else
			HUD.topbar = nil
		end
		for _, n in ipairs({ "ChatWindowConfiguration", "ChatInputBarConfiguration" }) do
			local c = TextChatService:FindFirstChild(n)
			if c then
				local ok, was = pcall(function() return c.Enabled end)
				if ok then
					if O.chat[c] == nil or fresh then O.chat[c] = was end
					HUD.chat[c] = O.chat[c]
				end
			end
		end
		for _, g in ipairs(CoreGui:GetChildren()) do
			if g:IsA("ScreenGui") and g.Name:lower():find("topbar") then
				if O.gui[g] == nil or fresh then O.gui[g] = g.Enabled end
				HUD.guis[g] = true -- the top bar always comes back
			end
		end
		-- chat and the top bar are never meant to stay off: restore them to ON no matter what was read (a leftover from an earlier run can read as off)
		HUD.core[Enum.CoreGuiType.Chat] = true
		for c in pairs(HUD.chat) do HUD.chat[c] = true end
		if HUD.topbar ~= nil then HUD.topbar = true end
		-- 2) hide
		for t, was in pairs(HUD.core) do
			if was then pcall(function() StarterGui:SetCoreGuiEnabled(t, false) end) end
		end
		if HUD.topbar ~= nil then pcall(function() StarterGui:SetCore("TopbarEnabled", false) end) end
		for c in pairs(HUD.chat) do pcall(function() c.Enabled = false end) end
		-- the game's own HUD (everything in PlayerGui except the touch controls), including ones it adds later
		local pg = LP:FindFirstChildOfClass("PlayerGui")
		if pg then
			for _, g in ipairs(pg:GetChildren()) do H.hudLock(g) end
			HUD.added = pg.ChildAdded:Connect(function(g) if HUD.on then H.hudLock(g) end end)
		end
		-- Roblox's own top bar app (logo / menu / mic icons) ignores TopbarEnabled on newer clients: hide it directly
		pcall(H.hudTop, true)
		pcall(function()
			HUD.addedCore = CoreGui.ChildAdded:Connect(function() if HUD.on then task.defer(function() pcall(H.hudTop, true) end) end end)
		end)
		HUD.acc = 0
		HUD.enforce = RunService.Heartbeat:Connect(function(dt)
			HUD.acc += dt
			if HUD.acc < 0.3 then return end
			HUD.acc = 0
			if HUD.on then pcall(H.hudTop, true) end -- Roblox re-shows it now and then: push it off again
		end)
	else
		H.hudRestoreT = os.clock()
		if HUD.enforce then HUD.enforce:Disconnect() HUD.enforce = nil end
		if HUD.added then HUD.added:Disconnect() HUD.added = nil end
		if HUD.addedCore then HUD.addedCore:Disconnect() HUD.addedCore = nil end
		pcall(H.hudTop, false) -- top bar back first, same frame
		for _, c in pairs(HUD.locks) do c:Disconnect() end
		local core, chat, guis, topv = HUD.core, HUD.chat, HUD.guis, HUD.topbar
		local function apply()
			for g, was in pairs(guis) do
				if was and g.Parent and not g.Enabled then pcall(function() g.Enabled = true end) end
			end
			for t, was in pairs(core) do
				if was then pcall(function() StarterGui:SetCoreGuiEnabled(t, true) end) end
			end
			if topv ~= nil then pcall(function() StarterGui:SetCore("TopbarEnabled", topv) end) end
			for c, was in pairs(chat) do
				if c.Parent then pcall(function() c.Enabled = was end) end
			end
		end
		apply() -- instantly
		task.delay(0.12, function() if not HUD.on then apply() end end) -- and again, in case Roblox or the game switched something back off
		task.delay(0.5, function() if not HUD.on then apply() end end)
		if H.drvPending and H.drvRecover then -- an Unfollow finished while the menu was open: its HUD restore was held back, do it now
			task.delay(0.7, function() if H.drvPending and not HUD.on then pcall(H.drvRecover, "menu closed") end end)
		end
		HUD.core, HUD.chat, HUD.guis, HUD.locks, HUD.topbar = {}, {}, {}, {}, nil
	end
end
onClean(function() UI.hud(false) end)
-- unstick: if an earlier run left Roblox's chat / top bar switched off, put them back on as this one starts
task.defer(function()
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true) end)
	pcall(function() StarterGui:SetCore("TopbarEnabled", true) end)
	for _, n in ipairs({ "ChatWindowConfiguration", "ChatInputBarConfiguration" }) do
		local c = TextChatService:FindFirstChild(n)
		if c then pcall(function() c.Enabled = true end) end
	end
	local tb = CoreGui:FindFirstChild("TopBarApp")
	if tb and tb:IsA("ScreenGui") then pcall(function() tb.Enabled = true end) end
end)

-- states: "closed" (only the emblem) | "open" (widgets out) | "docked" (widgets inside the nav bar, bar stays)
function UI.setDock(on, instant)
	if UI.state == "closed" then return end
	if on == (UI.state == "docked") then return end
	UI.setEdit(false)
	P.panel.Visible = false
	UI.state = on and "docked" or "open"
	if on then
		UI.hideWidgets()
		pagesHolder.Visible = false -- columns gone: only the nav pill can catch a touch, the camera is free
		UI.hud(false) -- docked = menu "off": every Roblox / in-game icon comes straight back
		UI.chromeShow(false, instant, true)
		UI.blur(false)
	else
		pagesHolder.Visible = true
		UI.chromeShow(true, instant, true)
		UI.showWidgets()
		UI.blur(true)
		UI.hud(true)
	end
	if H.pulse then H.pulse() end
end

local function setOpen(open, instant)
	if open then
		if UI.state ~= "closed" then
			if UI.state == "docked" then UI.setDock(false) end
			return
		end
		UI.state = "open"
		backdrop.Visible = true
		winHolder.Visible = true
		pcall(function() winHolder.Interactable = true end)
		pagesHolder.Visible = true
		UI.hud(true)
		tw(backdrop, 0.4, { BackgroundTransparency = 1 }) -- no dimming: the world keeps its normal brightness
		UI.chromeShow(true, instant)
		UI.blur(true)
		N.place()
		if instant then UI.assembleSnap() else UI.assemble() end
	else
		if UI.state == "closed" then return end
		local was = UI.state
		UI.hud(false) -- Roblox HUD comes back first, instantly
		UI.setEdit(false)
		UI.state = "closed"
		P.panel.Visible = false
		if was ~= "docked" then UI.hideWidgets() end
		pagesHolder.Visible = false -- release every column at once, nothing left to block touches
		pcall(function() winHolder.Interactable = false end)
		UI.chromeShow(false)
		tw(backdrop, 0.3, { BackgroundTransparency = 1 })
		UI.blur(false)
		N.place()
		task.delay(0.7, function()
			if UI.state == "closed" and not dead then winHolder.Visible = false backdrop.Visible = false end
		end)
	end
	if H.pulse then H.pulse() end
end
UI.setOpen = setOpen

-- single tap: dock / undock the widgets. fast double tap (< 0.3s): close the whole GUI. tap while closed: open.
do
	local lastTap = 0
	makeDraggable(floatBtn, floatBtn, function()
		haptic(0.4)
		local now = os.clock()
		if UI.state == "closed" then lastTap = 0 setOpen(true) return end
		if now - lastTap < 0.3 then lastTap = 0 setOpen(false) return end
		lastTap = now
		UI.setDock(UI.state ~= "docked")
	end, function()
		local vp = viewport()
		cfg.btnX, cfg.btnY = floatBtn.Position.X.Offset / vp.X, floatBtn.Position.Y.Offset / vp.Y
		cfgSave()
	end)
end
UI.tip(floatBtn, "Tap: dock  -  Double tap: close")
applyScale()
-- (the `do` block opened above is closed by Part 2, at the end of section 19)

-- ============================================================================
-- PART 2 / 3  |  replaces: 19, 19b, 20, 21, 22, 23   (paste right after Part 1)
-- The `do` Part 1 left open is closed by the first `end` below.
-- Home page: left column = profile (here) + toggles / extras / gravity (Part 3),
--            right column = quick commands, server, game, avatar copying (here).
-- ============================================================================

-- ============================================================================
-- 19. FIRST OPEN (the old shatter intro is gone: the new shell flies the widgets in itself)
-- ============================================================================
function UI.firstOpen()
	UI.showTab(UI.startTab(), true)
	if cfg.playIntro then
		-- one-shot slow fly-in: UI.setOpen calls UI.assemble() once, so wrap it for that single call
		local orig = UI.assemble
		UI.assemble = function() UI.assemble = orig orig(true) end
		UI.setOpen(true)
	else
		UI.setOpen(true, true)
	end
end

-- v1.1.4: floatBtn / winHolder / pagesHolder / nav only exist inside this block, but the watchdog below (Part 2) is outside it, so it
-- read them as nil globals: invariants() crashed every frame and the rest of the Heartbeat handler (the heal calls) never ran. Shared through UI now.
UI.floatBtn, UI.winHolder, UI.pagesHolder, UI.nav = floatBtn, winHolder, pagesHolder, nav

end -- closes the `do` opened at the end of Part 1

local tickFns, Server
do

-- ============================================================================
-- 20. SHARED TICKER (server stats, studs-away, stepper refresh). Runs only while the GUI is visible.
-- ============================================================================
tickFns = {}
task.spawn(function()
	while not dead do
		if UI.state ~= "closed" then
			for _, fn in ipairs(tickFns) do pcall(fn) end
		end
		task.wait(0.5)
	end
end)

-- ============================================================================
-- 21. SERVER ACTIONS (server hop reads Roblox's public server list so it can pick a server with exactly 27 players)
-- ============================================================================
Server = {}
-- Auto relaunch: when THIS script rejoins or hops (a teleport it started),
-- it queues a loader for itself so it launches again in the next server.
-- Leaving on your own never queues anything, so a manual leave stays left.
-- The script is hosted on GitHub and runs from a loadstring, so the queued
-- loader just fetches that same URL fresh in the new server - no file in
-- the executor workspace is needed, and whatever version is hosted at the
-- URL is the one that comes up. (The two special letters in the file name
-- are written in URL code so HttpGet handles the address cleanly.) The old
-- workspace-file read stays underneath as a fallback for local-file runs.
local RELAUNCH_URL = "https://raw.githubusercontent.com/marvens7999/QX7V-RTHA93ZK-M4P8NW/refs/heads/main/QX7V%C3%98RTHA93ZK%CE%9BM4P8NW.lua"
local RELAUNCH_FILES = { "GenX_LifeTogether_v6.lua", "GenX_LifeTogether.lua", "genx_lifetogether.lua" }
local function relaunchLoaderSource()
	return ("if game.PlaceId == %d then\n\trepeat task.wait() until game:IsLoaded()\n\tlocal g = (getgenv and getgenv()) or _G\n\tg.GX_RELAUNCHED = true\n\tloadstring(game:HttpGet(%q))()\nend"):format(DREAMVILLE_PLACE_ID, RELAUNCH_URL)
end
function queueRelaunch()
	local qot = queue_on_teleport or (syn and syn.queue_on_teleport)
	if type(qot) ~= "function" then return false end
	if pcall(qot, relaunchLoaderSource()) then return true end
	if type(isfile) == "function" and type(readfile) == "function" then
		for _, name in ipairs(RELAUNCH_FILES) do
			if isfile(name) then
				local ok, src = pcall(readfile, name)
				if ok and type(src) == "string" and #src > 5000 then
					pcall(qot, src)
					return true
				end
			end
		end
	end
	return false
end
local relaunchHinted = false
function queueRelaunchOrHint()
	if queueRelaunch() then return end
	if not relaunchHinted then
		relaunchHinted = true
		toast("info", "Auto relaunch", "This executor does not offer queue_on_teleport, so GenX cannot relaunch itself after a rejoin here", { duration = 9 })
	end
end

function Server.rejoin()
	queueRelaunchOrHint()
	toast("info", "Rejoin", "Reconnecting", { silent = true })
	local ok, err = pcall(function()
		if #Players:GetPlayers() <= 1 then
			TeleportService:Teleport(game.PlaceId, LP)
		else
			TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
		end
	end)
	if not ok then toast("err", "Rejoin failed", short(err, 60)) end
end
-- Server hop: reads Roblox's public server list and only joins a server with EXACTLY HOP_TARGET players (never lower, never higher).
-- It skips this server and any that failed to join, keeps scanning until one shows up, and tapping Server hop again while it searches cancels.
local HOP_TARGET = 27
local hopState = { token = 0, busy = false, bad = {} }
local function hopFetch(url)
	local body
	if pcall(function() body = game:HttpGet(url) end) and type(body) == "string" and #body > 0 then return body end
	local rq = (type(request) == "function" and request) or (type(http_request) == "function" and http_request) or nil
	if rq then
		local ok, res = pcall(rq, { Url = url, Method = "GET" })
		if ok and type(res) == "table" and type(res.Body) == "string" and #res.Body > 0 then return res.Body end
	end
	return nil
end
function Server.hop()
	if hopState.busy then
		hopState.busy = false
		hopState.token += 1
		toast("info", "Server hop", "Search cancelled", { silent = true })
		return
	end
	hopState.busy = true
	hopState.token += 1
	local my = hopState.token
	toast("info", "Server hop", "Searching for " .. HOP_TARGET .. "-player server. Tap to cancel", { silent = true })
	task.spawn(function()
		local function alive() return hopState.busy and hopState.token == my and not dead end
		local netFails, scans = 0, 0
		while alive() do
			scans += 1
			local cursor, pages, pick = nil, 0, nil
			repeat
				pages += 1
				local url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Desc&excludeFullGames=true&limit=100"
				if cursor then url = url .. "&cursor=" .. HttpService:UrlEncode(cursor) end
				local raw = hopFetch(url)
				local data
				if raw then
					local ok, d = pcall(function() return HttpService:JSONDecode(raw) end)
					if ok and type(d) == "table" and type(d.data) == "table" then data = d end
				end
				if not data then
					netFails += 1
					if netFails >= 4 then
						toast("err", "Server hop", "Server list unavailable (blocked or rate limited)")
						hopState.busy = false
						return
					end
					task.wait(2.5) -- rate limited or a bad reply: back off and try this page again
					break
				end
				netFails = 0
				local good = {}
				for _, sv in ipairs(data.data) do
					if sv.playing == HOP_TARGET and (sv.maxPlayers or 99) > HOP_TARGET and sv.id ~= game.JobId and not hopState.bad[sv.id] then
						good[#good + 1] = sv.id
					end
				end
				if #good > 0 then pick = good[math.random(#good)] break end
				cursor = data.nextPageCursor
				if cursor then task.wait(0.4) end
			until not cursor or pages >= 20 or not alive()
			if not alive() then break end
			if pick then
				local failed = false
				local conn = TeleportService.TeleportInitFailed:Connect(function(plr) if plr == LP then failed = true end end)
				toast("ok", "Server hop", HOP_TARGET .. "-player server found. Joining", { silent = true })
				queueRelaunchOrHint()
				if not pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, pick, LP) end) then failed = true end
				local t0 = os.clock()
				while alive() and not failed and os.clock() - t0 < 20 do task.wait(0.25) end
				conn:Disconnect()
				if failed and alive() then
					hopState.bad[pick] = true -- full by the time we got there, or Roblox refused it: never try it again
					toast("warn", "Server hop", "Server unavailable. Searching again", { silent = true })
				else
					break
				end
			else
				if scans == 1 or scans % 5 == 0 then
					toast("info", "Server hop", "No " .. HOP_TARGET .. "-player server yet. Searching", { silent = true })
				end
				local w = 0
				while alive() and w < 3 do task.wait(0.5) w += 0.5 end
			end
		end
		if hopState.token == my then hopState.busy = false end
	end)
end

-- ============================================================================
-- 22. HOME LAYOUT (two glass columns, centre stays empty and touch-through)
-- ============================================================================
local colL, colR = UI.columns(pages.Home)
UI.homeL, UI.homeR = colL, colR -- Part 3 mounts the toggle / extras / gravity widgets into colL

-- profile card
UI.mount(colL, "profile", 206, function(w)
	local av = UI.avatarImg(w, LP.UserId, 64, true)
	av.Position = UDim2.fromOffset(14, 14)
	label(w, LP.DisplayName, 17, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(90, 20), Size = UDim2.new(1, -104, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd })
	label(w, "@" .. LP.Name, 12, "muted", { Position = UDim2.fromOffset(90, 44), Size = UDim2.new(1, -104, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })

	local function stat(i, name)
		local x = (i - 1) / 3
		local v = label(w, "-", 17, "text", { Font = Enum.Font.GothamBold, Position = UDim2.new(x, 14, 0, 94), Size = UDim2.new(1 / 3, -14, 0, 22) })
		label(w, name, 10, "muted", { Font = Enum.Font.GothamBold, Position = UDim2.new(x, 14, 0, 117), Size = UDim2.new(1 / 3, -14, 0, 14) })
		return v
	end
	local sF, sA, sO = stat(1, "FRIENDS"), stat(2, "ACCOUNT"), stat(3, "ONLINE")
	sA.Text = LP.AccountAge .. "d"

	local div = mk("Frame", { Size = UDim2.new(1, -28, 0, 1), Position = UDim2.fromOffset(14, 148), BorderSizePixel = 0 }, w)
	themed(div, { BackgroundColor3 = "stroke" })
	div.BackgroundTransparency = 0.4
	label(w, "Joined Roblox in " .. os.date("%B %Y", os.time() - LP.AccountAge * 86400), 11, "muted", { Position = UDim2.fromOffset(14, 158), Size = UDim2.new(1, -28, 0, 16) })
	label(w, "Account " .. LP.AccountAge .. " days old", 11, "muted", { Position = UDim2.fromOffset(14, 178), Size = UDim2.new(1, -28, 0, 16) })

	-- friend counts come from Roblox's own client APIs; any failure just shows n/a
	task.spawn(function()
		local ok, pg = pcall(function() return Players:GetFriendsAsync(LP.UserId) end)
		if not ok then if sF.Parent then sF.Text = "n/a" end return end
		local n = 0
		for _ = 1, 8 do
			for _ in ipairs(pg:GetCurrentPage()) do n += 1 end
			if pg.IsFinished then break end
			if not pcall(function() pg:AdvanceToNextPageAsync() end) then break end
		end
		if sF.Parent then sF.Text = tostring(n) end
	end)
	task.spawn(function()
		local ok, list = pcall(function() return LP:GetFriendsOnline(200) end)
		if sO.Parent then sO.Text = ok and tostring(#list) or "n/a" end
	end)
end, { order = 10 })

-- quick commands: Copy Avatar + Role Spam + Anti Steal tiles
UI.mount(colR, "quick", 128, function(w)
	UI.header(w, "Quick Commands", "bolt")
	local function tile(i, text, icon, cb, dyn)
		local b = mk("TextButton", {
			Size = UDim2.new(1 / 3, -13.33, 0, 76), Position = UDim2.new((i - 1) / 3, 14 - (i - 1) * 7.33, 0, 42),
			Text = "", AutoButtonColor = false, BorderSizePixel = 0,
		}, w)
		if not dyn then themed(b, { BackgroundColor3 = "bg" }) b.BackgroundTransparency = 0.35 end
		round(b, 14)
		local st = mk("UIStroke", { Thickness = 1, Transparency = 0.5 }, b)
		themed(st, { Color = "stroke" })
		local ic = Icon.new(b, icon, 24, "accent")
		ic.frame.AnchorPoint = Vector2.new(0.5, 0)
		ic.frame.Position = UDim2.new(0.5, 0, 0, 12)
		local lb = label(b, text, 12, "text", { Font = Enum.Font.GothamBold, Position = UDim2.new(0, 0, 1, -26), Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Center })
		UI.press(b, 0.95)
		b.Activated:Connect(function() haptic(0.3) cb() end)
		return b, ic, lb
	end
	UI.tutRef.copyTile = tile(1, "Copy Avatar", "personPlus", function() UI.focusAvatar() end)

	local rsOn = false
	local rtile, ric, rlb
	local function paintRS()
		local th = T()
		rtile.BackgroundColor3 = rsOn and th.accent or th.bg
		rtile.BackgroundTransparency = rsOn and 0.08 or 0.35
		rlb.TextColor3 = rsOn and Color3.new(1, 1, 1) or th.text
		ric.color(rsOn and Color3.new(1, 1, 1) or th.accent)
	end
	local jobSpamOn = false
	rtile, ric, rlb = tile(2, "Job Spam", "role", function()
		jobSpamOn = not jobSpamOn
		if X and X.job_spammer then X.job_spammer(jobSpamOn) end
		if H.roleSpamPaint then H.roleSpamPaint(jobSpamOn) end
	end, true)
	UI.tutRef.roleTile = rtile
	function H.roleSpamPaint(on) rsOn = on paintRS() end
	onTheme(function() paintRS() end, rtile)
	paintRS()

	-- Anti Outfit Stealer: turning it on syncs right away, so people running the hub see it within a moment
	local asOn = cfg.antiSteal == true
	local atile, aic, alb
	local function paintAS()
		local th = T()
		atile.BackgroundColor3 = asOn and th.accent or th.bg
		atile.BackgroundTransparency = asOn and 0.08 or 0.35
		alb.TextColor3 = asOn and Color3.new(1, 1, 1) or th.text
		aic.color(asOn and Color3.new(1, 1, 1) or th.accent)
	end
	atile, aic, alb = tile(3, "Anti Steal", "shield", function()
		asOn = not asOn
		cfg.antiSteal = asOn
		cfgSave()
		paintAS()
		if X and X.anti_steal then pcall(X.anti_steal, asOn) end
		local TG = G.GENX_TAGS
		if TG and TG.setAnti then pcall(TG.setAnti, asOn) end
	end, true)
	onTheme(function() paintAS() end, atile)
	paintAS()
	if asOn and X and X.anti_steal then task.spawn(function() X.anti_steal(true) end) end
end, { order = 10 })

-- this server: players / ping / uptime + Rejoin / Server hop
UI.mount(colR, "server", 160, function(w)
	UI.header(w, "This server", "signal")
	local function stat(i, name)
		local x = (i - 1) / 3
		local v = label(w, "-", 17, "text", { Font = Enum.Font.GothamBold, Position = UDim2.new(x, 14, 0, 40), Size = UDim2.new(1 / 3, -14, 0, 22) })
		label(w, name, 10, "muted", { Font = Enum.Font.GothamBold, Position = UDim2.new(x, 14, 0, 63), Size = UDim2.new(1 / 3, -14, 0, 14) })
		return v
	end
	local sP, sPing, sUp = stat(1, "PLAYERS"), stat(2, "PING"), stat(3, "UPTIME")
	local row = mk("Frame", { Size = UDim2.new(1, -28, 0, 44), Position = UDim2.fromOffset(14, 98), BackgroundTransparency = 1 }, w)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, row)
	local b1 = button(row, "Rejoin", false, UDim2.new(0.5, -4, 1, 0), Server.rejoin)
	local b2 = button(row, "Server hop", true, UDim2.new(0.5, -4, 1, 0), Server.hop)
	local i1 = Icon.new(b1, "reset", 16, "text") i1.frame.AnchorPoint = Vector2.new(0, 0.5) i1.frame.Position = UDim2.new(0, 10, 0.5, 0)
	local i2 = Icon.new(b2, "swap", 16, Color3.new(1, 1, 1)) i2.frame.AnchorPoint = Vector2.new(0, 0.5) i2.frame.Position = UDim2.new(0, 10, 0.5, 0)
	pad(b1, 32, 0, 8, 0) pad(b2, 32, 0, 8, 0)
	tickFns[#tickFns + 1] = function()
		sP.Text = #Players:GetPlayers() .. "/" .. Players.MaxPlayers
		local ok, p = pcall(function() return LP:GetNetworkPing() * 1000 end)
		sPing.Text = ok and string.format("%dms", p) or "n/a"
		sUp.Text = fmtDuration(workspace.DistributedGameTime)
	end
end, { order = 20 })

-- game card: name, place id, copy join link / job id
UI.mount(colR, "game", 150, function(w)
	UI.header(w, "Game", "grid")
	local dBtn = mk("TextButton", { Size = UDim2.new(1, -28, 0, 40), Position = UDim2.fromOffset(14, 36), Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 5 }, w)
	dBtn.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
	round(dBtn, 12)
	mk("ImageLabel", { Size = UDim2.fromOffset(26, 26), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 11, 0.5, 0), BackgroundTransparency = 1, Image = "rbxassetid://10367063084", ScaleType = Enum.ScaleType.Fit, ZIndex = 6 }, dBtn)
	mk("TextLabel", { BackgroundTransparency = 1, Text = "Join Discord", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -52, 1, 0), Position = UDim2.fromOffset(46, 0), ZIndex = 6 }, dBtn)
	dBtn.Activated:Connect(function()
		if copyText("https://discord.gg/wk6zaFKZJs") then toast("ok", "Discord", "Invite link copied", { duration = 3 })
		else toast("err", "Discord", "Clipboard unsupported") end
	end)
	label(w, "Place " .. tostring(game.PlaceId), 11, "muted", { Position = UDim2.fromOffset(14, 80), Size = UDim2.new(1, -28, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
	local row = mk("Frame", { Size = UDim2.new(1, -28, 0, 44), Position = UDim2.fromOffset(14, 98), BackgroundTransparency = 1 }, w)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, row)
	local function copy(what, text)
		if copyText(text) then toast("ok", what, "Copied", { silent = true })
		else toast("err", what, "Clipboard unsupported") end
	end
	local b1 = button(row, "Copy link", false, UDim2.new(0.5, -4, 1, 0), function()
		copy("Join link", ("roblox://experiences/start?placeId=%d&gameInstanceId=%s"):format(game.PlaceId, game.JobId))
	end)
	local b2 = button(row, "Job ID", false, UDim2.new(0.5, -4, 1, 0), function() copy("Job ID", game.JobId) end)
	local i1 = Icon.new(b1, "link", 16, "text") i1.frame.AnchorPoint = Vector2.new(0, 0.5) i1.frame.Position = UDim2.new(0, 10, 0.5, 0)
	local i2 = Icon.new(b2, "copy", 16, "text") i2.frame.AnchorPoint = Vector2.new(0, 0.5) i2.frame.Position = UDim2.new(0, 10, 0.5, 0)
	pad(b1, 32, 0, 8, 0) pad(b2, 32, 0, 8, 0)
end, { order = 30 })

-- friend check for the join alert (cached: IsFriendsWith yields)
local friendCache = {}
local function isFriend(plr)
	local c = friendCache[plr.UserId]
	if c ~= nil then return c end
	local ok, r = pcall(function() return LP:IsFriendsWith(plr.UserId) end)
	c = ok and r == true
	friendCache[plr.UserId] = c
	return c
end

-- 23. AVATAR COPYING WIDGET
-- ============================================================================
local AW = { sel = nil, rows = {}, cardUi = {} }
UI.avatarCol, UI.avatarColR = UI.columns(pages.Avatar) -- left column: player list, right column: the player panel
avatarWidget, avatarWrap, avatarScale = UI.widget(UI.avatarCol, 420, "avatar", { order = 10 })
avatarWidget.Name = "Avatar Copying"
AW.pw = UI.widget(UI.avatarColR, 420, "avatarcard", { order = 10 })
AW.pw.Name = "Player"

label(avatarWidget, "Avatar Copying", 15, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -90, 0, 20) })
local countLbl = label(avatarWidget, "", 11, "muted", { Position = UDim2.new(1, -84, 0, 12), Size = UDim2.fromOffset(70, 16), TextXAlignment = Enum.TextXAlignment.Right })

local search = mk("TextBox", {
	Size = UDim2.new(1, -28, 0, 38), Position = UDim2.fromOffset(14, 38), Text = "", PlaceholderText = "Search players",
	Font = Enum.Font.Gotham, TextSize = 14, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0,
}, avatarWidget)
themed(search, { BackgroundColor3 = "bg", TextColor3 = "text", PlaceholderColor3 = "muted" })
round(search, 12)
pad(search, 12, 0, 12, 0)

local listFrame = mk("ScrollingFrame", {
	Position = UDim2.fromOffset(10, 84), Size = UDim2.new(1, -20, 1, -94), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, avatarWidget)
themed(listFrame, { ScrollBarImageColor3 = "accent" })
mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)
local emptyLbl = label(listFrame, "No other players here", 13, "muted", { Size = UDim2.new(1, 0, 0, 40), TextXAlignment = Enum.TextXAlignment.Center, Visible = false })

local function makeRow(plr)
	local b = mk("TextButton", { Size = UDim2.new(1, -4, 0, 52), AutoButtonColor = false, Text = "", BorderSizePixel = 0 }, listFrame)
	themed(b, { BackgroundColor3 = "bg" })
	round(b, 12)
	local img = mk("ImageLabel", { Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(8, 6), BackgroundTransparency = 1 }, b)
	themed(img, { BackgroundColor3 = "card" })
	img.BackgroundTransparency = 0
	round(img, 20)
	thumb(plr.UserId, "HeadShot", function(c) if img.Parent then img.Image = c end end)
	local nm = label(b, plr.DisplayName, 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(56, 8), Size = UDim2.new(1, -90, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd })
	label(b, "@" .. plr.Name, 12, "muted", { Position = UDim2.fromOffset(56, 27), Size = UDim2.new(1, -90, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
	local cic = Icon.new(b, "chevR", 16, "muted")
	cic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
	cic.frame.Position = UDim2.new(1, -22, 0, 25)
	b.Activated:Connect(function() haptic(0.2) UI.openPlayerCard(plr) end)
	return b
end

local listQueued = false
local function refreshList()
	if listQueued or dead then return end
	listQueued = true
	task.delay(0.15, function() -- debounce bursts of joins/leaves
		listQueued = false
		if dead then return end
		local q = search.Text:lower()
		local others = {}
		for _, p in ipairs(Players:GetPlayers()) do if p ~= LP then others[#others + 1] = p end end
		table.sort(others, function(a, b) return a.DisplayName:lower() < b.DisplayName:lower() end)
		for plr, row in pairs(AW.rows) do
			if plr.Parent ~= Players then row:Destroy() AW.rows[plr] = nil end
		end
		local shown = 0
		for i, p in ipairs(others) do
			local row = AW.rows[p]
			if not row then row = makeRow(p) AW.rows[p] = row end
			row.LayoutOrder = i
			local match = q == "" or p.DisplayName:lower():find(q, 1, true) or p.Name:lower():find(q, 1, true)
			row.Visible = match and true or false
			if match then shown += 1 end
		end
		emptyLbl.Visible = shown == 0
		emptyLbl.Text = #others == 0 and "No other players here" or "No matches"
		countLbl.Text = #others .. " online"
	end)
end
keep(search:GetPropertyChangedSignal("Text"):Connect(refreshList))

-- ---------------------------------------------------------------- player card
local card2 = mk("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 5 }, AW.pw)
themed(card2, { BackgroundColor3 = "card" })
local CU = AW.cardUi

-- empty state of the right widget: your own look + a hint, until a player is picked on the left
do
	local idle = mk("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 4 }, AW.pw)
	AW.idle = idle
	label(idle, "Player", 15, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 20) })
	local me = mk("ImageLabel", { Size = UDim2.fromOffset(110, 110), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 58), BorderSizePixel = 0 }, idle)
	themed(me, { BackgroundColor3 = "bg" })
	round(me, 20)
	thumb(LP.UserId, "AvatarBust", function(c) if me.Parent then me.Image = c end end)
	label(idle, "Pick a player", 16, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 184), Size = UDim2.new(1, -28, 0, 22), TextXAlignment = Enum.TextXAlignment.Center })
	label(idle, "Tap anyone in the list to copy their avatar, sync their animations, spectate, mute or follow them.", 12, "muted", { Position = UDim2.fromOffset(24, 210), Size = UDim2.new(1, -48, 0, 56), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top })
end
function AW.close()
	card2.Visible = false
	AW.sel = nil
	if AW.idle then AW.idle.Visible = true end
end

CU.back = mk("TextButton", { Size = UDim2.fromOffset(40, 36), Position = UDim2.fromOffset(8, 8), Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 6 }, card2)
themed(CU.back, { BackgroundColor3 = "bg" })
round(CU.back, 12)
do
	local bic = Icon.new(CU.back, "chevL", 20, "text", 7)
	bic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
	bic.frame.Position = UDim2.fromScale(0.5, 0.5)
end
label(card2, "Player", 14, "muted", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(56, 16), Size = UDim2.fromOffset(80, 20), ZIndex = 6 })

CU.img = mk("ImageLabel", { Size = UDim2.fromOffset(92, 92), Position = UDim2.fromOffset(14, 52), BorderSizePixel = 0, ZIndex = 6 }, card2)
themed(CU.img, { BackgroundColor3 = "bg" })
round(CU.img, 16)
CU.name = label(card2, "", 18, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(116, 52), Size = UDim2.new(1, -128, 0, 24), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6 })
CU.user = label(card2, "", 12, "muted", { Position = UDim2.fromOffset(116, 77), Size = UDim2.new(1, -128, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6 })
CU.friend = mk("TextLabel", { Size = UDim2.fromOffset(78, 18), Position = UDim2.fromOffset(116, 97), Text = "your friend", Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 6 }, card2)
themed(CU.friend, { BackgroundColor3 = "accent" })
round(CU.friend, 9)
CU.age = label(card2, "", 11, "muted", { Position = UDim2.fromOffset(116, 118), Size = UDim2.new(1, -128, 0, 14), ZIndex = 6 })
CU.dist = label(card2, "", 11, "accent", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(116, 133), Size = UDim2.new(1, -128, 0, 14), ZIndex = 6 })

local grid = mk("Frame", { Size = UDim2.new(1, -28, 0, 202), Position = UDim2.fromOffset(14, 160), BackgroundTransparency = 1, ZIndex = 6 }, card2)
mk("UIGridLayout", { CellSize = UDim2.new(0.5, -4, 0, 46), CellPadding = UDim2.fromOffset(8, 6), SortOrder = Enum.SortOrder.LayoutOrder }, grid)

local ACTIONS = { "copy", "sync", "spec", "hide", "bring", "kill", "annoy", "emote" }
local ACT_ICON = { copy = "personPlus", sync = "film", spec = "camera", hide = "eyeOff", bring = "target", kill = "cross", annoy = "bell", emote = "wave" }
local ACT_NAME = { copy = "Copy Avatar", sync = "Sync Anim", spec = "Spectate", hide = "Hide", bring = "Bring Player", kill = "Kill Player", annoy = "Annoy", emote = "Copy Emote" }
CU.btn = {}
for i, key in ipairs(ACTIONS) do
	local b = mk("TextButton", { Text = "", AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = i, ZIndex = 7 }, grid)
	round(b, 12)
	local st = mk("UIStroke", { Thickness = 1 }, b)
	themed(st, { Color = "stroke" })
	local t1 = mk("TextLabel", { Size = UDim2.new(1, -12, 0, 20), Position = UDim2.fromOffset(32, 5), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8, Text = ACT_NAME[key] }, b)
	local aic = Icon.new(b, ACT_ICON[key], 16, "text", 8)
	aic.frame.Position = UDim2.fromOffset(10, 7)
	local t2 = mk("TextLabel", { Size = UDim2.new(1, -12, 0, 14), Position = UDim2.fromOffset(10, 25), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 8, Text = "" }, b)
	CU.btn[key] = { b = b, t1 = t1, t2 = t2, ic = aic }
end

local function paintCard()
	local plr = AW.sel
	if not plr then return end
	local th = T()
	local s = Feat.state(plr)
	local applying = AV.applying() == plr
	local function paint(key, on, sub)
		local e = CU.btn[key]
		e.b.BackgroundColor3 = on and th.accent or th.bg
		e.t1.TextColor3 = on and Color3.new(1, 1, 1) or th.text
		e.ic.color(on and Color3.new(1, 1, 1) or th.text)
		e.t2.TextColor3 = on and Color3.new(1, 1, 1) or th.muted
		e.t2.Text = sub
	end
	paint("copy", applying, applying and "Applying..." or "Wear their look")
	paint("sync", AV.syncTarget() == plr, AV.syncTarget() == plr and "On" or "Off")
	paint("spec", s.spec, s.spec and "On" or "Off")
	paint("hide", s.hide, s.hide and "On" or "Off")
	paint("bring", false, "Bring to you")
	paint("kill", false, "Eliminate them")
	local annoyingThis = (X and X.annoy_state and select(2, X.annoy_state()) == plr) or false
	paint("annoy", annoyingThis, annoyingThis and "On" or "Off")
	paint("emote", false, "Copy their emote")
end
onTheme(function() paintCard() end)

Feat.changed = function(plr, key) if AW.sel == plr and card2.Visible then paintCard() end end
AV.onApply = function(plr, state) if AW.sel == plr then paintCard() end end
AV.onSync = function(plr, on) if AW.sel == plr then paintCard() end end

-- ================= WATCHDOG =================
-- Copy Avatar (and heavy moments in general) can make a phone drop a CanvasGroup's offscreen render: the card goes blank and only its outline stays.
-- The watchdog (1) restores the whole gui if something flips it off / moves it, every frame, (2) un-sticks any panel that stopped animating while
-- still transparent, (3) keeps forcing a redraw: every 0.2s during and right after a copy, every 1s otherwise. The redraw nudge is 1 frame and invisible.
UI.stuckAt = {}
function UI.heal(check)
	if dead or UI.state ~= "open" then return end
	local now = os.clock()
	local pagesHolder = UI.pagesHolder
	if pagesHolder and not pagesHolder.Visible then pagesHolder.Visible = true end
	local pg = pages[UI.curTab]
	if pg and not pg.Visible then pg.Visible = true end
	for _, rec in ipairs(UI.reg) do
		if rec.page == UI.curTab and not rec.hidden and rec.w and rec.w.Parent then
			local w = rec.w
			local bad = w.Parent ~= rec.wrap or rec.sc.Scale < 0.5 or not w.Visible
			if bad and now > (rec.busy or 0) + 0.15 then
				UI.settle(rec) w.Visible = true -- nothing is animating it any more: put it back right now
			elseif not check and not bad then
				local sz = w.Size
				w.Size = sz + UDim2.fromOffset(0, 1) -- 1-frame nudge forces a redraw, same as a finger touch
				task.delay(0.02, function() if w.Parent then w.Size = sz end end)
			end
		end
	end
	local chromeBad = false
	for _, e in ipairs(UI.chrome) do
		local g = e.inst
		if g and g.Parent and g:IsA("CanvasGroup") then
			if g.GroupTransparency > 0.98 then chromeBad = true
			elseif not check then
				local gt = g.GroupTransparency
				g.GroupTransparency = math.min(1, gt + 0.004)
				task.delay(0.02, function() if g.Parent then g.GroupTransparency = gt end end)
			end
		end
	end
	if chromeBad then
		UI.stuckAt.chrome = UI.stuckAt.chrome or now
		if now - UI.stuckAt.chrome > 1.2 then UI.stuckAt.chrome = nil UI.chromeShow(true, true) end
	else
		UI.stuckAt.chrome = nil
	end
	local nav = UI.nav
	if not check and nav and nav.Parent and nav.GroupTransparency < 0.5 then
		local gt = nav.GroupTransparency
		nav.GroupTransparency = gt + 0.004
		task.delay(0.02, function() if nav.Parent then nav.GroupTransparency = gt end end)
	end
	if not check then -- the outer rounded holders and the scrollers inside them: the layers a touch wakes up
		for _, col in ipairs(UI.cols or {}) do
			if col.page.Visible and col.holder.Parent then
				local c = col.c
				local cp = c.CanvasPosition
				c.CanvasPosition = cp + Vector2.new(0, 1)
				task.delay(0.02, function() if c.Parent then c.CanvasPosition = cp end end)
			end
		end
	end
end

-- repaint burst: a few quick passes right after something changes (tab switch etc.), so a glitch never has time to be seen
function UI.burst()
	task.spawn(function()
		for i = 1, 9 do
			if dead then return end
			UI.heal(false)
			task.wait(i < 4 and 0.03 or 0.12)
		end
	end)
end

do
	local prevOnApply = AV.onApply
	AV.onApply = function(plr, state)
		prevOnApply(plr, state)
		UI.lastApply = os.clock()
		for _, d in ipairs({ 0.05, 0.25, 1.2, 2.8 }) do task.delay(d, function() UI.heal(false) end) end
	end
end

do
	local gParent = gui.Parent
	local function guiGuard()
		if dead then return end
		if gui.Parent ~= gParent then pcall(function() gui.Parent = gParent end) end
		if not gui.Enabled then gui.Enabled = true end
		if gui.DisplayOrder ~= 2147483647 then gui.DisplayOrder = 2147483647 end
	end
	keep(gui:GetPropertyChangedSignal("Enabled"):Connect(guiGuard)) -- instant, same frame
	keep(gui:GetPropertyChangedSignal("DisplayOrder"):Connect(guiGuard))
	keep(gui:GetPropertyChangedSignal("Parent"):Connect(function() task.defer(guiGuard) end))
	local function invariants()
		local floatBtn, winHolder, pagesHolder = UI.floatBtn, UI.winHolder, UI.pagesHolder
		if not (floatBtn and winHolder and pagesHolder) then return end
		if floatBtn.Parent ~= gui then floatBtn.Parent = gui end
		if not floatBtn.Visible then floatBtn.Visible = true end
		if UI.state ~= "closed" and not winHolder.Visible then winHolder.Visible = true end
		if UI.state == "open" then
			if not pagesHolder.Visible then pagesHolder.Visible = true end
			local pg = pages[UI.curTab]
			if pg and not pg.Visible then pg.Visible = true end
		end
	end
	local a1, a2 = 0, 0
	keep(RunService.Heartbeat:Connect(function(dt)
		if dead then return end
		invariants() -- every frame
		a1 += dt a2 += dt
		if a1 >= 0.1 then a1 = 0 UI.heal(true) end -- stuck check, 10x per second
		local every = (AV.applying() or os.clock() - (UI.lastApply or -99) < 8) and 0.2 or 1
		if a2 >= every then a2 = 0 UI.heal(false) end -- forced redraw
	end))
end

-- mute picker
local picker = mk("Frame", { Size = UDim2.new(1, -28, 0, 96), Position = UDim2.fromOffset(14, 164), BorderSizePixel = 0, Visible = false, ZIndex = 20 }, card2)
themed(picker, { BackgroundColor3 = "bg" })
round(picker, 14)
do
	local s = mk("UIStroke", { Thickness = 1 }, picker)
	themed(s, { Color = "accent" })
end
label(picker, "Mute which?", 12, "muted", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 16), ZIndex = 21 })
local pickRow = mk("Frame", { Size = UDim2.new(1, -16, 0, 44), Position = UDim2.fromOffset(8, 40), BackgroundTransparency = 1, ZIndex = 21 }, picker)
mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, pickRow)
for _, mode in ipairs({ "Voice", "Chat", "Both", "Off" }) do
	local b = button(pickRow, mode, mode ~= "Off", UDim2.new(0.25, -5, 1, 0), function()
		picker.Visible = false
		if AW.sel then Feat.setMute(AW.sel, mode) end
	end)
	b.ZIndex = 22
	b.TextSize = 13
end

local function bindAction(key, fn)
	CU.btn[key].b.Activated:Connect(function()
		local plr = AW.sel
		if not plr or plr.Parent ~= Players then return end
		haptic(0.25)
		fn(plr)
	end)
end
bindAction("copy", function(plr)
	CAP.CL.add("info", string.format("CLICK Copy Avatar button on %s (@%s)%s", plr.DisplayName, plr.Name, AV.applying() == plr and " (already copying this player, ignored)" or ""), "CLICK")
	if AV.applying() == plr then return end
	task.spawn(AV.apply, plr)
	paintCard()
end)
bindAction("sync", function(plr)
	local on = AV.syncTarget() ~= plr
	AV.setSync(plr, on)
	if on then toast("info", "Sync Anim", "Mirroring " .. plr.DisplayName, { userId = plr.UserId, silent = true }) end
	paintCard()
end)
bindAction("spec", function(plr) Feat.setSpectate(plr, not Feat.state(plr).spec) end)
bindAction("hide", function(plr) Feat.setHide(plr, not Feat.state(plr).hide) end)
bindAction("bring", function(plr) task.spawn(function() if X and X.bring_player then X.bring_player(plr) end end) end)
bindAction("kill", function(plr) task.spawn(function() if X and X.kill_player then X.kill_player(plr) end end) end)
bindAction("annoy", function(plr)
	if not (X and X.annoy_player) then return end
	if select(2, X.annoy_state()) == plr then
		X.annoy_player(nil, false)
		pcall(toast, "info", "Annoy", "Off", { duration = 2 })
	else
		X.annoy_player(plr, true)
	end
	paintCard()
end)
bindAction("emote", function(plr)
	if X and X.copy_emote_plr then X.copy_emote_plr(plr) end
	pcall(toast, "ok", "Copy Emote", "Playing their emote", { duration = 2 })
end)

function UI.openPlayerCard(plr)
	if not plr or plr.Parent ~= Players then return end
	AW.sel = plr
	picker.Visible = false
	CU.name.Text = plr.DisplayName
	CU.user.Text = "@" .. plr.Name
	CU.friend.Visible = false
	CU.img.Image = ""
	thumb(plr.UserId, "AvatarBust", function(c) if AW.sel == plr then CU.img.Image = c end end)
	local days = plr.AccountAge
	CU.age.Text = string.format("Account age: %dy %dd", math.floor(days / 365), days % 365)
	task.spawn(function()
		local ok, fr = pcall(function() return LP:IsFriendsWith(plr.UserId) end)
		if ok and fr and AW.sel == plr then CU.friend.Visible = true end
	end)
	paintCard()
	if AW.idle then AW.idle.Visible = false end
	card2.Visible = true
	card2.Position = UDim2.fromOffset(0, 18)
	tw(card2, 0.28, { Position = UDim2.new() }, Enum.EasingStyle.Quint)
end
CU.back.Activated:Connect(function() AW.close() end)

tickFns[#tickFns + 1] = function()
	if card2.Visible and AW.sel then
		local d = studsTo(AW.sel)
		CU.dist.Text = d and string.format("%d studs away", d) or "Not in range"
	end
end

-- Quick Commands tile: bring the widget into view and pulse it once
function UI.focusAvatar()
	if card2.Visible then AW.close() end
	UI.showTab("Avatar")
	task.delay(0.05, function()
		local col = UI.avatarCol
		if col and col.Parent then
			local y = math.max(0, avatarWrap.AbsolutePosition.Y - col.AbsolutePosition.Y + col.CanvasPosition.Y - 4)
			TweenService:Create(col, TweenInfo.new(0.35, Enum.EasingStyle.Quint), { CanvasPosition = Vector2.new(0, y) }):Play()
		end
		tw(avatarScale, 0.18, { Scale = 1.04 }, Enum.EasingStyle.Quad)
		task.delay(0.2, function() tw(avatarScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back) end)
	end)
end

-- ---------------------------------------------------------------- join / leave
keep(Players.PlayerAdded:Connect(function(plr)
	refreshList()
	if cfg.joinAlerts then task.spawn(function() if isFriend(plr) then toast("join", plr.DisplayName, "Friend joined", { userId = plr.UserId }) end end) end
end))
keep(Players.PlayerRemoving:Connect(function(plr)
	if AW.sel == plr then AW.close() end
	Feat.dropPlayer(plr)
	refreshList()
	if cfg.leaveAlerts and friendCache[plr.UserId] then toast("leave", plr.DisplayName, "Friend left", { userId = plr.UserId }) end
end))
refreshList()


end

-- ============================================================================
-- PART 3 / 3  |  replaces: 24, 25, 25b, 26, 27   (paste right after Part 2, to the end of the file)
-- 25 now holds only the command MECHANICS (code stays, no command bar / list / chat hook / prefix UI),
-- the top-bar steppers, and the Home toggle / extras / gravity widgets.
-- ============================================================================

local Cmd, TG, Fly, flyUI, setToggle, findPlayer, doGoto, doRefresh, readSpeed, readJump, readFov
do

-- ============================================================================
-- 24. COMMAND MECHANICS
-- ============================================================================
Cmd = { speedTouched = false, jumpTouched = false, fovTouched = false, fov = 70 }
local GRAV_DEFAULT = 196.2
local origGravity = workspace.Gravity
TG = {} -- toggles: name -> { on, start, stop, ui = {switch objs}, icon, title, desc }


Fly = { up = false, down = false, padUp = false, padDown = false } -- pad* = the on-screen Float buttons
local TGC = {} -- connections / instances owned by each toggle

local function dropOwned(name)
	local o = TGC[name]
	if not o then return end
	for _, v in pairs(o) do
		if typeof(v) == "RBXScriptConnection" then v:Disconnect()
		elseif typeof(v) == "Instance" then pcall(function() v:Destroy() end) end
	end
	TGC[name] = nil
end

-- ---------------------------------------------------------------- steady air pose (no falling animation while fly / float)
local airSaved, airHum
local function airPose(on)
	local h = myHum()
	if not h then return end
	if on then
		if airHum ~= h then
			airSaved, airHum = {}, h
			for _, st in ipairs({ Enum.HumanoidStateType.Freefall, Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Jumping, Enum.HumanoidStateType.Ragdoll }) do
				airSaved[st] = h:GetStateEnabled(st)
				pcall(function() h:SetStateEnabled(st, false) end)
			end
		end
		pcall(function() h:ChangeState(Enum.HumanoidStateType.Running) end)
	elseif airSaved and airHum then
		for st, v in pairs(airSaved) do pcall(function() airHum:SetStateEnabled(st, v) end) end
		airSaved, airHum = nil, nil
	end
end
local function airKeep(h)
	local st = h:GetState()
	if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.FallingDown then
		h:ChangeState(Enum.HumanoidStateType.Running)
	end
end

-- ---------------------------------------------------------------- fly
local function flyStart()
	local root, hum = myRoot(), myHum()
	if not root or not hum then error("no character yet") end
	dropOwned("fly")
	local o = {}
	TGC.fly = o
	o.bv = mk("BodyVelocity", { MaxForce = Vector3.new(1e9, 1e9, 1e9), Velocity = Vector3.zero }, root)
	o.bg = mk("BodyGyro", { MaxTorque = Vector3.new(1e9, 1e9, 1e9), P = 9e4, D = 1e3, CFrame = root.CFrame }, root)
	airPose(true)
	-- fly has no up / down controls: tilt the camera and push the stick, Float owns the vertical buttons
	o.conn = RunService.RenderStepped:Connect(function()
		local r, h = myRoot(), myHum()
		if not r or not h or not o.bv.Parent then return end
		airKeep(h)
		if h.Jump then h.Jump = false end
		local c = workspace.CurrentCamera
		local md = h.MoveDirection
		local look, right = c.CFrame.LookVector, c.CFrame.RightVector
		local fl, fr = Vector3.new(look.X, 0, look.Z), Vector3.new(right.X, 0, right.Z)
		local f = fl.Magnitude > 0.01 and md:Dot(fl.Unit) or 0
		local s = fr.Magnitude > 0.01 and md:Dot(fr.Unit) or 0
		local v = look * f + right * s
		if v.Magnitude > 1 then v = v.Unit end
		local spd = math.clamp((Cmd.speed or h.WalkSpeed) * 3, 30, 220)
		o.bv.Velocity = v * spd
		if fl.Magnitude > 0.01 then o.bg.CFrame = CFrame.new(r.Position, r.Position + fl) end
	end)
end
local function flyStop()
	dropOwned("fly")
	if not (TG.float and TG.float.on) then airPose(false) end
	Fly.up, Fly.down = false, false
end

-- ---------------------------------------------------------------- noclip
local noclipTouched = {}
local function noclipStart()
	dropOwned("noclip")
	TGC.noclip = {}
	TGC.noclip.conn = RunService.Stepped:Connect(function()
		local c = LP.Character
		if not c then return end
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then
				noclipTouched[p] = true
				p.CanCollide = false
			end
		end
	end)
end
local function noclipStop()
	dropOwned("noclip")
	for p in pairs(noclipTouched) do
		if p.Parent then p.CanCollide = true end
	end
	noclipTouched = {}
end

-- ---------------------------------------------------------------- float
local FLOAT_SPEED = 18 -- studs / second up or down (never slower than your walk speed)
local function floatStart()
	local root, hum = myRoot(), myHum()
	if not root or not hum then error("no character yet") end
	dropOwned("float")
	local o = {}
	TGC.float = o
	-- holds altitude AND drives the walk, so you float, walk and climb at the same time. It re-creates itself if the game ever deletes it.
	local function makeMover(r)
		return mk("BodyVelocity", { Name = "GenXFloat", MaxForce = Vector3.new(1e9, 1e9, 1e9), P = 1e4, Velocity = Vector3.zero }, r)
	end
	o.bv = makeMover(root)
	airPose(true)
	if flyUI then flyUI.Visible = true end
	local vy, downUntil, y0 = 0, 0, root.Position.Y
	-- swipe down on the screen to sink
	o.swipe = UIS.InputChanged:Connect(function(i, gp)
		if gp then return end
		if i.UserInputType == Enum.UserInputType.Touch and i.Delta.Y > 1.5 then downUntil = os.clock() + 0.2 end
	end)
	o.conn = RunService.Heartbeat:Connect(function(dt)
		local r, h = myRoot(), myHum()
		if not r or not h then return end
		if not o.bv or o.bv.Parent ~= r then -- deleted or the root part changed: put it back
			o.rebuilt = (o.rebuilt or 0) + 1
			if o.rebuilt <= 5 then log("warn", "float: mover was removed by the game, recreated (" .. o.rebuilt .. ")") end
			if o.bv then pcall(function() o.bv:Destroy() end) end
			o.bv = makeMover(r)
		end
		airKeep(h)
		-- jump button / space / on-screen button = rise, swipe / shift / on-screen button = sink
		local up = h.Jump or Fly.padUp or UIS:IsKeyDown(Enum.KeyCode.Space)
		if h.Jump then h.Jump = false end
		local down = os.clock() < downUntil or Fly.padDown or UIS:IsKeyDown(Enum.KeyCode.LeftShift)
		local sp = math.max(FLOAT_SPEED, h.WalkSpeed)
		local target = ((up and 1 or 0) - (down and 1 or 0)) * sp
		vy += (target - vy) * math.min(1, dt * 8) -- eased so it never jerks
		if math.abs(vy) < 0.05 then vy = 0 end
		-- while no button is held, lock the current height so nothing can pull you down
		if target ~= 0 or math.abs(vy) > 0.5 then y0 = r.Position.Y end
		local md = h.MoveDirection
		local ws = h.WalkSpeed
		local hold = (target == 0 and math.abs(vy) < 0.5) and (y0 - r.Position.Y) * 12 or 0
		local vel = Vector3.new(md.X * ws, vy + math.clamp(hold, -30, 30), md.Z * ws)
		o.bv.Velocity = vel
		r.AssemblyLinearVelocity = vel
	end)
end
local function floatStop()
	dropOwned("float")
	Fly.padUp, Fly.padDown = false, false
	if flyUI then flyUI.Visible = false end
	if not (TG.fly and TG.fly.on) then airPose(false) end
end

-- ---------------------------------------------------------------- infinite jump
local function infjumpStart()
	dropOwned("infjump")
	TGC.infjump = {}
	TGC.infjump.conn = UIS.JumpRequest:Connect(function()
		local h = myHum()
		if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
	end)
end
local function infjumpStop() dropOwned("infjump") end

-- ---------------------------------------------------------------- fullbright
local savedLight
local function fullbrightStart()
	if not savedLight then
		savedLight = {
			Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
			GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient,
		}
	end
	Lighting.Brightness = 2
	Lighting.ClockTime = 14
	Lighting.FogEnd = 1e5
	Lighting.GlobalShadows = false
	Lighting.Ambient = Color3.fromRGB(178, 178, 178)
end
local function fullbrightStop()
	if savedLight then
		for k, v in pairs(savedLight) do pcall(function() Lighting[k] = v end) end
		savedLight = nil
	end
end

-- ---------------------------------------------------------------- click teleport
local function clicktpStart()
	dropOwned("clicktp")
	TGC.clicktp = {}
	local mouse = LP:GetMouse()
	TGC.clicktp.conn = UIS.InputBegan:Connect(function(i, processed)
		if processed then return end
		if i.UserInputType ~= Enum.UserInputType.Touch and i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local root = myRoot()
		if not root then return end
		local ray = mouse.UnitRay
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { LP.Character }
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
		if hit then root.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3.2, 0)) end
	end)
end
local function clicktpStop() dropOwned("clicktp") end

-- toggle registry (the switch objects get attached by the UI)
TG.fly = { icon = "fly", title = "Fly", desc = "Glide where the camera points", start = flyStart, stop = flyStop }
TG.noclip = { icon = "noclip", title = "Noclip", desc = "Walk straight through walls", start = noclipStart, stop = noclipStop }
TG.esp = { icon = "eye", title = "ESP", desc = "Outline every other player", start = function() Feat.setESPAll(true) end, stop = function() Feat.setESPAll(false) end }
TG.float = { icon = "float", title = "Float", desc = "Hover in place, up / down buttons", start = floatStart, stop = floatStop }
TG.infjump = { icon = "jump", title = "Infinite Jump", desc = "Jump again in midair", start = infjumpStart, stop = infjumpStop }
TG.fullbright = { icon = "sun", title = "Fullbright", desc = "Light up the whole map", start = fullbrightStart, stop = fullbrightStop }
local function antisitStart()
	dropOwned("antisit")
	local o = {}
	TGC.antisit = o
	local h0 = myHum()
	if h0 then pcall(function() h0:SetStateEnabled(Enum.HumanoidStateType.Seated, false) end) h0.Sit = false end
	o.conn = RunService.Stepped:Connect(function()
		local h = myHum()
		if h and h.Sit then h.Sit = false end
	end)
end
local function antisitStop()
	dropOwned("antisit")
	local h = myHum()
	if h then pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.Seated, true) end) end
end
TG.antisit = { icon = "person", title = "Anti-sit", desc = "Seats can't sit you down", start = antisitStart, stop = antisitStop }
TG.clicktp = { icon = "target", title = "Click TP", desc = "Tap the world to teleport", start = clicktpStart, stop = clicktpStop }
-- rainbow car: cycles blue / red / yellow / purple on your car (spawn it first). One call in flight, backs off when ping rises.
do
	local RB = { run = 0, colors = { Color3.fromRGB(0, 70, 255), Color3.fromRGB(255, 0, 0), Color3.fromRGB(255, 220, 0), Color3.fromRGB(150, 30, 230) } }
	TG.rainbowcar = {
		icon = "rainbow", title = "Rainbow Car", desc = "Cycle colors on your car",
		start = function()
			local rem = RS
			for _, n in ipairs({ "Packages", "Flux", "Services", "VehicleService", "RF", "SetVehicleColor" }) do rem = rem and rem:FindFirstChild(n) end
			if not rem then rem = false end -- Life Together has no Flux VehicleService; GX_rainbowFire routes via Net
			RB.run += 1
			local my = RB.run
			-- two workers share one colour counter so the cycle runs about twice as fast. A colour whose call fails is
			-- retried (never skipped). If the server dislikes two calls at once, the second worker stops itself.
			local sh = { idx = 0, fails = 0, delay = 0, base = nil, ema = nil, single = false }
			local function worker(second)
				local col
				while not dead and RB.run == my do
					if second and sh.single then return end
					if not col then
						sh.idx = sh.idx % #RB.colors + 1
						col = RB.colors[sh.idx]
					end
					local t = os.clock()
					local ok, res = pcall(function() return GX_rainbowFire(rem, col) end)
					local rtt = (os.clock() - t) * 1000
					if ok and res == true then
						col = nil
						sh.fails = 0
						sh.ema = sh.ema and (sh.ema * 0.8 + rtt * 0.2) or rtt
						sh.base = math.min(sh.base or sh.ema, sh.ema)
						if sh.ema > sh.base * 2.2 then sh.delay = math.min(sh.delay * 1.25 + 0.01, 0.4)
						else sh.delay = math.max(sh.delay * 0.85 - 0.002, 0) end
					else
						sh.fails += 1
						if not sh.single and sh.fails >= 3 then
							sh.single, sh.fails = true, 0 -- back to one call at a time
						elseif sh.fails >= 8 then
							if RB.run == my then
								RB.run += 1
								task.defer(function()
									setToggle("rainbowcar", false)
									toast("warn", "Rainbow Car", "Spawn a vehicle first")
								end)
							end
							return
						end
						task.wait(0.15)
					end
					if sh.delay > 0 then task.wait(sh.delay) else task.wait() end
				end
			end
			task.spawn(worker, false)
			task.spawn(worker, true)
		end,
		stop = function() RB.run += 1 end,
	}
end
for _, t in pairs(TG) do t.on, t.ui = false, {} end

function setToggle(name, v)
	local t = TG[name]
	if not t then return false end
	v = v and true or false
	if t.on == v then return true end
	local ok, err = pcall(v and t.start or t.stop)
	if not ok then
		log("fail", name .. ": " .. tostring(err))
		toast("err", t.title, short(err, 60))
		v = false
		pcall(t.stop)
	end
	t.on = v
	for _, sw in ipairs(t.ui) do sw.set(v, true) end
	return ok
end

-- ---------------------------------------------------------------- speed / jump / fov / gravity
local function jumpIsPower(h) return h.UseJumpPower end
function readSpeed() local h = myHum() return h and h.WalkSpeed or 16 end
function readJump()
	local h = myHum()
	if not h then return 50 end
	return jumpIsPower(h) and h.JumpPower or h.JumpHeight
end
function readFov() local c = workspace.CurrentCamera return c and c.FieldOfView or 70 end

local orig = { speed = nil, jump = nil, fov = nil, jumpPower = true }
local function captureOriginals()
	local h = myHum()
	if h and not orig.speed then
		orig.speed, orig.jump, orig.jumpPower = h.WalkSpeed, readJump(), jumpIsPower(h)
	end
	if not orig.fov then orig.fov = readFov() end
end
captureOriginals()

local function applySpeed(v)
	local h = myHum()
	if h then h.WalkSpeed = v end
end
local function applyJump(v)
	local h = myHum()
	if not h then return end
	if jumpIsPower(h) then h.JumpPower = v else h.JumpHeight = v end
end
local function applyFov(v)
	local c = workspace.CurrentCamera
	if c then c.FieldOfView = v end
end

function Cmd.setSpeed(v) v = math.clamp(v, 0, 500) Cmd.speed, Cmd.speedTouched = v, true captureOriginals() applySpeed(v) end
function Cmd.setJump(v) v = math.clamp(v, 0, 500) Cmd.jump, Cmd.jumpTouched = v, true captureOriginals() applyJump(v) end
function Cmd.setFov(v) v = math.clamp(v, 30, 120) Cmd.fov, Cmd.fovTouched = v, true applyFov(v) end
function Cmd.setGravity(v) v = math.clamp(v, 0, 1000) workspace.Gravity = v end
function Cmd.resetGravity() workspace.Gravity = GRAV_DEFAULT end
function Cmd.resetSpeed() if orig.speed then Cmd.speed, Cmd.speedTouched = nil, false applySpeed(orig.speed) end end
function Cmd.resetJump() if orig.jump then Cmd.jump, Cmd.jumpTouched = nil, false applyJump(orig.jump) end end
function Cmd.resetFov() if orig.fov then Cmd.fovTouched = false applyFov(orig.fov) end end

-- the game (or camera scripts) resets FOV on its own; hold ours once the user has set it
local fovGuard
local function hookFov()
	if fovGuard then fovGuard:Disconnect() end
	local c = workspace.CurrentCamera
	if c then
		fovGuard = c:GetPropertyChangedSignal("FieldOfView"):Connect(function()
			if Cmd.fovTouched and math.abs(c.FieldOfView - Cmd.fov) > 0.01 then c.FieldOfView = Cmd.fov end
		end)
	end
end
hookFov()
keep(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() hookFov() if Cmd.fovTouched then applyFov(Cmd.fov) end end))
onClean(function() if fovGuard then fovGuard:Disconnect() end end)

-- respawn: values and active toggles come back
keep(LP.CharacterAdded:Connect(function(char)
	local h = char:WaitForChild("Humanoid", 10)
	if not h or dead then return end
	task.wait(0.4)
	if Cmd.speedTouched and Cmd.speed then applySpeed(Cmd.speed) end
	if Cmd.jumpTouched and Cmd.jump then applyJump(Cmd.jump) end
	if Cmd.fovTouched then applyFov(Cmd.fov) end
	if TG.fly.on then pcall(flyStart) end
	if TG.float.on then pcall(floatStart) end
	if TG.antisit.on then pcall(antisitStart) end
end))

-- ---------------------------------------------------------------- actions
function findPlayer(q)
	q = tostring(q or ""):lower()
	if q == "" then return nil end
	local best, bestScore = nil, 0
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local n, d = p.Name:lower(), p.DisplayName:lower()
			local score = 0
			if n == q or d == q then score = 4
			elseif n:sub(1, #q) == q or d:sub(1, #q) == q then score = 3
			elseif n:find(q, 1, true) or d:find(q, 1, true) then score = 2 end
			if score > bestScore then best, bestScore = p, score end
		end
	end
	return best
end

function doGoto(plr)
	local mine, theirs = myRoot(), plr and rootOf(plr)
	if not mine or not theirs then
		toast("err", "Goto", plr and "Target not loaded" or "Target not found")
		return false
	end
	mine.CFrame = theirs.CFrame * CFrame.new(0, 0, 3)
	toast("ok", "Teleported", "At " .. plr.DisplayName, { userId = plr.UserId, silent = true })
	return true
end

function doRefresh()
	local root, hum = myRoot(), myHum()
	if not root or not hum then toast("err", "Refresh", "Character not loaded") return false end
	local cf = root.CFrame
	local conn
	conn = LP.CharacterAdded:Connect(function(ch)
		conn:Disconnect()
		local r = ch:WaitForChild("HumanoidRootPart", 10)
		if r then task.wait(0.2) r.CFrame = cf end
	end)
	task.delay(15, function() if conn then conn:Disconnect() end end)
	hum.Health = 0
	return true
end

function Cmd.stopAll()
	for name, t in pairs(TG) do
		if t.on then pcall(t.stop) t.on = false end
	end
	for name in pairs(TGC) do dropOwned(name) end
	noclipStop()
	fullbrightStop()
	if flyUI then flyUI.Visible = false end
	workspace.Gravity = origGravity > 0 and origGravity or GRAV_DEFAULT
	if orig.speed and Cmd.speedTouched then applySpeed(orig.speed) end
	if orig.jump and Cmd.jumpTouched then applyJump(orig.jump) end
	if orig.fov and Cmd.fovTouched then Cmd.fovTouched = false applyFov(orig.fov) end
end
onClean(Cmd.stopAll)

end

local rebuildRecent
do

-- float up / down buttons live on the root gui so they work with the window closed (same card look as the rest of the GUI)
flyUI = mk("Frame", { Size = UDim2.fromOffset(60, 128), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.62, 0), BackgroundTransparency = 1, Visible = false, ZIndex = 80 }, gui)
for i, d in ipairs({ { "fly", "padUp" }, { "arrowD", "padDown" } }) do
	local base = UDim2.fromOffset(58, 58)
	local b = mk("TextButton", { Size = base, Position = UDim2.fromOffset(1, (i - 1) * 70), Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 81 }, flyUI)
	themed(b, { BackgroundColor3 = "card" })
	b.BackgroundTransparency = 0.12
	round(b, 18)
	local s = mk("UIStroke", { Thickness = 1.5 }, b)
	themed(s, { Color = "accent" })
	mk("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.25) }) }, b)
	local fic = Icon.new(b, d[1], 26, "text", 82)
	fic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
	fic.frame.Position = UDim2.fromScale(0.5, 0.5)
	local function isPress(inp) return inp.UserInputType == Enum.UserInputType.Touch or inp.UserInputType == Enum.UserInputType.MouseButton1 end
	b.InputBegan:Connect(function(inp)
		if not isPress(inp) then return end
		Fly[d[2]] = true
		haptic(0.2)
		tw(b, 0.08, { Size = UDim2.fromOffset(52, 52), BackgroundColor3 = T().accent })
	end)
	b.InputEnded:Connect(function(inp)
		if not isPress(inp) then return end
		Fly[d[2]] = false
		tw(b, 0.15, { Size = base, BackgroundColor3 = T().card }, Enum.EasingStyle.Back)
	end)
end

-- ---------------------------------------------------------------- top-bar steppers

local function holdRepeat(btn, fn)
	local token = 0
	local function isPress(i) return i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 end
	btn.InputBegan:Connect(function(i)
		if not isPress(i) then return end
		token += 1
		local my = token
		fn()
		task.delay(0.4, function()
			while my == token and not dead do fn() task.wait(0.07) end
		end)
	end)
	btn.InputEnded:Connect(function(i) if isPress(i) then token += 1 end end)
end

local stepperRefresh = {}
local function makeStepper(caption, getVal, setVal, step, fmt)
	local f = card(steppers, UDim2.fromOffset(118, 44))
	f.ZIndex = 6
	local function sbtn(txt, x)
		local b = mk("TextButton", { Size = UDim2.fromOffset(34, 40), Position = UDim2.fromOffset(x, 2), Text = "", AutoButtonColor = false, BackgroundTransparency = 1, ZIndex = 7 }, f)
		local sic = Icon.new(b, txt == "+" and "plus" or "minus", 18, "text", 8)
		sic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
		sic.frame.Position = UDim2.fromScale(0.5, 0.5)
		return b
	end
	local minus, plus = sbtn("−", 2), sbtn("+", 82)
	label(f, caption, 9, "muted", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(36, 5), Size = UDim2.fromOffset(46, 12), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 7 })
	local val = label(f, "-", 16, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(36, 17), Size = UDim2.fromOffset(46, 24), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 7 })
	local function refresh() val.Text = string.format(fmt, getVal()) end
	holdRepeat(minus, function() setVal(getVal() - step) refresh() end)
	holdRepeat(plus, function() setVal(getVal() + step) refresh() end)
	refresh()
	stepperRefresh[#stepperRefresh + 1] = refresh
	return refresh
end

makeStepper("SPEED", function() return Cmd.speedTouched and Cmd.speed or readSpeed() end, function(v) Cmd.setSpeed(v) end, 2, "%d")
makeStepper("JUMP", function() return Cmd.jumpTouched and Cmd.jump or readJump() end, function(v) Cmd.setJump(v) end, 1, "%.0f")
makeStepper("FOV", function() return Cmd.fovTouched and Cmd.fov or readFov() end, function(v) Cmd.setFov(v) end, 5, "%d")
tickFns[#tickFns + 1] = function()
	if UI.state == "open" then for _, r in ipairs(stepperRefresh) do r() end end
end

-- ---------------------------------------------------------------- command table
local CMDS = {}
local CMD_BY = {}
local function defCmd(d) CMDS[#CMDS + 1] = d CMD_BY[d.name] = d end

local function numArg(rest) return tonumber((tostring(rest):match("^%s*(-?[%d%.]+)"))) end
local function numCmd(name, desc, current, setter, refresh)
	defCmd({ name = name, arg = "number", desc = desc, run = function(rest)
		local n = numArg(rest)
		if not n then toast("info", name, "Current: " .. tostring(math.floor(current() * 10 + 0.5) / 10), { silent = true }) return true end
		setter(n)
		for _, r in ipairs(stepperRefresh) do r() end
		if refresh then refresh() end
		toast("ok", name, "Set to " .. tostring(n), { silent = true })
		return true
	end })
end

defCmd({ name = "fly", toggle = "fly", desc = "Glide where the camera points" })
defCmd({ name = "noclip", toggle = "noclip", desc = "Pass through walls and objects" })
defCmd({ name = "esp", toggle = "esp", desc = "Outline every other player" })
defCmd({ name = "float", toggle = "float", desc = "Hover in place" })
defCmd({ name = "infjump", toggle = "infjump", desc = "Jump again while in midair" })
defCmd({ name = "goto", arg = "player", desc = "Teleport to a player", run = function(rest)
	local p = findPlayer(rest)
	if not p then toast("err", "goto", "No target matches \"" .. tostring(rest) .. "\"") return false end
	return doGoto(p)
end })
defCmd({ name = "refresh", desc = "Respawn and return to this spot", run = function() return doRefresh() end })
defCmd({ name = "fullbright", toggle = "fullbright", desc = "Remove darkness and fog" })
defCmd({ name = "clicktp", toggle = "clicktp", desc = "Tap the world to teleport there" })
defCmd({ name = "rainbowcar", toggle = "rainbowcar", desc = "Cycle colors on your car" })

local gravRefresh
numCmd("gravity", "Set gravity (default 196.2)", function() return workspace.Gravity end, Cmd.setGravity, function() if gravRefresh then gravRefresh() end end)
numCmd("speed", "Set walk speed", readSpeed, Cmd.setSpeed)
numCmd("jump", "Set jump power / height", readJump, Cmd.setJump)
numCmd("fov", "Set field of view (30-120)", readFov, Cmd.setFov)
defCmd({ name = "copyavatar", arg = "player", desc = "Open Avatar Copying for a player", run = function(rest)
	local p = findPlayer(rest)
	if not p then toast("err", "copyavatar", "No target matches \"" .. tostring(rest) .. "\"") return false end
	UI.showTab("Avatar")
	UI.openPlayerCard(p)
	CAP.CL.add("info", string.format("COMMAND copyavatar -> %s (@%s)", p.DisplayName, p.Name), "CLICK")
	task.spawn(AV.apply, p)
	return true
end })

-- ---------------------------------------------------------------- extra commands
do
	local function needChar(name)
		local r, h = myRoot(), myHum()
		if not r or not h then toast("err", name, "Character not loaded") return nil end
		return r, h
	end

	-- 2. spin <number>
	local spin = {}
	local function spinStop() if spin.conn then spin.conn:Disconnect() spin.conn = nil end end
	defCmd({ name = "spin", arg = "number", desc = "Spin in place (0 stops, 1-60 speed)", run = function(rest)
		local n = numArg(rest)
		if n == 0 or (n == nil and spin.conn) then
			spinStop()
			toast("ok", "spin", "Stopped", { silent = true })
			return true
		end
		local sp = math.clamp(n or 10, 1, 60)
		spinStop()
		spin.conn = RunService.RenderStepped:Connect(function(dt)
			local r = myRoot()
			if r then r.CFrame = r.CFrame * CFrame.Angles(0, math.rad(sp * dt * 60), 0) end
		end)
		toast("ok", "spin", "Speed " .. tostring(sp), { silent = true })
		return true
	end })
	onClean(spinStop)

	-- 3 + 4. view <player> / unview
	local viewConn
	local function unview()
		if viewConn then viewConn:Disconnect() viewConn = nil end
		local c, h = workspace.CurrentCamera, myHum()
		if c and h then c.CameraSubject = h end
	end
	defCmd({ name = "view", arg = "player", desc = "Watch through another player's camera", run = function(rest)
		local p = findPlayer(rest)
		if not p then toast("err", "view", "No target matches \"" .. tostring(rest) .. "\"") return false end
		local th = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		local c = workspace.CurrentCamera
		if not th or not c then toast("err", "view", "Target not loaded") return false end
		if viewConn then viewConn:Disconnect() end
		c.CameraSubject = th
		viewConn = RunService.RenderStepped:Connect(function()
			if not th.Parent then unview() toast("info", "view", "Target left view", { silent = true }) end
		end)
		toast("ok", "view", "Watching " .. p.DisplayName, { silent = true })
		return true
	end })
	defCmd({ name = "unview", desc = "Go back to your own camera", run = function() unview() return true end })
	onClean(unview)

	-- 5 + 6 + 7. savepos / loadpos / copypos
	local savedCF
	defCmd({ name = "savepos", desc = "Remember your current spot", run = function()
		local r = needChar("savepos")
		if not r then return false end
		savedCF = r.CFrame
		toast("ok", "savepos", "Spot saved", { silent = true })
		return true
	end })
	defCmd({ name = "loadpos", desc = "Teleport back to your saved spot", run = function()
		local r = needChar("loadpos")
		if not r then return false end
		if not savedCF then toast("err", "loadpos", "No saved position. Run savepos") return false end
		r.CFrame = savedCF
		return true
	end })
	defCmd({ name = "copypos", desc = "Copy your coordinates to the clipboard", run = function()
		local r = needChar("copypos")
		if not r then return false end
		local p = r.Position
		local txt = string.format("%.1f, %.1f, %.1f", p.X, p.Y, p.Z)
		if copyText(txt) then toast("ok", "copypos", txt, { silent = true }) return true end
		toast("err", "Copy failed", "Clipboard unsupported")
		return false
	end })

	-- more commands
	local loops = {}
	local function stopLoop(k) if loops[k] then loops[k]:Disconnect() loops[k] = nil end end
	local function targetOf(rest, name)
		local p = findPlayer(rest)
		if not p then toast("err", name, "No target matches \"" .. tostring(rest) .. "\"") return nil end
		if not rootOf(p) then toast("err", name, "Target not loaded") return nil end
		return p
	end

	-- headsit / unheadsit
	local function unheadsit()
		stopLoop("headsit") stopLoop("headsitJ")
		local h = myHum()
		if h then h.Sit = false end
	end
	defCmd({ name = "headsit", arg = "player", desc = "Sit on a player's head (jump to get off)", run = function(rest)
		local p = targetOf(rest, "headsit")
		if not p then return false end
		local r, h = needChar("headsit")
		if not r then return false end
		unheadsit() stopLoop("orbit") stopLoop("follow")
		loops.headsit = RunService.Heartbeat:Connect(function()
			local mr, mh = myRoot(), myHum()
			local head = p.Character and p.Character:FindFirstChild("Head")
			if not mr or not mh or not head then unheadsit() return end
			mh.Sit = true
			mr.CFrame = head.CFrame * CFrame.new(0, head.Size.Y / 2 + 1.3, 0)
			mr.AssemblyLinearVelocity = Vector3.zero
		end)
		loops.headsitJ = UIS.JumpRequest:Connect(unheadsit)
		toast("ok", "headsit", "On " .. p.DisplayName .. "'s head", { silent = true })
		return true
	end })
	defCmd({ name = "unheadsit", desc = "Get off their head", run = function() unheadsit() return true end })
	onClean(unheadsit)

	-- follow / unfollow
	defCmd({ name = "follow", arg = "player", desc = "Walk after a player", run = function(rest)
		local p = targetOf(rest, "follow")
		if not p then return false end
		stopLoop("follow") stopLoop("orbit")
		loops.follow = RunService.Heartbeat:Connect(function()
			local mh, tr = myHum(), rootOf(p)
			if not mh or not tr then stopLoop("follow") return end
			mh:MoveTo(tr.Position)
		end)
		toast("ok", "follow", "Following " .. p.DisplayName, { silent = true })
		return true
	end })
	defCmd({ name = "unfollow", desc = "Stop following", run = function()
		stopLoop("follow")
		local r, h = myRoot(), myHum()
		if r and h then h:MoveTo(r.Position) end
		return true
	end })
	onClean(function() stopLoop("follow") end)

	-- orbit / unorbit
	defCmd({ name = "orbit", arg = "player", desc = "Circle around a player", run = function(rest)
		local p = targetOf(rest, "orbit")
		if not p then return false end
		stopLoop("orbit") stopLoop("follow")
		local ang = 0
		loops.orbit = RunService.Heartbeat:Connect(function(dt)
			local mr, tr = myRoot(), rootOf(p)
			if not mr or not tr then stopLoop("orbit") return end
			ang += dt * 2
			local pos = tr.Position + Vector3.new(math.cos(ang) * 7, 0, math.sin(ang) * 7)
			mr.CFrame = CFrame.new(pos, Vector3.new(tr.Position.X, pos.Y, tr.Position.Z))
		end)
		toast("ok", "orbit", "Circling " .. p.DisplayName, { silent = true })
		return true
	end })
	defCmd({ name = "unorbit", desc = "Stop circling", run = function() stopLoop("orbit") return true end })
	onClean(function() stopLoop("orbit") end)

	-- freeze / unfreeze
	defCmd({ name = "freeze", desc = "Lock yourself in place", run = function()
		local r = needChar("freeze")
		if not r then return false end
		r.Anchored = true
		return true
	end })
	defCmd({ name = "unfreeze", desc = "Let yourself move again", run = function()
		local r = myRoot()
		if r then r.Anchored = false end
		return true
	end })
	onClean(function() local r = myRoot() if r then r.Anchored = false end end)

	-- emote <name>
	defCmd({ name = "emote", arg = "name", desc = "Play an emote: dance, wave, cheer, laugh, point", run = function(rest)
		local _, h = needChar("emote")
		if not h then return false end
		local name = tostring(rest):match("^%s*(%S+)") or "dance"
		local ok, played = pcall(function() return h:PlayEmote(name) end)
		if not (ok and played) then toast("err", "emote", "Emote unavailable: " .. name) return false end
		return true
	end })

	-- antisit / rejoin / serverhop
	defCmd({ name = "antisit", toggle = "antisit", desc = "Stop seats from sitting you down" })
	defCmd({ name = "rejoin", desc = "Rejoin this server", run = function() Server.rejoin() return true end })
	defCmd({ name = "serverhop", desc = "Hop to another server", run = function() Server.hop() return true end })

	-- 8. time <number>
	numCmd("time", "Set time of day (0-24)", function() return Lighting.ClockTime end, function(v) Lighting.ClockTime = math.clamp(v, 0, 24) end)

	-- 9. zoom <number>
	numCmd("zoom", "Set max camera zoom distance", function() return LP.CameraMaxZoomDistance end, function(v) LP.CameraMaxZoomDistance = math.clamp(v, 5, 100000) end)

	-- 10. hipheight <number>
	numCmd("hipheight", "Raise or lower your character", function() local h = myHum() return h and h.HipHeight or 0 end, function(v) local h = myHum() if h then h.HipHeight = math.clamp(v, 0, 50) end end)

	-- ===== un-commands =====
	local function refreshSteppers() for _, r in ipairs(stepperRefresh) do r() end end
	local function simple(name, desc, fn)
		defCmd({ name = name, desc = desc, run = function(rest)
			local r = fn(rest)
			if r == nil then r = true end
			return r
		end })
	end
	for _, n in ipairs({ "fly", "noclip", "esp", "float", "infjump", "fullbright", "clicktp", "antisit", "rainbowcar" }) do
		defCmd({ name = "un" .. n, desc = "Turn " .. TG[n].title .. " off", run = function()
			setToggle(n, false)
			toast("ok", TG[n].title, "Disabled", { silent = true })
			return true
		end })
	end
	simple("unspeed", "Reset walk speed", function() Cmd.resetSpeed() refreshSteppers() end)
	simple("unjump", "Reset jump", function() Cmd.resetJump() refreshSteppers() end)
	simple("unfov", "Reset field of view", function() Cmd.resetFov() refreshSteppers() end)
	simple("ungravity", "Reset gravity", function() Cmd.resetGravity() if gravRefresh then gravRefresh() end end)
	local origTime, origZoom, origHip = Lighting.ClockTime, LP.CameraMaxZoomDistance, nil
	do local h0 = myHum() origHip = h0 and h0.HipHeight end
	simple("untime", "Restore the time of day", function() Lighting.ClockTime = origTime end)
	simple("unzoom", "Restore max zoom", function() LP.CameraMaxZoomDistance = origZoom end)
	simple("unhipheight", "Restore hip height", function() local h = myHum() if h then h.HipHeight = origHip or 2 end end)
	simple("unspin", "Stop spinning", function() spinStop() end)
	simple("unsavepos", "Forget your saved spot", function() savedCF = nil end)
	simple("unemote", "Stop the current emote", function()
		local h = myHum()
		local an = h and h:FindFirstChildOfClass("Animator")
		if not an then return false end
		for _, t in ipairs(an:GetPlayingAnimationTracks()) do
			if t.Priority.Value >= 2 and t.Priority.Value < 1000 then pcall(function() t:Stop(0.2) end) end
		end
	end)

	-- ===== new commands =====
	simple("sit", "Sit down", function() local h = myHum() if not h then return false end h.Sit = true end)
	simple("unsit", "Stand back up", function() local h = myHum() if not h then return false end h.Sit = false end)
	simple("reset", "Reset your character", function() local h = myHum() if not h then return false end h.Health = 0 end)
	simple("day", "Set the time to midday", function() Lighting.ClockTime = 14 end)
	simple("night", "Set the time to midnight", function() Lighting.ClockTime = 0 end)
	simple("firstperson", "Lock first person", function() LP.CameraMode = Enum.CameraMode.LockFirstPerson end)
	simple("thirdperson", "Back to normal camera", function() LP.CameraMode = Enum.CameraMode.Classic end)
	for _, d in ipairs({ { "up", 1 }, { "down", -1 } }) do
		defCmd({ name = d[1], arg = "number", desc = "Move " .. d[1] .. " by studs (default 10)", run = function(rest)
			local r = needChar(d[1])
			if not r then return false end
			r.CFrame = r.CFrame + Vector3.new(0, d[2] * (numArg(rest) or 10), 0)
			return true
		end })
	end
	numCmd("ws", "Set walk speed (short)", readSpeed, Cmd.setSpeed)
	numCmd("jp", "Set jump (short)", readJump, Cmd.setJump)
	local function copyCmd(name, desc, value)
		defCmd({ name = name, desc = desc, run = function()
			if copyText(value()) then toast("ok", name, "Copied", { silent = true }) return true end
			toast("err", "Copy failed", "Clipboard unsupported")
			return false
		end })
	end
	copyCmd("jobid", "Copy this server's job ID", function() return tostring(game.JobId) end)
	copyCmd("placeid", "Copy the place ID", function() return tostring(game.PlaceId) end)
	defCmd({ name = "tp", arg = "player", desc = "Teleport to a player", run = CMD_BY["goto"].run })
	local function playerCmd(name, desc, fn)
		defCmd({ name = name, arg = "player", desc = desc, run = function(rest)
			local p = findPlayer(rest)
			if not p then toast("err", name, "No target matches \"" .. tostring(rest) .. "\"") return false end
			fn(p)
			toast("ok", name, p.DisplayName, { silent = true })
			return true
		end })
	end
	playerCmd("hide", "Hide a player from your view", function(p) Feat.setHide(p, true) end)
	playerCmd("unhide", "Show a hidden player again", function(p) Feat.setHide(p, false) end)
	playerCmd("mute", "Mute a player's chat and voice", function(p) Feat.setMute(p, "Both") end)
	playerCmd("unmute", "Unmute a player", function(p) Feat.setMute(p, "Off") end)
	playerCmd("spectate", "Spectate a player (must be close)", function(p) Feat.setSpectate(p, true) end)
	simple("unspectate", "Stop spectating", function()
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LP and Feat.state(p).spec then Feat.setSpectate(p, false) end
		end
	end)
end

-- ---------------------------------------------------------------- recent
local recentList
function rebuildRecent() end
local function addRecent(text)
	for i = #cfg.recent, 1, -1 do if cfg.recent[i] == text then table.remove(cfg.recent, i) end end
	table.insert(cfg.recent, 1, text)
	while #cfg.recent > 8 do table.remove(cfg.recent) end
	cfgSave()
	rebuildRecent()
end

local function runCommand(text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return false end
	local name, rest = text:match("^(%S+)%s*(.*)$")
	local def = CMD_BY[name:lower()]
	if not def then
		toast("warn", "Unknown command", short(name, 24), { silent = true })
		return false
	end
	local ok
	if def.toggle then
		local a = rest:lower()
		local want = (a == "on") and true or (a == "off") and false or not TG[def.toggle].on
		ok = setToggle(def.toggle, want)
		if ok then toast("ok", TG[def.toggle].title, TG[def.toggle].on and "Enabled" or "Disabled", { silent = true }) end
	else
		ok = def.run(rest)
	end
	log("info", "command: " .. text .. " -> " .. tostring(ok))
	if ok ~= false then addRecent(text) end
	return ok ~= false
end
UI.runCommand = runCommand

-- ---------------------------------------------------------------- role spam
do
	local ROLES = { "Police", "Firefighter", "Doctor", "Baker", "Pizza Worker", "Barista" } -- Life Together job names
	local WORKERS = 160 -- parallel senders; each fires its next role the instant the last one is answered (raise for faster, lower if the server lags)

	local rc = mk("Frame", { Size = UDim2.fromOffset(240, 84), BackgroundTransparency = 1, Visible = false }, gui)
	rc.Visible = false -- role spam lives on Home now, not on the Commands tab
	local hdr = Icon.new(rc, "role", 18, "accent")
	hdr.frame.Position = UDim2.fromOffset(14, 11)
	label(rc, "Roles", 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(40, 10), Size = UDim2.new(1, -54, 0, 20) })
	label(rc, "Role spam", 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 47), Size = UDim2.new(1, -90, 0, 18) })

	local state = { on = false, token = 0 }
	local remote
	local function getRemote()
		if remote and remote.Parent then return remote end
		local ok, r = pcall(function() return RS.Packages.Flux.Services.RoleService.RF.SetRole end)
		remote = ok and r or nil
		return remote
	end

	local sw
	local function paint(on) if H.roleSpamPaint then H.roleSpamPaint(on) end end
	local function stop() state.on = false state.token += 1 paint(false) end
	local function start()
		local r = getRemote()
		if not r then
			toast("err", "Role Spam", "Remote not found")
			sw.set(false, true)
			paint(false)
			return
		end
		state.on = true
		state.token += 1
		local my = state.token
		log("info", "role spam started")
		local i, fails, running = 0, 0, 0
		local function live() return state.on and state.token == my and not dead end
		local function worker()
			running += 1
			while live() do -- checked before EVERY send, so off means no more calls leave this client
				i = i % #ROLES + 1
				local role = ROLES[i]
				local t0 = os.clock()
				local ok = pcall(function() return GX_roleFire(r, role) end)
				if not live() then break end
				if ok then fails = 0 else fails += 1 end
				if fails >= 40 then
					stop()
					sw.set(false, true)
					toast("warn", "Role Spam Stopped", "Server rejected requests")
					break
				end
				if not ok or os.clock() - t0 < 0.004 then task.wait() end -- never spin without yielding
			end
			running -= 1
			if running == 0 then log("info", "role spam stopped") end
		end
		for _ = 1, WORKERS do task.spawn(worker) end
	end

	sw = switch(rc, false, function(v)
		haptic(0.2)
		if v then start() paint(true) else stop() end
	end)
	sw.frame.AnchorPoint = Vector2.new(1, 0)
	sw.frame.Position = UDim2.new(1, -14, 0, 45)
	H.roleSpam = { toggle = function() sw.set(not sw.get()) end }
	onClean(stop)
end

	-- ---------------------------------------------------------------- HOME WIDGETS (left column, built here because TG / setToggle live here)
	local function tgRow(parent, y, name)
		local t = TG[name]
		local row = mk("Frame", { Size = UDim2.new(1, -20, 0, 44), Position = UDim2.fromOffset(10, y), BackgroundTransparency = 1 }, parent)
		local tic = Icon.new(row, t.icon, 22, "text")
		tic.frame.AnchorPoint = Vector2.new(0.5, 0.5)
		tic.frame.Position = UDim2.fromOffset(21, 22)
		label(row, t.title, 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(44, 5), Size = UDim2.new(1, -110, 0, 18) })
		label(row, t.desc, 11, "muted", { Position = UDim2.fromOffset(44, 24), Size = UDim2.new(1, -110, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd })
		local sw
		sw = switch(row, t.on, function(v)
			haptic(0.2)
			if setToggle(name, v) then toast("ok", t.title, v and "Enabled" or "Disabled", { silent = true })
			else sw.set(t.on, true) end
		end)
		sw.frame.AnchorPoint = Vector2.new(1, 0.5)
		sw.frame.Position = UDim2.new(1, -2, 0.5, 0)
		t.ui[#t.ui + 1] = sw
	end

	UI.mount(UI.homeL, "toggles", 40 + 4 * 46 + 4, function(w)
		UI.header(w, "Toggles", "bolt")
		GXRow(w, 36, "check", "Free Premium", "Premium features unlocked", false, function(v) if X then X.freepay_func(v) end end)
		GXRow(w, 82, "float", "Float", "Hover in place", false, function(v) if X then if v then X.start_flames_float() else X.stop_flames_float() end end end)
		GXRow(w, 128, "noclip", "Noclip", "Walk straight through walls", false, function(v) if X then X.ToggleNoclip(v) end end)
		GXRow(w, 174, "wave", "Walk Fling", "Fling players you walk into", false, function(v) if X then if v then X.start_walkfling() else X.stop_walkfling() end end end)
	end, { order = 20 })

	UI.mount(UI.homeL, "extras", 380, function(w)
		UI.header(w, "Extras", "grid")
		GXRow(w, 36, "shield", "Anti House Ban", "House bans can't touch you", false, function(v) if X then X.anti_house_ban(v) end end)
		GXRow(w, 82, "rainbow", "Rainbow Vehicle", "Cycle colors on your car", (X and X.RGB_Vehicle_state and X.RGB_Vehicle_state()) or false, function(v) if X then X.RGB_Vehicle(v) end end)
		GXRow(w, 128, "lock", "Auto Lock Home", "Keep your house locked", false, function(v) if X then X.keep_home_locked(v) end end)
		GXBtn(w, 178, "Bring Vehicle To Me", false, function() if X then X.bring_vehicle_to_me() end end)
		GXBtn(w, 228, "Spawn SchoolBus", false, function() if X then X.spawn_any_vehicle("SchoolBus") end end)
		local vin = GXInput(w, 278, "Vehicle name")
		GXBtn(w, 328, "Spawn Vehicle", true, function() if X and vin.Text ~= "" then X.spawn_any_vehicle(vin.Text) end end)
	end, { order = 30 })

end

-- ============================================================================
-- 25b. FEATURES TAB: the GenX Life Together feature set (built inside this window)
-- ============================================================================
UI.mountTroll = function()
	local page = pages.Troll
	local colL, colR = UI.columns(page)
	local function findByName(text)
		if not text or text == "" then return nil end
		local q = text:lower()
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LP and (p.Name:lower():find(q, 1, true) or p.DisplayName:lower():find(q, 1, true)) then return p end
		end
		return nil
	end
	UI.mount(colL, "gxcharacter", 40 + 5 * 46 + 4, function(w)
		UI.header(w, "Character", "person")
		GXRow(w, 36, "rainbow", "RGB Skin", "Cycle your skin tone", false, function(v) if X then X.rainbow_skin(v) end end)
		GXRow(w, 82, "sliders", "RGB Phone", "Cycle your phone color", false, function(v) if X then X.RGB_Phone(v) end end)
		GXRow(w, 128, "sliders", "RGB Tool", "Cycle your tool color", false, function(v) if X then X.rainbow_tool(v) end end)
		GXRow(w, 174, "eyeOff", "Flash Invisible", "Blink in and out of sight", false, function(v) if X then X.flash_invisible(v) end end)
		GXRow(w, 220, "mute", "Block Calls", "Nobody can call you", false, function(v) if X then X.block_calls(v) end end)
	end, { order = 10 })
	UI.mount(colL, "gxbody", 236, function(w)
		UI.header(w, "Body Size", "sliders")
		local hin = GXInput(w, 36, "Height scale (number or inf)")
		hin.FocusLost:Connect(function()
			local v = tonumber(hin.Text)
			if v then if X then X.height_func_setter(v) end else pcall(toast, "warn", "Body Size", "Enter a valid number!") end
		end)
		local win = GXInput(w, 84, "Width scale (number or inf)")
		win.FocusLost:Connect(function()
			local v = tonumber(win.Text)
			if v then if X then X.width_func_setter(v) end else pcall(toast, "warn", "Body Size", "Enter a valid number!") end
		end)
		GXBtn(w, 132, "Cover Map", true, function() if X then X.size_func_setter(85, 85) end end)
		GXBtn(w, 182, "Reset Size", false, function() if X then X.size_func_setter(1, 1) end end)
	end, { order = 20 })
	UI.mount(colR, "gxdefense", 270, function(w)
		UI.header(w, "Defense", "shield")
		GXRow(w, 36, "shield", "Anti Fling", "Throws can't move you", false, function(v) if X then X.Toggle_AntiFling_Boolean_Func(v) end end)
		GXRow(w, 82, "warn", "Anti Void", "Void drops can't kill you", false, function(v) if X then X.anti_void(v) end end)
		GXRow(w, 128, "bolt", "Anti Fire", "Fire can't touch you", false, function(v) if X then X.set_fire_state(v) end end)
		GXRow(w, 174, "car", "Anti Car Fling", "Cars can't fling you", false, function(v) if X then X.anti_car_fling(v) end end)
		GXRow(w, 220, "eye", "Anti Invisible Players", "See invisible players", false, function(v) if X then X.Anti_Invisible_Players(v) end end)
	end, { order = 10 })
	UI.mount(colR, "gxutility", 282, function(w)
		UI.header(w, "Utility", "sliders")
		GXRow(w, 36, "bolt", "FPS Boost", "Strip effects for frames", false, function(v) if X then X.FlamesLagReducerFunc(v) end end)
		GXRow(w, 82, "sun", "Night Vision", "See in the dark", false, function(v) if X then X.night_vision(v) end end)
		GXRow(w, 128, "rainbow", "RGB Street Lights", "Cycle the street lights", false, function(v) if X then X.toggle_rgb_streetlights(v) end end)
		GXBtn(w, 178, "Set SpawnPoint", false, function() if X then X.set_spawnpoint(0.1) end end)
		GXBtn(w, 228, "Clear SpawnPoint", false, function() if X then X.clear_spawnpoint() end end)
	end, { order = 20 })
end
xpcall(UI.mountTroll, function(e) pcall(toast, "err", "Features tab", short(e, 70)) end)

local setAntiAfk, AutoExec
do

-- ============================================================================
-- 26. SETTINGS TAB
-- ============================================================================
local setPage = pages.Settings
local syncFns = {} -- each control re-reads cfg when config is imported / layout reset
function H.settingsSync() for _, f in ipairs(syncFns) do pcall(f) end end

local sL, sR = UI.columns(setPage)

local function sCard(col, title, height, order)
	local c = UI.widget(col, height, "set" .. (title:gsub("%W", "")), { order = order * 10 })
	label(c, title, 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 20) })
	return c
end

-- a labelled switch row at y inside a card; get/set talk to cfg
local function switchRow(c, y, title, desc, get, set)
	label(c, title, 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -90, 0, 18) })
	if desc then label(c, desc, 11, "muted", { Position = UDim2.fromOffset(14, y + 19), Size = UDim2.new(1, -90, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd }) end
	local sw = switch(c, get(), function(v) set(v) cfgSave() end)
	sw.frame.AnchorPoint = Vector2.new(1, 0)
	sw.frame.Position = UDim2.new(1, -14, 0, y + 2)
	syncFns[#syncFns + 1] = function() sw.set(get(), true) end
	return sw
end

local function sliderRow(c, y, title, min, max, get, set, fmt)
	label(c, title, 14, "text", { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, y), Size = UDim2.new(0.6, 0, 0, 18) })
	local val = label(c, string.format(fmt, get()), 13, "accent", { Font = Enum.Font.GothamBold, Position = UDim2.new(0.6, 0, 0, y), Size = UDim2.new(0.4, -14, 0, 18), TextXAlignment = Enum.TextXAlignment.Right })
	local sl = slider(c, min, max, get(), function(v) set(v) val.Text = string.format(fmt, v) end, UDim2.new(1, -28, 0, 28))
	sl.frame.Position = UDim2.fromOffset(14, y + 20)
	syncFns[#syncFns + 1] = function() sl.set(get()) val.Text = string.format(fmt, get()) end
	return sl
end

-- ---------------------------------------------------------------- auto-launch
-- queue_on_teleport covers rejoin / server hop; a file in the executor's autoexec folder covers leaving and coming back later.
-- both just re-run the script link (CAP.selfUrl, the loader link, or getgenv().GENX_SELF_URL). the switch below removes both.
do
	local AL_FILE = "genx_dreamville.lua"
	local AL_DIRS = { "../Autoexecute/", "autoexec/", "Autoexecute/" } -- the first folder this executor accepts wins
	AutoExec = { queued = false, where = nil }

	local function alUrl()
		-- placeholder: backend removed, no hosted script link to re-run
		return nil
	end
	local function alBody(url)
		return ("-- GenX Dreamville auto-launch (turn it off in GenX > Settings > Auto-launch)\nif game.PlaceId == %d then\n\trepeat task.wait() until game:IsLoaded()\n\tloadstring(game:HttpGet(%q))()\nend\n"):format(DREAMVILLE_PLACE_ID, url)
	end

	function AutoExec.status()
		if not alUrl() then return "Needs your script link: paste it into CAP.selfUrl near the top" end
		if AutoExec.where then return "On: saved to your executor's autoexec folder" end
		if CAP.qot then return "On: relaunches after rejoin and server hop" end
		return "This executor can't auto-launch"
	end
	function AutoExec.queue()
		local url = alUrl()
		if AutoExec.queued or not url or not CAP.qot then return end
		AutoExec.queued = (pcall(queue_on_teleport, alBody(url)))
	end
	function AutoExec.install()
		local url = alUrl()
		if not url or not CAP.writefile or AutoExec.where then return end
		local body = alBody(url)
		for _, d in ipairs(AL_DIRS) do
			local path = d .. AL_FILE
			local ok = CAP.CL.rawPcall(writefile, path, body) -- most folders don't exist on a given executor, that's expected
			if ok then
				local okf, ex = pcall(isfile, path)
				if okf and ex then AutoExec.where = path break end
			end
		end
	end
	function AutoExec.remove()
		if typeof(clear_teleport_queue) == "function" then pcall(clear_teleport_queue) end
		AutoExec.queued = false
		if CAP.writefile then
			for _, d in ipairs(AL_DIRS) do
				local path = d .. AL_FILE
				local okf, ex = pcall(isfile, path)
				if okf and ex then
					if typeof(delfile) == "function" then pcall(delfile, path) else pcall(writefile, path, "-- GenX auto-launch is off\n") end
				end
			end
		end
		AutoExec.where = nil
	end
	function AutoExec.apply(on)
		if on then AutoExec.queue() AutoExec.install() else AutoExec.remove() end
	end

	local c = sCard(sR, "Auto-launch", 88, 1)
	switchRow(c, 40, "Auto relaunch", nil, function() return cfg.autoLaunch ~= false end, function(v)
		cfg.autoLaunch = v
		AutoExec.apply(v)
		toast(v and "ok" or "info", "Auto-launch", v and "GenX will launch itself in Dreamville" or "Auto-launch removed", { silent = true })
	end)
end

-- ---------------------------------------------------------------- themes
do
	local n = #THEME_ORDER
	local rows = math.ceil(n / 2)
	local c = sCard(sL, "Themes", 40 + rows * 104 + 4, 1)
	local grid2 = mk("Frame", { Size = UDim2.new(1, -20, 0, rows * 104), Position = UDim2.fromOffset(10, 36), BackgroundTransparency = 1 }, c)
	mk("UIGridLayout", { CellSize = UDim2.new(0.5, -5, 0, 96), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }, grid2)
	local checks, strokes = {}, {}
	for i, name in ipairs(THEME_ORDER) do
		local th = THEMES[name]
		local b = mk("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = th.bg, BorderSizePixel = 0, LayoutOrder = i }, grid2)
		round(b, 14)
		local st = mk("UIStroke", { Thickness = 1, Color = th.stroke }, b)
		strokes[name] = st
		-- mini top bar
		local tb = mk("Frame", { Size = UDim2.new(1, -14, 0, 18), Position = UDim2.fromOffset(7, 7), BackgroundColor3 = th.card, BorderSizePixel = 0 }, b)
		round(tb, 6)
		mk("Frame", { Size = UDim2.fromOffset(26, 4), Position = UDim2.fromOffset(7, 7), BackgroundColor3 = th.text, BorderSizePixel = 0 }, tb)
		local wm = mk("Frame", { Size = UDim2.fromOffset(20, 10), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -5, 0.5, 0), BackgroundColor3 = th.accent, BorderSizePixel = 0 }, tb)
		round(wm, 5)
		-- mini accent button
		local btn = mk("Frame", { Size = UDim2.fromOffset(46, 14), Position = UDim2.fromOffset(9, 32), BackgroundColor3 = th.accent, BorderSizePixel = 0 }, b)
		round(btn, 7)
		-- mini nav pill
		local np = mk("Frame", { Size = UDim2.fromOffset(62, 12), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -22), BackgroundColor3 = th.card, BorderSizePixel = 0 }, b)
		round(np, 6)
		local dot = mk("Frame", { Size = UDim2.fromOffset(18, 8), Position = UDim2.fromOffset(3, 2), BackgroundColor3 = th.accent, BorderSizePixel = 0 }, np)
		round(dot, 4)
		mk("TextLabel", { Size = UDim2.new(1, -10, 0, 16), Position = UDim2.new(0, 8, 1, -19), BackgroundTransparency = 1, Text = name, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = th.text, TextXAlignment = Enum.TextXAlignment.Left }, b)
		checks[name] = mk("TextLabel", { Size = UDim2.fromOffset(18, 18), AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -6, 1, -4), BackgroundColor3 = th.accent, Text = "", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false }, b)
		round(checks[name], 9)
		local cki = Icon.new(checks[name], "check", 12, Color3.new(1, 1, 1))
		cki.frame.AnchorPoint = Vector2.new(0.5, 0.5)
		cki.frame.Position = UDim2.fromScale(0.5, 0.5)
		b.Activated:Connect(function()
			haptic(0.3)
			applyTheme(name, true)
		end)
	end
	local function paintChecks()
		for name, ck in pairs(checks) do
			ck.Visible = (name == cfg.theme)
			strokes[name].Thickness = (name == cfg.theme) and 2 or 1
			strokes[name].Color = (name == cfg.theme) and THEMES[name].accent or THEMES[name].stroke
		end
	end
	onTheme(function() paintChecks() end)
	syncFns[#syncFns + 1] = function() applyTheme(cfg.theme, false) paintChecks() end
end

-- ---------------------------------------------------------------- notifications
do
	local c = sCard(sL, "Notifications", 36 + 4 * 46 + 52, 2)
	switchRow(c, 38, "Friend join alerts", "Toast when a friend joins", function() return cfg.joinAlerts end, function(v) cfg.joinAlerts = v end)
	switchRow(c, 84, "Friend leave alerts", "Toast when a friend leaves", function() return cfg.leaveAlerts end, function(v) cfg.leaveAlerts = v end)
	H.hapSwitch = switchRow(c, 130, "Haptics", "Vibration plus a small shake", function() return cfg.haptics end, function(v) cfg.haptics = v paintHap() end)
	switchRow(c, 176, "Sound", "Short ping on notifications", function() return cfg.sound end, function(v) cfg.sound = v refreshVolume() end)
	sliderRow(c, 222, "Volume", 0, 1, function() return cfg.volume end, function(v) cfg.volume = v refreshVolume() cfgSave() end, "%.2f")
end
-- settings re-sync also repaints the top-bar haptic icon and the sound volume
do
	local old = H.settingsSync
	function H.settingsSync() old() paintHap() refreshVolume() end
end

do
	local c = sCard(sL, "Server tools", 40 + 2 * 50, 4)
	local g = mk("Frame", { Size = UDim2.new(1, -28, 0, 100), Position = UDim2.fromOffset(14, 36), BackgroundTransparency = 1 }, c)
	mk("UIGridLayout", { CellSize = UDim2.new(0.5, -4, 0, 42), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }, g)
	local function copyBtn(text, what, value, order)
		local b = button(g, text, false, nil, function()
			if copyText(value) then toast("ok", "Copied", what, { silent = true }) else toast("err", "Copy failed", "Clipboard unsupported") end
		end)
		b.LayoutOrder = order
	end
	local r = button(g, "Rejoin", false, nil, Server.rejoin) r.LayoutOrder = 1
	local h = button(g, "Server hop", true, nil, Server.hop) h.LayoutOrder = 2
	copyBtn("Copy Job ID", "Job ID", tostring(game.JobId), 3)
	copyBtn("Copy Place ID", "Place ID", tostring(game.PlaceId), 4)
end

-- ---------------------------------------------------------------- utilities
local afk = {}
function setAntiAfk(on)
	if afk.conn then afk.conn:Disconnect() afk.conn = nil end
	if not on then return end
	afk.conn = LP.Idled:Connect(function()
		pcall(function()
			local vu = game:GetService("VirtualUser")
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end)
end
onClean(function() setAntiAfk(false) end)
do
	local c = sCard(sR, "Utilities", 36 + 7 * 46 + 4, 4)
	switchRow(c, 38, "Anti-AFK", "Stops the idle kick", function() return cfg.antiAfk end, function(v) cfg.antiAfk = v setAntiAfk(v) end)
	switchRow(c, 84, "FPS counter", "Shown in the top bar", function() return cfg.fps end, function(v) cfg.fps = v end)

	-- 1. auto-rejoin after a kick / disconnect
	task.spawn(function()
		local ok, overlay = pcall(function()
			return CoreGui:WaitForChild("RobloxPromptGui", 10):WaitForChild("promptOverlay", 10)
		end)
		if not ok or not overlay or dead then return end
		keep(overlay.ChildAdded:Connect(function(ch)
			if ch.Name ~= "ErrorPrompt" or not cfg.autoRejoin or dead then return end
			task.wait(1.5)
			if cfg.autoRejoin and not dead then pcall(function() queueRelaunchOrHint() TeleportService:Teleport(game.PlaceId, LP) end) end
		end))
	end)
	switchRow(c, 130, "Auto-rejoin", "Rejoin after a kick or disconnect", function() return cfg.autoRejoin end, function(v) cfg.autoRejoin = v end)

	-- 2. lower graphics
	local gfx = {}
	local function setLowGfx(on)
		if on then
			if gfx.saved then return end
			gfx.saved = { shadows = Lighting.GlobalShadows, fx = {} }
			pcall(function() gfx.saved.quality = settings().Rendering.QualityLevel end)
			Lighting.GlobalShadows = false
			for _, e in ipairs(Lighting:GetChildren()) do
				if e:IsA("PostEffect") and e.Enabled then gfx.saved.fx[#gfx.saved.fx + 1] = e e.Enabled = false end
			end
			pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
		elseif gfx.saved then
			local sv = gfx.saved
			gfx.saved = nil
			Lighting.GlobalShadows = sv.shadows
			for _, e in ipairs(sv.fx) do if e.Parent then e.Enabled = true end end
			if sv.quality then pcall(function() settings().Rendering.QualityLevel = sv.quality end) end
		end
	end
	switchRow(c, 176, "Lower graphics", "Less lag: no shadows or effects", function() return cfg.lowGfx end, function(v) cfg.lowGfx = v setLowGfx(v) end)

	-- 3. mute game audio
	local mute = {}
	local function setMute(on)
		pcall(function()
			local ugs = UserSettings():GetService("UserGameSettings")
			if on then
				if mute.prev == nil then mute.prev = ugs.MasterVolume end
				ugs.MasterVolume = 0
			elseif mute.prev ~= nil then
				ugs.MasterVolume = mute.prev
				mute.prev = nil
			end
		end)
	end
	switchRow(c, 222, "Mute game audio", "Silence the whole game", function() return cfg.muteGame end, function(v) cfg.muteGame = v setMute(v) end)

	-- 4. unlock camera zoom
	local zoom = {}
	local function setZoom(on)
		if on then
			zoom.saved = zoom.saved or { max = LP.CameraMaxZoomDistance, min = LP.CameraMinZoomDistance }
			LP.CameraMaxZoomDistance, LP.CameraMinZoomDistance = 1e4, 0.5
		elseif zoom.saved then
			LP.CameraMaxZoomDistance, LP.CameraMinZoomDistance = zoom.saved.max, zoom.saved.min
			zoom.saved = nil
		end
	end
	switchRow(c, 268, "Unlock zoom", "Zoom the camera out much farther", function() return cfg.unlockZoom end, function(v) cfg.unlockZoom = v setZoom(v) end)

	-- 5. anti-sit (same switch as the antisit command)
	local asw = switchRow(c, 314, "Anti-sit", "Seats can't sit you down", function() return TG.antisit.on end, function(v) setToggle("antisit", v) end)
	TG.antisit.ui[#TG.antisit.ui + 1] = asw


	-- restore saved choices on launch, undo everything on destroy
	if cfg.lowGfx then setLowGfx(true) end
	if cfg.muteGame then setMute(true) end
	if cfg.unlockZoom then setZoom(true) end
	onClean(function() setLowGfx(false) setMute(false) setZoom(false) end)
end

do
	local c = sCard(sL, "Config", 36 + 52 + 66 + 52, 3)
	local row = mk("Frame", { Size = UDim2.new(1, -28, 0, 42), Position = UDim2.fromOffset(14, 36), BackgroundTransparency = 1 }, c)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, row)
	button(row, "Export config", false, UDim2.new(1, 0, 1, 0), function()
		local json = HttpService:JSONEncode(cfg)
		if copyText(json) then toast("ok", "Config Copied", "Export ready", { silent = true })
		else toast("err", "Copy failed", "Clipboard unsupported") end
	end)
	local box = mk("TextBox", { Size = UDim2.new(1, -28, 0, 58), Position = UDim2.fromOffset(14, 86), Text = "", PlaceholderText = "Paste a config here", Font = Enum.Font.Code, TextSize = 12, ClearTextOnFocus = false, MultiLine = true, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, BorderSizePixel = 0 }, c)
	themed(box, { BackgroundColor3 = "bg", TextColor3 = "text", PlaceholderColor3 = "muted" })
	round(box, 10)
	pad(box, 8, 6, 8, 6)
	local imp = button(c, "Import config", true, UDim2.new(1, -28, 0, 42), function()
		local ok, res = importConfig(box.Text)
		if ok then box.Text = "" toast("ok", "Config imported", res .. " settings applied", { silent = true })
		else toast("err", "Import failed", tostring(res)) end
	end)
	imp.Position = UDim2.fromOffset(14, 152)
end

end


-- ============================================================================
-- 26b. FIRST-RUN TUTORIAL (new users only, shown once). Blurred backdrop, spotlight on the REAL controls, animated tap demo.
-- ============================================================================
UI.tutorial = function()
	if dead then return end
	local th = T()
	local root
	local function VP()
		if root and root.Parent and root.AbsoluteSize.X > 10 then return root.AbsoluteSize end
		return (workspace.CurrentCamera or cam).ViewportSize
	end
	local w0 = os.clock()
	while not dead and UI.state ~= "open" and os.clock() - w0 < 12 do task.wait(0.2) end
	if dead or UI.state ~= "open" then return end
	task.wait(1.2) -- let the fly-in finish
	if dead then return end

	local function lumOf(c) return c.R * 0.3 + c.G * 0.59 + c.B * 0.11 end
	local lum = math.max(lumOf(th.accent), lumOf(th.accent2 or th.accent)) -- the button is an accent -> accent2 gradient, judge its light end
	local onAccent = lum > 0.5 and Color3.fromRGB(14, 16, 24) or Color3.new(1, 1, 1)

	local prevInsets = gui.ScreenInsets -- full screen: drop the side safe-area strips for the length of the tutorial only
	pcall(function() gui.ScreenInsets = Enum.ScreenInsets.None end)
	root = track(mk("Frame", { Name = "Tutorial", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Active = true, ZIndex = 100 }, gui))

	-- SPOT LAYER: dim panels, ring and tap demo live INSIDE the hub window (same parent chain as the real controls), so the
	-- spotlight can never drift from the control (the old root-relative math was off by the topbar inset). The layer is
	-- counter-scaled so everything inside it is in real pixels, measured against spot.AbsolutePosition.
	local WH, WS = UI.winHolder, UI.winScale
	local spot, spotScale = root, nil
	if WH and WS then
		spot = track(mk("Frame", { Name = "TutSpot", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 99 }, WH))
		spotScale = mk("UIScale", { Scale = 1 }, spot)
	end
	local function syncSpot()
		if not spotScale then return end
		local sc = math.max(0.05, WS.Scale)
		spotScale.Scale = 1 / sc
		spot.Size = UDim2.fromScale(sc, sc)
	end
	syncSpot()
	local blur = track(mk("BlurEffect", { Name = "GenXTutBlur", Size = 0 }, Lighting))
	tw(blur, 0.6, { Size = 20 })

	-- every other GUI behind the tutorial goes away (executor, Roblox, game) and comes back when it ends
	local hidden = {}    -- ScreenGuis we switched off: [gui] = true
	local hiddenVis = {} -- GuiObjects inside protected guis (RobloxGui etc.) we switched off: [obj] = true
	local tutOver = false
	local KEEP = { RobloxGui = true, RobloxPromptGui = true, PurchasePromptApp = true, ThemeProvider = true, RobloxNetworkPause = true, TeleportGui = true, TopBarApp = true }
	local HINTS = { "deltaexploits", "using delta", "execute clipboard", "script1.lua" } -- text only the Delta editor shows
	local function claim(d) -- d is something that belongs to a foreign gui: switch off the gui (or just its branch if it hides in a Roblox gui)
		if tutOver then return end
		local sg = d
		while sg and not sg:IsA("ScreenGui") do sg = sg.Parent end
		if not sg or sg == gui or sg.Name:sub(1, 5) == "GenXD" then return end
		if KEEP[sg.Name] then
			local top = d
			while top.Parent and top.Parent ~= sg do top = top.Parent end
			if top:IsA("GuiObject") and hiddenVis[top] == nil and top.Visible then hiddenVis[top] = true end
		elseif hidden[sg] == nil and sg.Enabled then
			hidden[sg] = true
		end
	end
	local function sweep()
		if tutOver then return end
		local roots = { CoreGui }
		if CAP.gethui then
			local okh, h = pcall(gethui)
			if okh and h and h ~= CoreGui then roots[#roots + 1] = h end
		end
		for _, r in ipairs(roots) do
			for _, g in ipairs(r:GetChildren()) do
				if g:IsA("ScreenGui") and g ~= gui and not KEEP[g.Name] and g.Name:sub(1, 5) ~= "GenXD" then
					if hidden[g] == nil and g.Enabled then hidden[g] = true end
				end
			end
		end
		for g in pairs(hidden) do -- keep everything we claimed switched off, even if it re-enables itself
			if g.Parent and g.Enabled then pcall(function() g.Enabled = false end) end
		end
		for o in pairs(hiddenVis) do
			if o.Parent and o.Visible then pcall(function() o.Visible = false end) end
		end
	end
	-- the Delta editor / other executors can sit in any container or even inside a Roblox gui: find them by what they show, not by name
	local function deepScan()
		local places = {}
		local pg = LP:FindFirstChildOfClass("PlayerGui")
		if pg then places[#places + 1] = pg end
		if CAP.gethui then
			local okh, h = pcall(gethui)
			if okh and h then places[#places + 1] = h end
		end
		places[#places + 1] = CoreGui
		local seen = 0
		for _, r in ipairs(places) do
			for _, top in ipairs(r:GetChildren()) do
				if tutOver or dead then return end
				if top ~= gui and top.Name:sub(1, 5) ~= "GenXD" then
					if top:IsA("ScreenGui") and top.Name:lower():find("delta", 1, true) then claim(top) end
					local ok, list = pcall(function() return top:GetDescendants() end)
					if ok then
						for _, d in ipairs(list) do
							if d:IsA("TextLabel") or d:IsA("TextButton") then
								local t = d.Text
								if #t > 3 and #t < 120 then
									t = t:lower()
									for _, hnt in ipairs(HINTS) do
										if t:find(hnt, 1, true) then claim(d) break end
									end
								end
							end
							seen += 1
							if seen % 600 == 0 then task.wait() end
						end
					end
				end
			end
		end
	end
	local function restoreExternal()
		tutOver = true -- from here on nothing may be hidden again (the old loop could re-hide right after the restore)
		for g in pairs(hidden) do
			pcall(function() if g.Parent then g.Enabled = true end end)
		end
		for o in pairs(hiddenVis) do
			pcall(function() if o.Parent then o.Visible = true end end)
		end
		table.clear(hidden)
		table.clear(hiddenVis)
	end
	UI.tutRestore = restoreExternal
	onClean(restoreExternal)
	pcall(UI.hud, true) -- Roblox + game HUD off
	sweep()

	-- ---------------------------------------------------------------- finders (they look at the real, live controls)
	local function isShown(o)
		local c = o
		while c and c ~= gui do
			if c:IsA("GuiObject") and not c.Visible then return false end
			c = c.Parent
		end
		return o.AbsoluteSize.X > 4 and o.AbsoluteSize.Y > 4
	end
	local function scan(pred)
		for _, d in ipairs(gui:GetDescendants()) do
			if not d:IsDescendantOf(root) and pred(d) and isShown(d) then return d end
		end
	end
	local function byText(t)
		return scan(function(d) return (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text == t end)
	end
	local function tileOf(o)
		local V = VP()
		local cur = o
		for _ = 1, 3 do
			local p = cur.Parent
			if not (p and p:IsA("GuiObject")) or p.AbsoluteSize.X > V.X * 0.4 or p.AbsoluteSize.Y > V.Y * 0.45 then break end
			cur = p
			if p.BackgroundTransparency < 0.9 then break end
		end
		return cur
	end

	local STEPS = {
		{ title = "Welcome to GenX", body = "A 60 second walkthrough of the core tools. Everything you see is live.", tab = "Home" },
		{ title = "Navigation", body = "The dock switches between Home, Avatar, Features and Settings.", tab = "Home",
			find = function() return UI.navRow end,
			tap = function() return UI.navRow and UI.navRow:FindFirstChild("Troll") end },
		{ title = "Quick Commands", body = "Job Spam cycles jobs at maximum speed. Copy Avatar clones a target's look. Anti Steal guards your outfit. One tap toggles each.", tab = "Home",
			find = function() local r = UI.tutRef.roleTile if r and isShown(r) then return r end local l = byText("Role Spam") return l and tileOf(l) end },
		{ title = "Avatar Copy", body = "Select a target, run the check, then copy. Protected targets are flagged automatically.", tab = "Avatar", page = true },
		{ title = "Select a Target", body = "Pick a target from the list. The truck spawns, locks on and follows.", tab = "Troll",
			find = function()
				local r = UI.tutRef.list
				if r and isShown(r) then return r end
				local b = scan(function(d) return d:IsA("TextBox") and d.PlaceholderText == "Search player" end)
				return b and b.Parent
			end },
		{ title = "Unfollow", body = "Ends the session, clears the vehicle and returns to the saved position.", tab = "Troll",
			find = function()
				local r = UI.tutRef.unfollow
				if r and isShown(r) then return r end
				local l = byText("Unfollow")
				return l and (l:IsA("TextButton") and l or tileOf(l))
			end },
		{ title = "Settings", body = "Themes, UI scale and opacity, notifications, sound, utilities like Anti-AFK and Billboards, server tools and config export.", tab = "Settings", page = true },
		{ title = "Ready", body = "Setup complete. Select a target and start.", tab = "Home" },
	}

	-- ---------------------------------------------------------------- backdrop: four panels around a hole, tweened to the spotlight
	local function dimFrame() return mk("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 101 }, spot) end
	local dT, dB, dL, dR = dimFrame(), dimFrame(), dimFrame(), dimFrame()
	local V0 = VP()
	dT.Size = UDim2.fromScale(1, 1)
	for _, f in ipairs({ dT, dB, dL, dR }) do tw(f, 0.5, { BackgroundTransparency = 0.38 }) end
	local function setHole(x, y, w, h) -- real px relative to the spot layer
		syncSpot()
		local V = (spot ~= root and spot.AbsoluteSize.X > 10) and spot.AbsoluteSize or VP()
		local function put(f, pos, size) tw(f, 0.4, { Position = pos, Size = size }) end
		put(dT, UDim2.fromOffset(0, 0), UDim2.fromOffset(V.X, y))
		put(dB, UDim2.fromOffset(0, y + h), UDim2.fromOffset(V.X, math.max(0, V.Y - y - h)))
		put(dL, UDim2.fromOffset(0, y), UDim2.fromOffset(x, h))
		put(dR, UDim2.fromOffset(x + w, y), UDim2.fromOffset(math.max(0, V.X - x - w), h))
	end

	-- pulsing ring around the spotlight
	local ring = mk("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 103, Visible = false }, spot)
	round(ring, 14)
	local rs = mk("UIStroke", { Thickness = 2.5, Color = th.accent, Transparency = 0.1 }, ring)
	TweenService:Create(rs, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.8 }):Play()

	-- animated finger + ripple (the tap demo)
	local cur = mk("Frame", { Size = UDim2.fromOffset(26, 26), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 110, Visible = false }, spot)
	round(cur, 13)
	mk("UIStroke", { Thickness = 2, Color = th.accent }, cur)
	local rip = mk("Frame", { Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 109, Visible = false }, spot)
	round(rip, 100)
	local ripS = mk("UIStroke", { Thickness = 3, Color = th.accent, Transparency = 0 }, rip)

	local demoTok = 0
	local function demo(target)
		demoTok += 1
		local my = demoTok
		cur.Visible = false
		rip.Visible = false
		if not target then return end
		task.spawn(function()
			while demoTok == my and not dead and root.Parent do
				if not (target.Parent and target.AbsoluteSize.X > 0) then break end
				local c = target.AbsolutePosition + target.AbsoluteSize / 2 - spot.AbsolutePosition
				cur.Position = UDim2.fromOffset(c.X + 90, c.Y + 70)
				cur.Size = UDim2.fromOffset(26, 26)
				cur.BackgroundTransparency = 1
				cur.Visible = true
				tw(cur, 0.25, { BackgroundTransparency = 0.05 })
				tw(cur, 0.8, { Position = UDim2.fromOffset(c.X, c.Y) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				task.wait(0.9)
				if demoTok ~= my then break end
				tw(cur, 0.1, { Size = UDim2.fromOffset(18, 18) })
				rip.Position = UDim2.fromOffset(c.X, c.Y)
				rip.Size = UDim2.fromOffset(12, 12)
				ripS.Transparency = 0
				rip.Visible = true
				tw(rip, 0.6, { Size = UDim2.fromOffset(84, 84) })
				tw(ripS, 0.6, { Transparency = 1 })
				task.wait(0.12)
				tw(cur, 0.12, { Size = UDim2.fromOffset(26, 26) })
				task.wait(0.8)
				if demoTok ~= my then break end
				tw(cur, 0.25, { BackgroundTransparency = 1 })
				task.wait(1.1)
			end
			if demoTok == my then cur.Visible = false rip.Visible = false end
		end)
	end

	-- ---------------------------------------------------------------- instruction card
	local cw = math.clamp(math.floor(V0.X * 0.46), 270, 380)
	local card = mk("Frame", { Name = "Card", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(V0.X / 2, V0.Y + 60), Size = UDim2.fromOffset(cw, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 120 }, root)
	round(card, 18)
	mk("UIGradient", { Rotation = 90, Color = ColorSequence.new(th.card:Lerp(th.accent, 0.12), th.bg) }, card)
	mk("UIStroke", { Thickness = 1.5, Color = th.accent, Transparency = 0.3 }, card)
	pad(card, 16, 14, 16, 14)
	mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, card)
	local function txt(props)
		props.BackgroundTransparency = 1
		props.ZIndex = 121
		props.TextXAlignment = Enum.TextXAlignment.Left
		props.TextWrapped = true
		props.Size = UDim2.new(1, 0, 0, 0)
		props.AutomaticSize = Enum.AutomaticSize.Y
		return mk("TextLabel", props, card)
	end
	local bar = mk("Frame", { Size = UDim2.fromOffset(38, 4), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, LayoutOrder = 1, ZIndex = 121 }, card)
	round(bar, 2)
	mk("UIGradient", { Color = ColorSequence.new(th.accent, th.accent2) }, bar)
	local badge = txt({ LayoutOrder = 2, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = th.accent, Text = "" })
	local titleL = txt({ LayoutOrder = 3, Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = th.text, Text = "" })
	local bodyL = txt({ LayoutOrder = 4, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = th.muted, Text = "" })
	local pipRow = mk("Frame", { Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1, LayoutOrder = 5, ZIndex = 121 }, card)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, pipRow)
	local pips = {}
	for k = 1, #STEPS do
		local pf = mk("Frame", { Size = UDim2.fromOffset(6, 6), BackgroundColor3 = th.stroke, BorderSizePixel = 0, ZIndex = 122, LayoutOrder = k }, pipRow)
		round(pf, 3)
		pips[k] = pf
	end
	local btnRow = mk("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, LayoutOrder = 6, ZIndex = 121 }, card)
	local function mkBtn(text, primary, w, anchorX, posX)
		local b = mk("TextButton", {
			Size = UDim2.fromOffset(w, 36), AnchorPoint = Vector2.new(anchorX, 0), Position = UDim2.new(anchorX, posX, 0, 0),
			BackgroundColor3 = primary and Color3.new(1, 1, 1) or th.bg, BackgroundTransparency = primary and 0 or 0.1,
			AutoButtonColor = false, Text = text, Font = Enum.Font.GothamBold, TextSize = 13,
			TextColor3 = primary and onAccent or th.text, BorderSizePixel = 0, ZIndex = 122,
		}, btnRow)
		round(b, 10)
		if primary then mk("UIGradient", { Color = ColorSequence.new(th.accent, th.accent2), Rotation = 20 }, b) end
		return b
	end
	local skipB = mk("TextButton", { Size = UDim2.fromOffset(60, 36), BackgroundTransparency = 1, Text = "Skip", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = th.muted, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 122 }, btnRow)
	local nextB = mkBtn("Next", true, 98, 1, 0)
	local backB = mkBtn("Back", false, 76, 1, -106)

	-- ---------------------------------------------------------------- flow
	local idx, busy, finished, firstShow, trackTok = 0, false, false, true, 0
	local function finish(skipped)
		if finished then return end
		finished = true
		demoTok += 1
		trackTok += 1
		restoreExternal()
		pcall(UI.hud, false) -- Roblox + game HUD back
		pcall(function() gui.ScreenInsets = prevInsets end)
		cfg.tutorialV2 = true
		cfgSave()
		tw(blur, 0.5, { Size = 0 })
		for _, f in ipairs({ dT, dB, dL, dR }) do tw(f, 0.4, { BackgroundTransparency = 1 }) end
		ring.Visible = false
		cur.Visible = false
		rip.Visible = false
		tw(card, 0.45, { Position = UDim2.fromOffset(VP().X / 2, VP().Y + 80) })
		pcall(UI.showTab, "Home")
		task.delay(0.6, function()
			pcall(function() root:Destroy() end)
			pcall(function() if spot ~= root then spot:Destroy() end end)
			pcall(function() blur:Destroy() end)
		end)
		if not skipped then toast("ok", "Setup Complete", "Select a target in Troll to begin", { silent = true }) end
	end

	-- smooth helpers: the ring shrinks away instead of popping, and the hole closes to a point while a page switches
	local ringTok = 0
	local function hideRing()
		if not ring.Visible then return end
		ringTok += 1
		local my = ringTok
		local p, sz = ring.Position, ring.Size
		tw(ring, 0.3, { Position = UDim2.fromOffset(p.X.Offset + sz.X.Offset / 2, p.Y.Offset + sz.Y.Offset / 2), Size = UDim2.fromOffset(0, 0) })
		task.delay(0.32, function() if ringTok == my then ring.Visible = false end end)
	end
	local function collapse()
		hideRing()
		local V = (spot ~= root and spot.AbsoluteSize.X > 10) and spot.AbsoluteSize or VP()
		setHole(V.X / 2, V.Y / 2, 0, 0)
	end

	local function show(i)
		idx = i
		local s = STEPS[i]
		demoTok += 1
		trackTok += 1 -- stop the old spotlight tracker right away so it can't chase a page that is leaving
		cur.Visible = false
		rip.Visible = false
		if not firstShow then -- fade the old text out before swapping it
			for _, l in ipairs({ badge, titleL, bodyL }) do tw(l, 0.1, { TextTransparency = 1 }) end
			task.wait(0.1)
			if finished or dead then return end
		end
		badge.Text = string.format("STEP %d / %d", i, #STEPS)
		titleL.Text = s.title
		bodyL.Text = s.body
		for _, l in ipairs({ badge, titleL, bodyL }) do
			l.TextTransparency = 1
			tw(l, 0.3, { TextTransparency = 0 })
		end
		for k, pf in ipairs(pips) do
			tw(pf, 0.3, { Size = UDim2.fromOffset(k == i and 18 or 6, 6), BackgroundColor3 = k == i and th.accent or th.stroke })
		end
		backB.Visible = i > 1
		skipB.Visible = i < #STEPS
		nextB.Text = (i == #STEPS) and "Finish" or "Next"
		if s.tab and UI.curTab ~= s.tab then
			collapse() -- spotlight closes while the old page leaves, then opens on the new target
			UI.showTab(s.tab)
			task.wait(1.1) -- the page's widgets fly in, measure after they settle
		end
		if finished or dead then return end
		local target = s.find and s.find()
		if target and not (target.Parent and isShown(target)) then target = nil end
		local focus = target
		if not focus and s.page and pages[s.tab] then focus = pages[s.tab] end
		if focus then -- widgets are still flying in: wait until the control stops moving
			local lastP, lastS
			for _ = 1, 14 do
				local p, sz = focus.AbsolutePosition, focus.AbsoluteSize
				if lastP and (p - lastP).Magnitude < 0.5 and (sz - lastS).Magnitude < 0.5 then break end
				lastP, lastS = p, sz
				task.wait(0.15)
			end
		end
		local V = VP()
		local hy, hh, lastR
		local function place()
			if not (focus and focus.Parent) then return end
			local pd = (target and 7) or 0
			V = VP()
			syncSpot()
			local Vs = (spot ~= root and spot.AbsoluteSize.X > 10) and spot.AbsoluteSize or V
			local fp, fs = focus.AbsolutePosition - spot.AbsolutePosition, focus.AbsoluteSize
			local x1 = math.clamp(fp.X - pd, 0, Vs.X)
			local y1 = math.clamp(fp.Y - pd, 0, Vs.Y)
			local x2 = math.clamp(fp.X + fs.X + pd, 0, Vs.X)
			local y2 = math.clamp(fp.Y + fs.Y + pd, 0, Vs.Y)
			x1, y1, x2, y2 = math.floor(x1), math.floor(y1), math.ceil(x2), math.ceil(y2) -- whole pixels: the four dim panels share exact edges, no hairline flicker
			hy, hh = y1, y2 - y1
			if lastR and math.abs(lastR[1] - x1) < 2 and math.abs(lastR[2] - y1) < 2 and math.abs(lastR[3] - x2) < 2 and math.abs(lastR[4] - y2) < 2 then
				return -- nothing really moved: don't restart the tweens every tick
			end
			lastR = { x1, y1, x2, y2 }
			setHole(x1, y1, x2 - x1, y2 - y1)
			if target then
				ringTok += 1 -- cancel a pending hide
				if not ring.Visible then -- grow out of the target's centre instead of popping in
					ring.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
					ring.Size = UDim2.fromOffset(0, 0)
					ring.Visible = true
				end
				tw(ring, 0.4, { Position = UDim2.fromOffset(x1, y1), Size = UDim2.fromOffset(x2 - x1, y2 - y1) }) -- same duration as the hole so they move as one
			else
				hideRing()
			end
		end
		if focus then
			place()
			trackTok += 1
			local myT = trackTok
			task.spawn(function() -- the spotlight follows the control if the layout shifts
				while trackTok == myT and not finished and not dead do
					task.wait(0.25)
					pcall(place)
				end
			end)
		else
			trackTok += 1
			collapse()
		end
		task.wait(0.06) -- card auto-sizes to the new text
		local ch = card.AbsoluteSize.Y
		local cy
		if not hy then
			cy = (V.Y - ch) / 2
		elseif hh > V.Y * 0.6 then
			cy = V.Y - ch - 14
		elseif hy + hh / 2 > V.Y * 0.5 then
			cy = 14
		else
			cy = V.Y - ch - 14
		end
		cy = math.max(8, cy)
		if firstShow then
			firstShow = false
			card.Position = UDim2.fromOffset(V.X / 2, V.Y + 60)
		end
		tw(card, 0.5, { Position = UDim2.fromOffset(V.X / 2, cy) })
		demo((s.tap and s.tap()) or target)
	end

	local function go(i)
		if busy or finished then return end
		busy = true
		local ok = pcall(show, i)
		busy = false
		if not ok then finish(true) end
	end

	nextB.Activated:Connect(function()
		pcall(haptic, 0.25)
		if idx >= #STEPS then finish(false) else go(idx + 1) end
	end)
	backB.Activated:Connect(function()
		pcall(haptic, 0.2)
		if idx > 1 then go(idx - 1) end
	end)
	skipB.Activated:Connect(function()
		pcall(haptic, 0.2)
		finish(true)
	end)

	task.spawn(function() pcall(deepScan) pcall(sweep) end)
	task.spawn(function() -- keep them hidden if something re-enables itself
		local n = 0
		while not finished and not dead do
			task.wait(0.4)
			if finished or dead then break end -- never sweep after the restore
			sweep()
			n += 1
			if n % 12 == 0 then pcall(deepScan) end
		end
	end)
	go(1)
end

-- ============================================================================
-- 27. BOOT
-- ============================================================================
if not cfg.opV2 then cfg.opacity = 0.92 cfg.opV2 = true cfgSave() end
setAntiAfk(cfg.antiAfk)
cfg.autoExec = false
-- who is this: first launch time + launch count live in the config file (that file is the user's identity on this device)
cfg.firstRun = (cfg.firstRun and cfg.firstRun > 0) and cfg.firstRun or os.time()
cfg.runs = (cfg.runs or 0) + 1
keep(LP.OnTeleport:Connect(function() if cfg.autoLaunch ~= false then AutoExec.queue() end end))
if cfg.autoLaunch ~= false then
	task.spawn(function()
		AutoExec.apply(true)
		if AutoExec.paint then AutoExec.paint() end
		if not cfg.alNotified and (AutoExec.queued or AutoExec.where) then
			cfg.alNotified = true
			cfgSave()
			task.wait(5)
			if not dead then toast("info", "Auto-launch is on", "GenX relaunches itself in Dreamville. Turn it off in Settings.") end
		end
	end)
end
cfgSave()
applyTheme(cfg.theme, false)
applyOpacity()
applyScale()
refreshVolume()

-- full teardown: effects first (LIFO), then connections, then instances
local function stopAll()
	if dead then return end
	dead = true
	for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for _, i in ipairs(insts) do pcall(function() i:Destroy() end) end
	if G.GENX_DV_STOP == stopAll then G.GENX_DV_STOP = nil end
	log("info", "stopped")
end
G.GENX_DV_STOP = stopAll

-- billboard.lua uses this to show "Protected by GenX" / Anti Troll messages in Dreamville's own notifications
G.GENX_NOTIFY = function(kind, title, body) pcall(toast, kind, title, body) end
onClean(function() G.GENX_NOTIFY = nil end)

-- placeholder: billboard / Anti Outfit Stealer backend removed (no remote loader)

-- the loader flips GENX_SESSION_ENDED when the session dies; only react to a fresh flip
task.spawn(function()
	local armed = not G.GENX_SESSION_ENDED
	while not dead do
		local v = G.GENX_SESSION_ENDED
		if not v then armed = true end
		if v and armed then
			toast("warn", "Session Ended", "Shutting down")
			task.wait(1.8)
			stopAll()
			return
		end
		task.wait(1)
	end
end)

task.spawn(function()
	task.wait(0.2) -- let the first layout pass run so the intro can read real positions
	if dead then return end
	-- relaunched by the teleport loader: stay closed (no auto-open, no blur, no tutorial)
	-- so the game's own join / updates screen stays fully usable - GenX waits on its button
	local relaunched = G.GX_RELAUNCHED == true
	G.GX_RELAUNCHED = nil
	if relaunched then
		toast("ok", "GenX", "Relaunched - tap the GenX button when you're in", { silent = true })
	else
		UI.firstOpen()
	end
	log("ok", "ready")
	-- first-run walkthrough: brand-new users only, once
	CAP.alwaysTutorial = false -- the tutorial only shows for brand-new users, once
	if not relaunched and (CAP.alwaysTutorial or cfg.tutorialV2 ~= true) then
		if CAP.alwaysTutorial or not G.GENX_DV_TUT_SEEN then
			G.GENX_DV_TUT_SEEN = true
			cfg.tutorialV2 = true -- remembered right away, even if the game is closed mid-tutorial
			cfgSave()
			task.spawn(function()
				local ok, e = pcall(UI.tutorial)
				if not ok then
					log("fail", "tutorial error: " .. tostring(e))
					pcall(function() local f = gui:FindFirstChild("Tutorial") if f then f:Destroy() end end)
					pcall(function() local w = UI.winHolder and UI.winHolder:FindFirstChild("TutSpot") if w then w:Destroy() end end)
					pcall(function() local b = Lighting:FindFirstChild("GenXTutBlur") if b then b:Destroy() end end)
					if UI.tutRestore then pcall(UI.tutRestore) end
					pcall(UI.hud, false)
					cfg.tutorialV2 = true
					cfgSave()
				end
			end)
		end
	end
end)
