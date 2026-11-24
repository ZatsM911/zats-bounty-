-- Bounty Checker v2 (Blox Fruits) - live session status to a Discord webhook
-- Fully local: no loadstring, no remote code. Only sends the stats shown below.

repeat task.wait() until game:IsLoaded()

-- Prevent running two copies at once
if _G.__BountyCheckerRunning then
    warn("[BountyChecker] Already running. Call _G.BountyChecker.Stop() first to restart.")
    return
end

----------------------------------------------------------------
-- Config (read from the loader's _G.BountyConfig, with defaults)
----------------------------------------------------------------
local User = (_G.BountyConfig or {})["Webhook"] or {}

local Config = {
    Enabled     = User["Enabled"] ~= false,
    Webhook     = tostring(User["Url Webhook"] or ""),
    DiscordId   = tostring(User["Discord ID"] or ""),
    Interval    = math.max(tonumber(User["Interval"]) or 60, 10), -- seconds, min 10
    EditMessage = User["Edit Message"] ~= false,  -- true: edit one message instead of spamming
    Ping        = User["Ping"] ~= false,          -- mention you (first message only when editing)
    ShowExtras  = User["Show Extras"] ~= false,   -- Level / Beli if found
    BotName     = "Bounty Checker",
    Title       = "LIVE SESSION STATUS",
}

if not Config.Enabled then return end

local function validWebhook(url)
    return url:match("^https://[%w%.]*discord[%w%.]*/api/webhooks/%d+/[%w%-_]+") ~= nil
end

if not validWebhook(Config.Webhook) then
    warn("[BountyChecker] Missing or invalid webhook URL in _G.BountyConfig.")
    return
end

-- Remove any ?query part so we can build message URLs ourselves
local baseUrl = Config.Webhook:gsub("%?.*$", "")

----------------------------------------------------------------
-- Services / executor HTTP
----------------------------------------------------------------
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

local httpRequest = (syn and syn.request) or http_request or request or (http and http.request)
if not httpRequest then
    warn("[BountyChecker] No HTTP request function found in this executor.")
    return
end

_G.__BountyCheckerRunning = true
local running = true

_G.BountyChecker = {
    Stop = function()
        running = false
        _G.__BountyCheckerRunning = nil
        print("[BountyChecker] Stopped.")
    end,
}

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

local function formatTime(total)
    total = math.floor(total)
    return string.format("%dh %dm %ds", math.floor(total / 3600), math.floor((total % 3600) / 60), total % 60)
end

local function code(text)
    return "`" .. tostring(text) .. "`"
end

local function signed(n)
    return (n >= 0 and "+" or "-") .. commify(math.abs(n))
end

----------------------------------------------------------------
-- Session tracking
----------------------------------------------------------------
player:WaitForChild("leaderstats", 30)

local startTime = os.clock()
local startBounty = getBounty()
local lastBounty = startBounty
local kills = 0

-- Count a kill whenever bounty goes up (approximate)
task.spawn(function()
    while running do
        task.wait(1)
        local b = getBounty()
        if b > lastBounty then
            kills += 1
        end
        lastBounty = b
    end
end)

----------------------------------------------------------------
-- Discord delivery (edit-in-place, retry, rate-limit aware)
----------------------------------------------------------------
local messageId = nil

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

local function deliver(payload)
    for _ = 1, 3 do
        local res, err
        if Config.EditMessage and messageId then
            res, err = request("PATCH", baseUrl .. "/messages/" .. messageId, payload)
        else
            res, err = request("POST", baseUrl .. "?wait=true", payload)
        end

        if not res then
            warn("[BountyChecker] Request failed: " .. tostring(err))
            task.wait(5)
        else
            local status = res.StatusCode or res.Status
            if status == 200 or status == 204 then
                if Config.EditMessage and not messageId and res.Body then
                    local okDecode, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
                    if okDecode and type(data) == "table" and data.id then
                        messageId = data.id
                    end
                end
                return true
            elseif status == 404 and messageId then
                messageId = nil -- message was deleted, send a fresh one
            elseif status == 429 then
                local wait = 5
                local okDecode, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "{}")
                if okDecode and type(data) == "table" and tonumber(data.retry_after) then
                    wait = math.min(tonumber(data.retry_after) + 0.5, 30)
                end
                task.wait(wait)
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
local function buildPayload()
    local current = getBounty()
    local change = current - startBounty
    local elapsed = os.clock() - startTime
    local team = player.Team and player.Team.Name or "None"

    local perHour = "N/A"
    if elapsed >= 60 then
        perHour = signed(change / (elapsed / 3600)) .. " / hr"
    end

    local fields = {
        { name = "User Account",        value = code(player.Name),             inline = false },
        { name = "Total Time Run",      value = code(formatTime(elapsed)),     inline = false },
        { name = "Total Bounty Change", value = code(signed(change)),          inline = true },
        { name = "Total Kills",         value = code(kills .. " Kills"),       inline = true },
        { name = "Bounty Rate",         value = code(perHour),                 inline = true },
        { name = "Current Bounty",      value = code(commify(current)),        inline = false },
        { name = "Current Team",        value = code(team),                    inline = true },
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
    end

    -- Green when gaining, red when losing, gold when flat
    local color = 16766720
    if change > 0 then
        color = 5763719
    elseif change < 0 then
        color = 15548997
    end

    local mention = ""
    if Config.Ping and Config.DiscordId ~= "" then
        mention = "<@" .. Config.DiscordId .. ">"
    end

    return {
        username = Config.BotName,
        content = mention,
        allowed_mentions = Config.DiscordId ~= "" and { users = { Config.DiscordId } } or { parse = {} },
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

task.spawn(function()
    while running do
        local ok, payload = pcall(buildPayload)
        if ok then
            deliver(payload)
        else
            warn("[BountyChecker] Failed to build report: " .. tostring(payload))
        end

        local waited = 0
        while running and waited < Config.Interval do
            task.wait(1)
            waited += 1
        end
    end
end)
