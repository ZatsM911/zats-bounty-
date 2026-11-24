-- Bounty Checker v6 (Blox Fruits) - live session status to a Discord webhook
-- Fully local: no loadstring, no remote code. Only sends the stats shown in the embed.

repeat task.wait() until game:IsLoaded()

if _G.__BountyCheckerRunning then
    warn("[BountyChecker] Already running. Call _G.BountyChecker.Stop() first to restart.")
    return
end

----------------------------------------------------------------
-- Config (read from the loader's _G.BountyConfig, with defaults)
----------------------------------------------------------------
local User = (_G.BountyConfig or {})["Webhook"] or {}

local function pickStyle(value)
    value = tostring(value or "both"):lower()
    if value == "full" or value == "short" then
        return value
    end
    return "both"
end

local Config = {
    Enabled       = User["Enabled"] ~= false,
    Webhook       = tostring(User["Url Webhook"] or ""),
    DiscordId     = tostring(User["Discord ID"] or ""),
    Interval      = math.max(tonumber(User["Interval"]) or 60, 10),       -- seconds, min 10
    EditMessage   = User["Edit Message"] ~= false,     -- edit one message instead of posting new ones
    Ping          = User["Ping"] ~= false,             -- mention you (first message only when editing)
    NumberStyle   = pickStyle(User["Number Style"]),   -- "both" (6,158,753 (6.16M)), "full" or "short"
    Ansi          = User["Ansi Colors"] ~= false,      -- colored text in code blocks
    ShowExtras    = User["Show Extras"] ~= false,      -- Level / Beli / server info
    ShowTrend     = User["Show Trend"] ~= false,       -- sparkline of recent bounty
    TrendPoints   = math.clamp(tonumber(User["Trend Points"]) or 20, 5, 30),
    EventCount    = math.clamp(tonumber(User["Recent Events"]) or 5, 0, 8), -- 0 disables the feed
    Persist       = User["Persist Session"] ~= false,  -- keep stats across server hops (needs writefile)
    ResumeWindow  = tonumber(User["Resume Window"]) or 600,  -- seconds a saved session stays valid
    MinKillGain   = tonumber(User["Min Kill Gain"]) or 1,    -- min bounty gain counted as a kill
    AlertBounty   = tonumber(User["Alert Bounty"]),          -- optional goal: progress bar, ETA, one-time ping
    IdleMinutes   = math.max(tonumber(User["Idle Minutes"]) or 10, 1), -- no bounty change for this long = idle
    IdleAlert     = User["Idle Alert"] == true,        -- ping once when idle (off by default)
    BotName       = tostring(User["Bot Name"] or "Bounty Checker"),
    BotAvatar     = tostring(User["Bot Avatar"] or ""),
    Version       = "v6",
}

if not Config.Enabled then return end

if Config.Webhook:match("^https://[%w%.]*discord[%w%.]*/api/[v%d/]*webhooks/%d+/[%w%-_]+") == nil then
    warn("[BountyChecker] Missing or invalid webhook URL in _G.BountyConfig.")
    return
end

local baseUrl = Config.Webhook:gsub("%?.*$", "")

----------------------------------------------------------------
-- Services / executor functions
----------------------------------------------------------------
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

local httpRequest = (syn and syn.request) or http_request or request or (http and http.request)
if not httpRequest then
    warn("[BountyChecker] No HTTP request function found in this executor.")
    return
end

local hasFS = type(writefile) == "function" and type(readfile) == "function"

_G.__BountyCheckerRunning = true
local running = true

----------------------------------------------------------------
-- Number and text helpers
----------------------------------------------------------------
local function safeValue(parent, ...)
    local node = parent
    for _, name in ipairs({ ... }) do
        node = node and node:FindFirstChild(name)
    end
    return node and node.Value
end

local function findBountyValue()
    local ls = player:FindFirstChild("leaderstats")
    return ls and (ls:FindFirstChild("Bounty/Honor") or ls:FindFirstChild("Bounty"))
end

local function getBounty()
    local v = findBountyValue()
    return v and tonumber(v.Value) or 0
end

-- 6158753 -> "6,158,753"
local function commify(n)
    local sign = n < 0 and "-" or ""
    local s = tostring(math.floor(math.abs(n)))
    local out = ""
    while #s > 3 do
        out = "," .. s:sub(-3) .. out
        s = s:sub(1, -4)
    end
    return sign .. s .. out
end

-- 6158753 -> "6.16M"
local function compact(n)
    local abs = math.abs(n)
    local sign = n < 0 and "-" or ""
    local function fmt(value, suffix)
        local s = string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", "")
        return sign .. s .. suffix
    end
    if abs >= 1e9 then
        return fmt(abs / 1e9, "B")
    elseif abs >= 1e6 then
        return fmt(abs / 1e6, "M")
    elseif abs >= 1e3 then
        return fmt(abs / 1e3, "K")
    end
    return sign .. tostring(math.floor(abs))
end

local function signed(n)
    return (n >= 0 and "+" or "-") .. commify(math.abs(n))
end

local function signedShort(n)
    return (n >= 0 and "+" or "") .. compact(n)
end

-- Number for small fields: short unless the style is "full"
local function small(n)
    if Config.NumberStyle == "full" then
        return commify(n)
    end
    return compact(n)
end

local function padLeft(s, width)
    return string.rep(" ", math.max(width - #s, 0)) .. s
end

local function padRight(s, width)
    return s .. string.rep(" ", math.max(width - #s, 0))
end

local function formatTime(total)
    total = math.floor(total)
    return string.format("%dh %02dm %02ds", math.floor(total / 3600), math.floor((total % 3600) / 60), total % 60)
end

-- Progress bar, e.g. 0.5 -> ██████░░░░░░
local function bar(frac, len)
    len = len or 14
    frac = math.clamp(frac, 0, 1)
    local filled = math.floor(frac * len + 0.5)
    return string.rep(utf8.char(0x2588), filled) .. string.rep(utf8.char(0x2591), len - filled)
end

-- Sparkline from a list of numbers, e.g. ▁▂▄▅▇
local function sparkline(values)
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(values) do
        lo = math.min(lo, v)
        hi = math.max(hi, v)
    end
    local out = {}
    for _, v in ipairs(values) do
        local idx = 4
        if hi > lo then
            idx = math.floor((v - lo) / (hi - lo) * 7 + 0.5) + 1
        end
        out[#out + 1] = utf8.char(0x2580 + idx)
    end
    return table.concat(out), lo, hi
end

----------------------------------------------------------------
-- ANSI colored code blocks (Discord renders ```ansi)
----------------------------------------------------------------
local ESC = "\u{1B}["
local C = {
    gray = "0;30", red = "0;31", green = "0;32", yellow = "0;33",
    cyan = "0;36", white = "1;37",
}

local function colorize(text, color)
    if not Config.Ansi then
        return text
    end
    return ESC .. color .. "m" .. text .. ESC .. "0m"
end

local function block(lines)
    return "```" .. (Config.Ansi and "ansi" or "") .. "\n" .. table.concat(lines, "\n") .. "\n```"
end

local LABEL_W = 7
local function row(label, body)
    return colorize(padRight(label, LABEL_W), C.gray) .. body
end

local function signColor(n)
    if n > 0 then
        return C.green
    elseif n < 0 then
        return C.red
    end
    return C.yellow
end

----------------------------------------------------------------
-- Session state (saved to disk so server hops do not reset it)
----------------------------------------------------------------
local SESSION_FILE = "BountyChecker_" .. player.UserId .. ".json"

local session = {
    startTime = os.time(),
    startBounty = nil,
    peak = 0,
    kills = 0,
    deaths = 0,
    lastKill = 0,
    hops = 0,
    jobId = game.JobId,
    messageId = nil,
    alerted = false,
    history = {},  -- list of { timestamp, bounty }
    events = {},   -- list of { ts = timestamp, text = string }
    lastSeen = os.time(),
}

local function saveSession()
    if not (Config.Persist and hasFS) then return end
    session.lastSeen = os.time()
    session.jobId = game.JobId
    pcall(function()
        writefile(SESSION_FILE, HttpService:JSONEncode(session))
    end)
end

-- Returns resumed, hopped
local function loadSession()
    if not (Config.Persist and hasFS) then return false, false end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(SESSION_FILE))
    end)
    if not (ok and type(data) == "table" and tonumber(data.lastSeen)
        and os.time() - data.lastSeen <= Config.ResumeWindow) then
        return false, false
    end

    session.startTime = tonumber(data.startTime) or session.startTime
    session.startBounty = tonumber(data.startBounty)
    session.peak = tonumber(data.peak) or 0
    session.kills = tonumber(data.kills) or 0
    session.deaths = tonumber(data.deaths) or 0
    session.lastKill = tonumber(data.lastKill) or 0
    session.hops = tonumber(data.hops) or 0
    session.messageId = data.messageId
    session.alerted = data.alerted == true

    if type(data.history) == "table" then
        for _, p in ipairs(data.history) do
            if type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) then
                session.history[#session.history + 1] = { tonumber(p[1]), tonumber(p[2]) }
            end
        end
    end
    if type(data.events) == "table" then
        for _, e in ipairs(data.events) do
            if type(e) == "table" and tonumber(e.ts) and type(e.text) == "string" then
                session.events[#session.events + 1] = { ts = tonumber(e.ts), text = e.text }
            end
        end
    end

    local hopped = data.jobId ~= game.JobId
    if hopped then
        session.hops += 1
    end
    return true, hopped
end

local function pushHistory(value)
    table.insert(session.history, { os.time(), value })
    while #session.history > Config.TrendPoints do
        table.remove(session.history, 1)
    end
end

local function pushEvent(text)
    if Config.EventCount <= 0 then return end
    table.insert(session.events, { ts = os.time(), text = text })
    while #session.events > Config.EventCount do
        table.remove(session.events, 1)
    end
end

-- Average bounty per second over the stored history window
local function recentRate()
    local h = session.history
    if #h < 3 then return nil end
    local dt = h[#h][1] - h[1][1]
    if dt < 120 then return nil end
    return (h[#h][2] - h[1][2]) / dt
end

----------------------------------------------------------------
-- Tracking: bounty (events), deaths, idle detection
----------------------------------------------------------------
player:WaitForChild("leaderstats", 30)
local resumed, hopped = loadSession()

local lastBounty = getBounty()
local lastChangeTime = os.time()
local idleAlerted = false
local boundValue, bountyConn, humanoidConn, charConn

local function onBountyChanged(newValue)
    newValue = tonumber(newValue) or 0
    local gain = newValue - lastBounty
    if gain ~= 0 then
        lastChangeTime = os.time()
        idleAlerted = false
    end
    if gain >= Config.MinKillGain then
        session.kills += 1
        session.lastKill = gain
        pushEvent("\u{2694}\u{FE0F} Kill " .. signed(gain))
    end
    if newValue > session.peak then
        session.peak = newValue
    end
    lastBounty = newValue
end

local function hookBounty()
    local v = findBountyValue()
    if v and v ~= boundValue then
        if bountyConn then
            bountyConn:Disconnect()
        end
        boundValue = v
        lastBounty = tonumber(v.Value) or 0
        bountyConn = v:GetPropertyChangedSignal("Value"):Connect(function()
            onBountyChanged(v.Value)
        end)
    end
end

local function hookCharacter(char)
    if humanoidConn then
        humanoidConn:Disconnect()
        humanoidConn = nil
    end
    local hum = char:WaitForChild("Humanoid", 10)
    if hum then
        humanoidConn = hum.Died:Connect(function()
            session.deaths += 1
            pushEvent("\u{1F480} Died")
        end)
    end
end

hookBounty()
if not session.startBounty then
    session.startBounty = getBounty()
end
session.peak = math.max(session.peak, getBounty())

if not resumed then
    pushEvent("\u{25B6}\u{FE0F} Session started")
elseif hopped then
    pushEvent("\u{1F501} Server hop")
end

if player.Character then
    task.spawn(hookCharacter, player.Character)
end
charConn = player.CharacterAdded:Connect(function(char)
    task.spawn(hookCharacter, char)
end)

-- Re-hook if the game rebuilds leaderstats
task.spawn(function()
    while running do
        hookBounty()
        task.wait(5)
    end
end)

----------------------------------------------------------------
-- Discord delivery (edit in place, retry, rate-limit aware)
----------------------------------------------------------------
local function request(method, url, body)
    local ok, res = pcall(httpRequest, {
        Url = url,
        Method = method,
        Headers = { ["Content-Type"] = "application/json" },
        Body = body and HttpService:JSONEncode(body) or nil,
    })
    if not ok then
        return nil, tostring(res)
    end
    return res
end

local function decodeBody(res)
    local ok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "{}")
    return ok and type(data) == "table" and data or {}
end

-- Message edits do not accept a new identity, so drop those fields
local function stripIdentity(payload)
    local copy = {}
    for key, value in pairs(payload) do
        if key ~= "username" and key ~= "avatar_url" then
            copy[key] = value
        end
    end
    return copy
end

-- Sends a payload. When edit is true and a message exists, edits it instead.
local function deliver(payload, edit)
    for _ = 1, 3 do
        local res, err
        if edit and session.messageId then
            res, err = request("PATCH", baseUrl .. "/messages/" .. session.messageId, stripIdentity(payload))
        else
            res, err = request("POST", baseUrl .. "?wait=true", payload)
        end

        if not res then
            warn("[BountyChecker] Request failed: " .. tostring(err))
            task.wait(5)
        else
            local status = res.StatusCode or res.Status
            if status == 200 or status == 204 then
                if edit and not session.messageId then
                    local data = decodeBody(res)
                    if data.id then
                        session.messageId = data.id
                    end
                end
                return true
            elseif status == 404 and edit and session.messageId then
                session.messageId = nil -- message was deleted, send a fresh one
            elseif status == 429 then
                local retry = tonumber(decodeBody(res).retry_after) or 5
                task.wait(math.min(retry + 0.5, 30))
            else
                warn("[BountyChecker] Discord returned HTTP " .. tostring(status))
                return false
            end
        end
    end
    return false
end

----------------------------------------------------------------
-- Embed
----------------------------------------------------------------
local function mentionText()
    if Config.Ping and Config.DiscordId ~= "" then
        return "<@" .. Config.DiscordId .. ">"
    end
    return ""
end

local function allowedMentions()
    if Config.DiscordId ~= "" then
        return { users = { Config.DiscordId } }
    end
    return { parse = {} }
end

local function field(name, value, inline)
    return { name = name, value = value, inline = inline == true }
end

local function avatarUrl()
    return "https://www.roblox.com/headshot-thumbnail/image?userId="
        .. player.UserId .. "&width=150&height=150&format=png"
end

local function withIdentity(payload)
    payload.username = Config.BotName
    if Config.BotAvatar ~= "" then
        payload.avatar_url = Config.BotAvatar
    end
    return payload
end

local STATUS_TEXT = {
    running = "\u{1F7E2} Running",
    idle    = "\u{1F7E1} Idle",
    stopped = "\u{26AB} Stopped",
}

-- Aligned number table: Bounty / Gain / Peak / Rate / Recent
local function overviewBlock(current, change, elapsed)
    local rows = {
        { "Bounty", commify(current), compact(current), C.white },
        { "Gain", signed(change), signedShort(change), signColor(change) },
        { "Peak", commify(session.peak), compact(session.peak), C.cyan },
    }

    if elapsed >= 60 then
        local perHour = change / elapsed * 3600
        rows[#rows + 1] = { "Rate", signed(perHour) .. "/hr", signedShort(perHour) .. "/hr", signColor(perHour) }
    end

    local recent = recentRate()
    if recent then
        local perHour = recent * 3600
        rows[#rows + 1] = { "Recent", signed(perHour) .. "/hr", signedShort(perHour) .. "/hr", signColor(perHour) }
    end

    local widthFull, widthShort = 0, 0
    for _, r in ipairs(rows) do
        widthFull = math.max(widthFull, #r[2])
        widthShort = math.max(widthShort, #r[3])
    end

    local lines = {}
    for _, r in ipairs(rows) do
        local body
        if Config.NumberStyle == "full" then
            body = colorize(padLeft(r[2], widthFull), r[4])
        elseif Config.NumberStyle == "short" then
            body = colorize(padLeft(r[3], widthShort), r[4])
        else
            body = colorize(padLeft(r[2], widthFull), r[4]) .. colorize("  (" .. r[3] .. ")", C.gray)
        end
        lines[#lines + 1] = row(r[1], body)
    end
    return block(lines)
end

local function buildPayload(status)
    status = status or "running"
    local now = os.time()
    local current = getBounty()
    local change = current - session.startBounty
    local elapsed = now - session.startTime
    local idleFor = now - lastChangeTime
    local team = player.Team and player.Team.Name or "None"

    if status == "running" and idleFor >= Config.IdleMinutes * 60 then
        status = "idle"
    end

    local statusLine = STATUS_TEXT[status]
    if status == "idle" then
        statusLine = statusLine .. " (no change for " .. math.floor(idleFor / 60) .. "m)"
    end

    local description = string.format(
        "%s\n\u{1F552} Started <t:%d:R>  \u{2022}  Updated <t:%d:R>",
        statusLine, session.startTime, now
    )

    local kd = session.kills / math.max(session.deaths, 1)
    local kdColor = (session.deaths == 0 or kd >= 1) and C.green or C.red

    local combat = {
        row("Kills", colorize(tostring(session.kills), C.green)),
        row("Deaths", colorize(tostring(session.deaths), C.red)),
        row("K/D", colorize(string.format("%.2f", kd), kdColor)),
        row("Last", colorize(session.kills > 0 and signedShort(session.lastKill) or "-", C.cyan)),
    }

    local sessionLines = {
        row("Time", colorize(formatTime(elapsed), C.white)),
        row("Team", colorize(team, C.white)),
        row("Server", colorize(#Players:GetPlayers() .. "/" .. Players.MaxPlayers, C.white)),
    }
    if session.hops > 0 then
        sessionLines[#sessionLines + 1] = row("Hops", colorize(tostring(session.hops), C.white))
    end

    local fields = {
        field("\u{1F4CA} Overview", overviewBlock(current, change, elapsed), false),
        field("\u{2694}\u{FE0F} Combat", block(combat), true),
        field("\u{1F9ED} Session", block(sessionLines), true),
    }

    if Config.ShowExtras then
        local level = safeValue(player, "Data", "Level")
        local beli = safeValue(player, "Data", "Beli")
        local account = {}
        if level then
            account[#account + 1] = row("Level", colorize(commify(level), C.white))
        end
        if beli then
            account[#account + 1] = row("Beli", colorize(small(beli), C.yellow))
        end
        if #account > 0 then
            table.insert(fields, field("\u{1F3AE} Account", block(account), true))
        end
    end

    if Config.AlertBounty then
        local frac = current / Config.AlertBounty
        local barColor = frac >= 1 and C.green or C.yellow
        local goalLines = {
            colorize(bar(frac, 14), barColor) .. colorize(string.format("  %.1f%%", math.clamp(frac, 0, 1) * 100), C.white),
        }

        -- ETA from this session's average rate
        local remaining = Config.AlertBounty - current
        if remaining > 0 and change > 0 and elapsed >= 300 then
            local eta = remaining / (change / elapsed)
            local etaText = eta > 360000 and "100h+" or formatTime(eta)
            goalLines[#goalLines + 1] = colorize("ETA ", C.gray) .. colorize(etaText, C.white)
        end

        table.insert(fields, field("\u{1F3C1} Goal: " .. small(Config.AlertBounty), block(goalLines), false))
    end

    if Config.ShowTrend and #session.history >= 2 then
        local values = {}
        for i, p in ipairs(session.history) do
            values[i] = p[2]
        end
        local line, lo, hi = sparkline(values)
        local trend = {
            colorize(line, C.cyan),
            colorize("low ", C.gray) .. colorize(small(lo), C.white)
                .. colorize("   high ", C.gray) .. colorize(small(hi), C.white),
        }
        table.insert(fields, field("\u{1F4C9} Trend (last " .. #values .. " updates)", block(trend), false))
    end

    if Config.EventCount > 0 and #session.events > 0 then
        local feed = {}
        for i = #session.events, 1, -1 do
            local e = session.events[i]
            feed[#feed + 1] = e.text .. " \u{2022} <t:" .. e.ts .. ":R>"
        end
        table.insert(fields, field("\u{1F4DC} Recent Events", table.concat(feed, "\n"), false))
    end

    -- Green: gaining, red: losing, gold: flat, orange: idle, gray: stopped
    local color = 16766720
    if status == "stopped" then
        color = 9807270
    elseif status == "idle" then
        color = 15105570
    elseif change > 0 then
        color = 5763719
    elseif change < 0 then
        color = 15548997
    end

    return withIdentity({
        content = mentionText(),
        allowed_mentions = allowedMentions(),
        embeds = {{
            author = {
                name = player.DisplayName .. " (@" .. player.Name .. ")",
                icon_url = avatarUrl(),
            },
            title = "Bounty Session",
            description = description,
            color = color,
            fields = fields,
            thumbnail = { url = avatarUrl() },
            footer = {
                text = "Bounty Checker " .. Config.Version .. "  |  refreshes every " .. Config.Interval .. "s",
                icon_url = avatarUrl(),
            },
            timestamp = DateTime.now():ToIsoDate(),
        }},
    })
end

local function sendAlert(title, text, color)
    request("POST", baseUrl, withIdentity({
        content = Config.DiscordId ~= "" and ("<@" .. Config.DiscordId .. ">") or "",
        allowed_mentions = allowedMentions(),
        embeds = {{
            title = title,
            description = text,
            color = color,
            thumbnail = { url = avatarUrl() },
            timestamp = DateTime.now():ToIsoDate(),
        }},
    }))
end

local function checkAlerts()
    local current = getBounty()

    if Config.AlertBounty and not session.alerted and current >= Config.AlertBounty then
        session.alerted = true
        pushEvent("\u{1F3C6} Goal reached")
        sendAlert(
            "\u{1F3C6} Goal reached",
            player.Name .. " reached `" .. commify(current) .. "` bounty (" .. compact(current) .. ").",
            16766720
        )
    end

    local idleFor = os.time() - lastChangeTime
    if Config.IdleAlert and not idleAlerted and idleFor >= Config.IdleMinutes * 60 then
        idleAlerted = true
        pushEvent("\u{1F7E1} Went idle")
        sendAlert(
            "\u{1F7E1} Bounty idle",
            player.Name .. " has had no bounty change for " .. math.floor(idleFor / 60) .. " minutes.",
            15105570
        )
    end
end

----------------------------------------------------------------
-- Main loop
----------------------------------------------------------------
local function updateOnce()
    pushHistory(getBounty())
    local sent = deliver(buildPayload("running"), Config.EditMessage)
    checkAlerts()
    saveSession()
    return sent
end

task.spawn(function()
    local failStreak = 0
    while running do
        local ok, result = pcall(updateOnce)

        if ok and result then
            failStreak = 0
        else
            failStreak += 1
            if not ok then
                warn("[BountyChecker] Update failed: " .. tostring(result))
            end
        end

        -- Back off when Discord keeps failing
        local delay = Config.Interval * (failStreak >= 3 and 2 or 1)
        local waited = 0
        while running and waited < delay do
            task.wait(1)
            waited += 1
        end
    end
end)

----------------------------------------------------------------
-- Public control
----------------------------------------------------------------
_G.BountyChecker = {
    -- Force an immediate update
    SendNow = function()
        pcall(updateOnce)
    end,

    -- Restart the session stats (keeps the same Discord message)
    Reset = function()
        local current = getBounty()
        session.startTime = os.time()
        session.startBounty = current
        session.peak = current
        session.kills, session.deaths, session.lastKill, session.hops = 0, 0, 0, 0
        session.history, session.events = {}, {}
        session.alerted = false
        lastChangeTime = os.time()
        pushEvent("\u{1F504} Session reset")
        saveSession()
    end,

    -- Stop(true) also deletes the saved session
    Stop = function(clearSession)
        if not running then return end
        running = false
        _G.__BountyCheckerRunning = nil
        for _, conn in ipairs({ bountyConn, humanoidConn, charConn }) do
            if conn then
                conn:Disconnect()
            end
        end
        pcall(function()
            deliver(buildPayload("stopped"), Config.EditMessage)
        end)
        if clearSession and type(delfile) == "function" then
            pcall(delfile, SESSION_FILE)
        else
            saveSession()
        end
        print("[BountyChecker] Stopped.")
    end,
}
