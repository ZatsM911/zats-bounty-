-- Bounty Checker (Blox Fruits) - sends live session status to a Discord webhook
-- Fully local: no loadstring, no remote code. Only sends the stats shown below.

repeat task.wait() until game:IsLoaded()

-- Settings come from the loader (_G.BountyConfig); defaults are used if missing
local User = (_G.BountyConfig or {})["Webhook"] or {}

local Config = {
    Enabled   = User["Enabled"] ~= false,
    Webhook   = User["Url Webhook"] or "PUT_YOUR_WEBHOOK_URL_HERE",
    DiscordId = User["Discord ID"] or "",    -- "" disables the ping
    Interval  = User["Interval"] or 60,      -- seconds between reports
    BotName   = "Bounty Checker",
    Title     = "LIVE SESSION STATUS",
    Color     = 16766720,                    -- embed color (decimal)
}

if not Config.Enabled then return end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

-- Executors expose different request functions
local httpRequest = (syn and syn.request) or http_request or request or (http and http.request)
if not httpRequest then
    warn("[BountyChecker] No HTTP request function found in this executor.")
    return
end

if Config.Webhook == "" or Config.Webhook:find("PUT_YOUR") then
    warn("[BountyChecker] Set your webhook URL in Config.Webhook first.")
    return
end

local function getBounty()
    local ls = player:FindFirstChild("leaderstats")
    if not ls then return 0 end
    local v = ls:FindFirstChild("Bounty/Honor") or ls:FindFirstChild("Bounty")
    return v and v.Value or 0
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
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    return string.format("%dh %dm %ds", h, m, s)
end

local function code(text)
    return "`" .. tostring(text) .. "`"
end

local startTime = os.clock()
local startBounty = getBounty()
local lastBounty = startBounty
local kills = 0

-- Count a kill whenever bounty goes up
task.spawn(function()
    while true do
        task.wait(1)
        local b = getBounty()
        if b > lastBounty then
            kills += 1
        end
        lastBounty = b
    end
end)

local function sendReport()
    local current = getBounty()
    local change = current - startBounty
    local team = player.Team and player.Team.Name or "None"

    local payload = {
        username = Config.BotName,
        content = (Config.DiscordId ~= "" and not Config.DiscordId:find("PUT_YOUR"))
            and ("<@" .. Config.DiscordId .. ">") or "",
        embeds = {{
            title = Config.Title,
            color = Config.Color,
            fields = {
                { name = "User Account",        value = code(player.Name),                          inline = false },
                { name = "Total Time Run",      value = code(formatTime(os.clock() - startTime)),   inline = false },
                { name = "Total Bounty Change", value = code((change >= 0 and "+" or "") .. commify(change)), inline = true },
                { name = "Total Kills",         value = code(kills .. " Kills"),                    inline = true },
                { name = "Current Bounty",      value = code(commify(current)),                     inline = false },
                { name = "Current Team",        value = code(team),                                 inline = false },
            },
            footer = { text = "Bounty Checker" },
            timestamp = DateTime.now():ToIsoDate(),
        }},
    }

    local ok, err = pcall(function()
        httpRequest({
            Url = Config.Webhook,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload),
        })
    end)
    if not ok then
        warn("[BountyChecker] Failed to send: " .. tostring(err))
    end
end

-- Report loop
task.spawn(function()
    while true do
        sendReport()
        task.wait(Config.Interval)
    end
end)
