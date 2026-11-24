-- Bounty Checker v5 (Blox Fruits) - live session status to a Discord webhook
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

local Config = {
    Enabled       = User["Enabled"] ~= false,
    Webhook       = tostring(User["Url Webhook"] or ""),
    DiscordId     = tostring(User["Discord ID"] or ""),
    Interval      = math.max(tonumber(User["Interval"]) or 60, 10),       -- seconds, min 10
    EditMessage   = User["Edit Message"] ~= false,     -- edit one message instead of posting new ones
    Ping          = User["Ping"] ~= false,             -- mention you (first message only when editing)
    ShowExtras    = User["Show Extras"] ~= false,      -- Level / Beli / server info
    ShowTrend     = User["Show Trend"] ~= false,       -- sparkline of recent bounty
    TrendPoints   = math.clamp(tonumber(User["Trend Points"]) or 20, 5, 30),
    Persist       = User["Persist Session"] ~= false,  -- keep stats across server hops (needs writefile)
    ResumeWindow  = tonumber(User["Resume Window"]) or 600,  -- seconds a saved session stays valid
    MinKillGain   = tonumber(User["Min Kill Gain"]) or 1,    -- min bounty gain counted as a kill
    AlertBounty   = tonumber(User["Alert Bounty"]),          -- optional goal: progress bar, ETA, one-time ping
    IdleMinutes   = math.max(tonumber(User["Idle Minutes"]) or 10, 1), -- no bounty change for this long = idle
    IdleAlert     = User["Idle Alert"] == true,        -- ping once when idle (off by default)
    BotName       = tostring(User["Bot Name"] or "Bounty Checker"),
    BotAvatar     = tostring(User["Bot Avatar"] or ""),
    Version       = "v5",
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
-- Helpers
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

local function signed(n)
    return (n >= 0 and "+" or "-") .. commify(math.abs(n))
end

local function formatTime(total)
    total = math.floor(total)
    return string.format("%dh %dm %ds", math.floor(total / 3600), math.floor((total % 3600) / 60), total % 60)
end

local function code(text)
    return "`" .. tostring(text) .. "`"
end

-- Progress bar, e.g. 0.5 -> ██████░░░░░░
local function bar(frac, len)
    len = len or 12
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
    history = {},
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

local function loadSession()
    if not (Config.Persist and hasFS) then return end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(SESSION_FILE))
    end)
    if ok and type(data) == "table" and tonumber(data.lastSeen)
        and os.time() - data.lastSeen <= Config.ResumeWindow then
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
            session.history = data.history
        end
        -- Resuming in a different server counts as a hop
        if data.jobId ~= game.JobId then
            session.hops += 1
        end
    end
end

local function pushHistory(value)
    table.insert(session.history, value)
    while #session.history > Config.TrendPoints do
        table.remove(session.history, 1)
    end
end

----------------------------------------------------------------
-- Tracking: bounty (events), deaths, idle detection
----------------------------------------------------------------
player:WaitForChild("leaderstats", 30)
loadSession()

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
        end)
    end
end

hookBounty()
if not session.startBounty then
    session.startBounty = getBounty()
end
session.peak = math.max(session.peak, getBounty())

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
-- Embeds
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

    local rate = "N/A"
    local perSecond = 0
    if elapsed >= 60 then
        perSecond = change / elapsed
        rate = signed(perSecond * 3600) .. " / hr"
    end

    local statusLine = STATUS_TEXT[status]
    if status == "idle" then
        statusLine = statusLine .. " (no change for " .. math.floor(idleFor / 60) .. "m)"
    end

    local description = string.format(
        "%s\n\u{1F552} Started <t:%d:R>  \u{2022}  Updated <t:%d:R>",
        statusLine, session.startTime, now
    )

    local kd = string.format("%.2f", session.kills / math.max(session.deaths, 1))

    local fields = {
        field("\u{1F4B0} Bounty",         code(commify(current)),        true),
        field("\u{1F4C8} Session Gain",   code(signed(change)),          true),
        field("\u{1F3D4}\u{FE0F} Peak",   code(commify(session.peak)),   true),
        field("\u{2694}\u{FE0F} Kills",   code(session.kills),           true),
        field("\u{1F480} Deaths",         code(session.deaths),          true),
        field("\u{1F4CA} K/D",            code(kd),                      true),
        field("\u{23F1}\u{FE0F} Runtime", code(formatTime(elapsed)),     true),
        field("\u{1F4B9} Rate",           code(rate),                    true),
        field("\u{2620}\u{FE0F} Team",    code(team),                    true),
    }

    if session.kills > 0 then
        table.insert(fields, field("\u{1F3AF} Last Kill", code(signed(session.lastKill)), true))
    end

    if Config.ShowExtras then
        local level = safeValue(player, "Data", "Level")
        local beli = safeValue(player, "Data", "Beli")
        if level then
            table.insert(fields, field("\u{2B50} Level", code(commify(level)), true))
        end
        if beli then
            table.insert(fields, field("\u{1FA99} Beli", code(commify(beli)), true))
        end
        table.insert(fields, field(
            "\u{1F310} Server",
            code(#Players:GetPlayers() .. "/" .. Players.MaxPlayers),
            true
        ))
        if session.hops > 0 then
            table.insert(fields, field("\u{1F501} Server Hops", code(session.hops), true))
        end
    end

    if Config.AlertBounty then
        local frac = current / Config.AlertBounty
        local text = bar(frac, 14) .. string.format(" %.1f%%", math.clamp(frac, 0, 1) * 100)

        -- ETA from the average rate of this session
        local remaining = Config.AlertBounty - current
        if remaining > 0 and perSecond > 0 and elapsed >= 300 then
            local eta = remaining / perSecond
            text = text .. (eta > 360000 and "\nETA: 100h+" or ("\nETA: " .. formatTime(eta)))
        end

        table.insert(fields, field("\u{1F3C1} Goal: " .. commify(Config.AlertBounty), code(text), false))
    end

    if Config.ShowTrend and #session.history >= 2 then
        local line, lo, hi = sparkline(session.history)
        table.insert(fields, field(
            "\u{1F4C9} Trend (last " .. #session.history .. " updates)",
            code(line) .. "\nlow " .. code(commify(lo)) .. "  high " .. code(commify(hi)),
            false
        ))
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
            footer = { text = "Bounty Checker " .. Config.Version .. " | refreshes every " .. Config.Interval .. "s" },
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
        sendAlert("\u{1F3C6} Goal reached", player.Name .. " reached " .. code(commify(current)) .. " bounty.", 16766720)
    end

    local idleFor = os.time() - lastChangeTime
    if Config.IdleAlert and not idleAlerted and idleFor >= Config.IdleMinutes * 60 then
        idleAlerted = true
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
task.spawn(function()
    local failStreak = 0
    while running do
        local ok, result = pcall(function()
            pushHistory(getBounty())
            local sent = deliver(buildPayload("running"), Config.EditMessage)
            checkAlerts()
            saveSession()
            return sent
        end)

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
