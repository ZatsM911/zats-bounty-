-- Bounty Checker v3 (Blox Fruits) - live session status to a Discord webhook
-- Fully local: no loadstring, no remote code. Only sends the stats shown below.

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
    Interval      = math.max(tonumber(User["Interval"]) or 60, 10), -- seconds, min 10
    EditMessage   = User["Edit Message"] ~= false,   -- edit one message instead of spamming
    Ping          = User["Ping"] ~= false,           -- mention you (first message only when editing)
    ShowExtras    = User["Show Extras"] ~= false,    -- Level / Beli / server players
    Persist       = User["Persist Session"] ~= false, -- keep stats across server hops (needs writefile)
    ResumeWindow  = tonumber(User["Resume Window"]) or 600, -- seconds a saved session stays valid
    MinKillGain   = tonumber(User["Min Kill Gain"]) or 1,   -- min bounty gain counted as a kill
    AlertBounty   = tonumber(User["Alert Bounty"]),         -- optional: ping once at this bounty
    BotName       = "Bounty Checker",
    Title         = "LIVE SESSION STATUS",
}

if not Config.Enabled then return end

if Config.Webhook:match("^https://[%w%.]*discord[%w%.]*/api/webhooks/%d+/[%w%-_]+") == nil then
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

local function getBounty()
    local ls = player:FindFirstChild("leaderstats")
    local v = ls and (ls:FindFirstChild("Bounty/Honor") or ls:FindFirstChild("Bounty"))
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

----------------------------------------------------------------
-- Session state (saved to disk so server hops do not reset it)
----------------------------------------------------------------
local SESSION_FILE = "BountyChecker_" .. player.UserId .. ".json"

local session = {
    startTime = os.time(),
    startBounty = nil,
    kills = 0,
    messageId = nil,
    alerted = false,
    lastSeen = os.time(),
}

local function saveSession()
    if not (Config.Persist and hasFS) then return end
    session.lastSeen = os.time()
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
        session.kills = tonumber(data.kills) or 0
        session.messageId = data.messageId
        session.alerted = data.alerted == true
    end
end

_G.BountyChecker = {
    Stop = function(clearSession)
        running = false
        _G.__BountyCheckerRunning = nil
        if clearSession and type(delfile) == "function" then
            pcall(delfile, SESSION_FILE)
        end
        print("[BountyChecker] Stopped.")
    end,
}

player:WaitForChild("leaderstats", 30)
loadSession()

if not session.startBounty then
    session.startBounty = getBounty()
end

local lastBounty = getBounty()
local lastReportBounty = lastBounty

-- Count a kill whenever bounty rises by at least MinKillGain (approximate)
task.spawn(function()
    while running do
        task.wait(1)
        local b = getBounty()
        if b - lastBounty >= Config.MinKillGain then
            session.kills += 1
        end
        lastBounty = b
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

-- Sends a payload. When edit is true and a message exists, edits it instead.
local function deliver(payload, edit)
    for _ = 1, 3 do
        local res, err
        if edit and session.messageId then
            res, err = request("PATCH", baseUrl .. "/messages/" .. session.messageId, payload)
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
-- Report
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

local function buildPayload()
    local current = getBounty()
    local change = current - session.startBounty
    local elapsed = os.time() - session.startTime
    local team = player.Team and player.Team.Name or "None"
    local sinceLast = current - lastReportBounty
    lastReportBounty = current

    local rate = "N/A"
    if elapsed >= 60 then
        rate = signed(change / (elapsed / 3600)) .. " / hr"
    end

    local fields = {
        { name = "User Account",        value = code(player.Name),          inline = false },
        { name = "Total Time Run",      value = code(formatTime(elapsed)),  inline = false },
        { name = "Total Bounty Change", value = code(signed(change)),       inline = true },
        { name = "Total Kills",         value = code(session.kills .. " Kills"), inline = true },
        { name = "Bounty Rate",         value = code(rate),                 inline = true },
        { name = "Since Last Report",   value = code(signed(sinceLast)),    inline = true },
        { name = "Current Bounty",      value = code(commify(current)),     inline = false },
        { name = "Current Team",        value = code(team),                 inline = true },
    }

    if Config.ShowExtras then
        local level = safeValue(player, "Data", "Level")
        local beli = safeValue(player, "Data", "Beli")
        if level then
            table.insert(fields, { name = "Level", value = code(commify(level)), inline = true })
        end
        if beli then
            table.insert(fields, { name = "Beli", value = code(commify(beli)), inline = true })
        end
        table.insert(fields, {
            name = "Server Players",
            value = code(#Players:GetPlayers() .. "/" .. Players.MaxPlayers),
            inline = true,
        })
    end

    -- Green when gaining, red when losing, gold when flat
    local color = 16766720
    if change > 0 then
        color = 5763719
    elseif change < 0 then
        color = 15548997
    end

    return {
        username = Config.BotName,
        content = mentionText(),
        allowed_mentions = allowedMentions(),
        embeds = {{
            title = Config.Title,
            color = color,
            fields = fields,
            thumbnail = {
                url = "https://www.roblox.com/headshot-thumbnail/image?userId="
                    .. player.UserId .. "&width=150&height=150&format=png",
            },
            footer = { text = "Bounty Checker | updates every " .. Config.Interval .. "s" },
            timestamp = DateTime.now():ToIsoDate(),
        }},
    }
end

local function checkAlert()
    if not Config.AlertBounty or session.alerted then return end
    local current = getBounty()
    if current >= Config.AlertBounty then
        session.alerted = true
        request("POST", baseUrl, {
            username = Config.BotName,
            content = (Config.DiscordId ~= "" and ("<@" .. Config.DiscordId .. "> ") or "")
                .. "Bounty milestone reached: " .. commify(current),
            allowed_mentions = allowedMentions(),
        })
    end
end

task.spawn(function()
    while running do
        local ok, payload = pcall(buildPayload)
        if ok then
            deliver(payload, Config.EditMessage)
        else
            warn("[BountyChecker] Failed to build report: " .. tostring(payload))
        end

        checkAlert()
        saveSession()

        local waited = 0
        while running and waited < Config.Interval do
            task.wait(1)
            waited += 1
        end
    end
end)
