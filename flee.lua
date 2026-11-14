local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

-- Roblox's bold UI face renders far cleaner than the default text font
local BOLD_FONT = 11
pcall(function() BOLD_FONT = Drawing.Fonts.ProximaSoftBold end)

local CFG = {
    survivor = Color3.fromRGB(90, 205, 255),
    beast    = Color3.fromRGB(255, 70, 70),
    computer = Color3.fromRGB(0, 150, 255),
    exit     = Color3.fromRGB(255, 170, 40),
    pod      = Color3.fromRGB(60, 240, 220),

    -- menu toggles (names and the lobby filter are always on)
    survivorESP = true,
    beastESP = true,
    computerESP = true,
    exitESP = false,     -- off by default; turn it on in the menu
    podESP = false,      -- freeze pods are plentiful, so off by default
    showDist = true,     -- survivor distance tag
    beastDist = true,    -- beast distance tag
    computerDist = true, -- computer distance tag
    hideHacked = true,   -- drop a terminal once the game's count confirms it is finished
    exitDist = true,
    podDist = false,

    -- extras
    tracers = false,     -- line from the bottom of the screen to each player box
    hud = true,          -- match summary in the bottom-left corner

    -- tuning
    maxDistance = 3000,
    -- box sizes are fixed defaults (no slider): a fraction of the model's height
    survivorScale = 1.0,   -- survivor box multiplier
    beastScale = 1.0,      -- beast box multiplier
    computerScale = 0.20,  -- computer table
    exitScale = 0.62,      -- measured on the door leaves
    podScale = 0.42,       -- freeze pod
    menuKey = 0x4B,        -- K; rebindable from Settings
    menuKeyName = "K",
    nameSize = 15,         -- player name text
    tagSize = 13,          -- object tag text
    lobbyMargin = 8,       -- slack around the lobby bounds before a player counts as lobby
    slowInterval = 0.25,   -- character lookups, beast tag, text content
    scanCooldown = 10,     -- min seconds between scans while objects exist but some went stale (map changed)
    scanRetryEmpty = 8,    -- min seconds between scans while no objects are known
    scanRefresh = 20,      -- sec between background sweeps, so objects that appear after the round starts are still found
    sliceBudget = 0.006,   -- max seconds of scan work per frame before yielding
}

-- One entry per scannable object. `enabler` is the menu switch, `scaleId` the
-- box-size slider and `distId` the distance-tag switch. `focus` narrows the
-- measured model to a child, so an exit's trigger volume cannot stretch the box.
local KINDS = {
    computer = { enabler = "computerESP", scaleId = "computerScale", distId = "computerDist", color = CFG.computer, label = "COMPUTER", focus = nil },
    exit     = { enabler = "exitESP",     scaleId = "exitScale",     distId = "exitDist",     color = CFG.exit,     label = "EXIT",     focus = "Door" },
    pod      = { enabler = "podESP",      scaleId = "podScale",      distId = "podDist",      color = CFG.pod,      label = "POD",      focus = nil },
}

-- Instance names the scan cares about, mapped to the kind above.
local SCAN_TARGETS = {
    ComputerTable = "computer",
    ExitDoor = "exit",
    FreezePod = "pod",
}

local function kindOf(name)
    local kind = SCAN_TARGETS[name]
    if kind then return kind end
    -- freeze pods are named differently map to map: "FreezePod", "FreezePod 2",
    -- "Freeze Pod", "CryoPod", "FreezeChamber". The suffix is only ever a number.
    local low = string.lower(name)
    local rest = nil
    if string.sub(low, 1, 10) == "freeze pod" then rest = string.sub(low, 11)
    elseif string.sub(low, 1, 9) == "freezepod" then rest = string.sub(low, 10)
    elseif string.sub(low, 1, 14) == "freeze chamber" then rest = string.sub(low, 15)
    elseif string.sub(low, 1, 13) == "freezechamber" then rest = string.sub(low, 14)
    elseif string.sub(low, 1, 8) == "cryo pod" then rest = string.sub(low, 9)
    elseif string.sub(low, 1, 7) == "cryopod" then rest = string.sub(low, 8)
    end
    if rest ~= nil and string.match(rest, "^[ _]?%d*$") ~= nil then
        return "pod"
    end
    return nil
end

local running = true
_G.FTF_ESP_Unload = function() running = false end

-- Round state the game publishes itself (ComputersLeft, GameStatus).
-- Reading it is cheaper and truer than inferring anything from the map models.
local RoundStore = game:GetService("ReplicatedStorage")
local function readValue(name)
    local v = RoundStore:FindFirstChild(name)
    if not v then return nil end
    local ok, val = pcall(function() return v.Value end)
    if ok then return val end
    return nil
end

-- ==========================================
-- Entry helpers (pooled drawing sets)
-- ==========================================
local function newBox(thickness)
    local b = Drawing.new("Square")
    b.Filled = false
    b.Thickness = thickness
    b.Visible = false
    return b
end

local function newText(size)
    local t = Drawing.new("Text")
    t.Size = size
    t.Center = true
    t.Outline = true
    pcall(function() t.Font = BOLD_FONT end)
    t.Visible = false
    return t
end

local function newLine()
    local l = Drawing.new("Line")
    l.Thickness = 1
    l.Visible = false
    return l
end

local function newPlayerEntry()
    return { box = newBox(1.5), name = newText(CFG.nameSize), tracer = newLine(), shown = false, lastName = "" }
end

local function newObjectEntry(kind)
    local k = KINDS[kind]
    local color = k and k.color or CFG.computer
    local e = { box = newBox(1.5), text = newText(CFG.tagSize), shown = false, lastLabel = nil }
    e.box.Color = color
    e.text.Color = color
    e.text.Text = k and k.label or "OBJECT"
    return e
end

local function setShown(e, state)
    if e.shown == state then return end
    e.shown = state
    e.box.Visible = state
    if e.name then e.name.Visible = state end
    if e.text then e.text.Visible = state end
    if e.tracer then e.tracer.Visible = state and CFG.tracers == true end
end

local function destroyEntry(e)
    setShown(e, false)
    pcall(function() e.box:Remove() end)
    if e.name then pcall(function() e.name:Remove() end) end
    if e.text then pcall(function() e.text:Remove() end) end
    if e.tracer then pcall(function() e.tracer:Remove() end) end
end

-- ==========================================
-- Game helpers
-- ==========================================
local function hasBeastTag(char)
    return char:FindFirstChild("Hammer") ~= nil or char:FindFirstChild("BeastPowers") ~= nil
end

-- Lobby bounds. Between rounds everyone (and every late joiner) stands in the lobby,
-- which is a fixed set of workspace folders beside the round map. A player inside
-- those bounds is in the lobby, so they get no box. Measured once: the lobby is static.
local LOBBY_FOLDERS = { "LobbyCave", "LobbyInteractiveObjects", "HalloweenLobby2026", "BeastCave" }
local lobbyBox = nil

local function measureLobby()
    local roots = {}
    for i = 1, #LOBBY_FOLDERS do
        local ok, inst = pcall(function() return Workspace:FindFirstChild(LOBBY_FOLDERS[i]) end)
        if ok and inst then roots[#roots + 1] = inst end
    end
    if #roots == 0 then return nil end

    local box = { done = false, parts = 0,
        minX = math.huge, minY = math.huge, minZ = math.huge,
        maxX = -math.huge, maxY = -math.huge, maxZ = -math.huge }

    task.spawn(function()
        for r = 1, #roots do
            local okA, all = pcall(function() return roots[r]:GetDescendants() end)
            if okA and all then
                local i, n = 1, #all
                while i <= n and running do
                    local deadline = tick() + CFG.sliceBudget
                    while i <= n and tick() < deadline do
                        local stop = i + 199
                        if stop > n then stop = n end
                        for j = i, stop do
                            local part = all[j]
                            local okP, pos, size = pcall(function() return part.Position, part.Size end)
                            if okP and pos and size then
                                box.parts = box.parts + 1
                                local x0, y0, z0 = pos.X - size.X / 2, pos.Y - size.Y / 2, pos.Z - size.Z / 2
                                local x1, y1, z1 = pos.X + size.X / 2, pos.Y + size.Y / 2, pos.Z + size.Z / 2
                                if x0 < box.minX then box.minX = x0 end
                                if y0 < box.minY then box.minY = y0 end
                                if z0 < box.minZ then box.minZ = z0 end
                                if x1 > box.maxX then box.maxX = x1 end
                                if y1 > box.maxY then box.maxY = y1 end
                                if z1 > box.maxZ then box.maxZ = z1 end
                            end
                        end
                        i = stop + 1
                    end
                    task.wait()
                end
            end
        end
        if box.parts > 0 then box.done = true end
    end)

    return box
end

task.spawn(function()
    while running do
        if not lobbyBox then lobbyBox = measureLobby() end -- kept until the lobby folders exist
        if lobbyBox and lobbyBox.done then break end
        task.wait(2)
    end
end)

-- true while the player stands in the lobby / spawn area
local function inLobby(pos)
    local b = lobbyBox
    if not b or not b.done then return false end
    local m = CFG.lobbyMargin
    return pos.X >= b.minX - m and pos.X <= b.maxX + m
        and pos.Y >= b.minY - m and pos.Y <= b.maxY + m
        and pos.Z >= b.minZ - m and pos.Z <= b.maxZ + m
end

-- true when the instance lives inside one of the lobby folders (the lobby holds
-- prefab copies of computers, pods and doors that must never be drawn)
local function inLobbyTree(inst)
    local p = inst.Parent
    while p and p ~= Workspace do
        for i = 1, #LOBBY_FOLDERS do
            if p.Name == LOBBY_FOLDERS[i] then return true end
        end
        p = p.Parent
    end
    return false
end

-- Base parts that make up a visible object. Wedges and trusses are included
-- because some maps build their pods out of anything but plain blocks, and a pod
-- measured from plain Parts only would come out wrong or not at all.
local SOLID = {
    Part = true, MeshPart = true, UnionOperation = true,
    WedgePart = true, CornerWedgePart = true, TrussPart = true,
}

-- World-space bounds of one scanned object. `focus` narrows it to a child
-- model (the door leaves of an exit, for example). ClearWall is a tall invisible
-- panel above the computer monitor, so it is always skipped or the box floats.
local function objectBounds(inst, focus)
    local root = inst
    if focus then
        local okC, child = pcall(function() return inst:FindFirstChild(focus, true) end)
        if okC and child then root = child end
    end
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    local any = false

    local function addPart(part)
        if not SOLID[part.ClassName] then return end
        if part.Name == "ClearWall" then return end
        local okR, pos, size = pcall(function() return part.Position, part.Size end)
        if not (okR and pos and size) then return end
        local x0, y0, z0 = pos.X - size.X / 2, pos.Y - size.Y / 2, pos.Z - size.Z / 2
        local x1, y1, z1 = pos.X + size.X / 2, pos.Y + size.Y / 2, pos.Z + size.Z / 2
        if x0 < minX then minX = x0 end
        if y0 < minY then minY = y0 end
        if z0 < minZ then minZ = z0 end
        if x1 > maxX then maxX = x1 end
        if y1 > maxY then maxY = y1 end
        if z1 > maxZ then maxZ = z1 end
        any = true
    end

    -- an object that is itself one part (a pod shipped without a model) measures itself
    addPart(root)

    local ok, all = pcall(function() return root:GetDescendants() end)
    if not ok or not all then return nil end
    for i = 1, #all do addPart(all[i]) end
    if not any then return nil end
    local halfX, halfY, halfZ = (maxX - minX) / 2, (maxY - minY) / 2, (maxZ - minZ) / 2
    if halfY < 0.1 then halfY = 0.1 end
    return {
        center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2),
        halfY = halfY,
        aspect = math.max(halfX, halfZ) / halfY, -- width/height seen on screen
    }
end

-- ==========================================
-- State (keyed by numbers, not Instances)
-- ==========================================
local pcache = {}       -- [userId] = { name, hrp, head, hum, tagged, entry, stamp }
local objs = {}         -- [address] = { inst, kind, bounds, entry, stamp, root }
local textDirty = true
local frame = 0
local lastScanStart = -1e9
local vpX, vpY = 1920, 1080 -- camera viewport size, refreshed by the slow loop
local fpsNow, fpsFrames, fpsTime = 0, 0, 0

-- ==========================================
-- Slow path: players
-- ==========================================
local function refreshMeta()
    local cam = Workspace.CurrentCamera
    if cam then
        local ok, vp = pcall(function() return cam.ViewportSize end)
        if ok and vp and vp.Y and vp.Y > 0 then vpY = vp.Y end
        if ok and vp and vp.X and vp.X > 0 then vpX = vp.X end
    end
end

local function refreshPlayers()
    local list = Players:GetPlayers()
    local present = {}

    for _, p in ipairs(list) do
        local uid = p.UserId
        present[uid] = true
        local char = p.Character
        -- The role is latched for the whole round and never cleared here. FTF
        -- parents the beast's Hammer in and out of the character while it swings
        -- or fires a power, and a fresh read taken during one of those gaps dropped
        -- the box to the survivor colour - that light blue blink is the flicker.
        -- While unequipped the badge sits in the Backpack, so both are checked.
        local pack = p:FindFirstChild("Backpack")
        local tagged = (char ~= nil and hasBeastTag(char))
            or (pack ~= nil and hasBeastTag(pack))

        if p ~= LocalPlayer then
            local rec = pcache[uid]
            if not rec then
                rec = { stamp = 0 }
                pcache[uid] = rec
            end
            rec.name = p.Name
            if tagged then rec.tagged = true end
            rec.hrp = char and char:FindFirstChild("HumanoidRootPart")
            rec.head = char and char:FindFirstChild("Head")
            rec.hum = char and char:FindFirstChildOfClass("Humanoid")
        end
    end

    for uid, rec in pairs(pcache) do
        if not present[uid] then
            if rec.entry then destroyEntry(rec.entry) end
            pcache[uid] = nil
        end
    end
end

task.spawn(function()
    while running do
        pcall(refreshMeta)
        pcall(refreshPlayers)
        textDirty = true
        task.wait(CFG.slowInterval)
    end
end)

-- ==========================================
-- Object scan (on demand, time-sliced)
-- ==========================================
-- top-level workspace child that contains an instance; used to notice a map swap
local function rootOf(inst)
    local p, last = inst, inst
    while p and p ~= Workspace do
        last = p
        p = p.Parent
    end
    return last
end

local function rootName(inst)
    local r = rootOf(inst)
    return r and r.Name or ""
end

-- Some maps group their pods in a folder or name the copies "1", "2", ... under
-- one, so a container holding a PodTrigger / PodScript / PodRoof is a pod too,
-- whatever it is called. The name gate keeps this off every other model.
local function podLike(inst)
    local low = string.lower(inst.Name)
    local parent = inst.Parent
    local plow = parent and string.lower(parent.Name) or ""
    local named = string.find(low, "pod", 1, true) or string.find(low, "freeze", 1, true)
        or string.find(plow, "pod", 1, true) or string.find(plow, "freeze", 1, true)
    if not named then return false end
    for _, ch in pairs(inst:GetChildren()) do
        if ch.Name == "PodTrigger" or ch.Name == "PodScript" or ch.Name == "PodRoof" then return true end
    end
    return false
end

local function checkInst(inst, found)
    local cls = inst.ClassName
    local lowName = string.lower(inst.Name)
    -- prefab copies sit outside the lobby folders on some maps and must not be drawn
    if string.sub(lowName, 1, 6) == "prefab" then return end
    local kind = kindOf(inst.Name)
    if not kind and (cls == "Model" or cls == "Folder") and podLike(inst) then kind = "pod" end
    if not kind then return end
    -- pods may be a bare part; everything else is a model
    if cls ~= "Model" and cls ~= "Folder" and not (kind == "pod" and SOLID[cls]) then return end
    if inLobbyTree(inst) then return end
    found[inst.Address] = { inst = inst, kind = kind }
end

-- Set when a round change is seen. The old code only wrote lastScanStart = -1e9
-- and then never asked for a scan, because a map that is still being built can
-- hand back its exits and pods while the computers do not exist yet: every record
-- stays alive, so nothing ever triggered another sweep and computer ESP stayed
-- empty for the whole round. This flag is what makes those requests happen.
local scanForced = false

local function scanNeeded(now)
    if scanForced then return true end
    local total, valid = 0, 0
    for _, rec in pairs(objs) do
        total = total + 1
        if rec.inst.Parent then valid = valid + 1 end
    end
    if total == 0 then
        return now - lastScanStart >= CFG.scanRetryEmpty
    end
    if valid < total then
        return now - lastScanStart >= CFG.scanCooldown
    end
    -- everything alive is not proof that everything was found: a sweep that ran
    -- while the map was still loading can miss a whole kind. Sweep again on a slow
    -- timer instead of trusting one snapshot for the rest of the round.
    return now - lastScanStart >= CFG.scanRefresh
end

-- A new round destroys the old map folder and builds a new one. A map can be
-- rebuilt under the very same name, so the folder itself is compared rather than
-- its name: the old records are dropped the moment their map folder is a
-- different instance (or gone), instead of waiting for a rescan to notice.
local function checkMap()
    local present = {}
    local kids = Workspace:GetChildren()
    for i = 1, #kids do present[kids[i].Name] = true end
    for _, rec in pairs(objs) do
        local gone = rec.root and rec.root ~= "" and not present[rec.root]
        if not gone and rec.rootInst and rootOf(rec.inst) ~= rec.rootInst then
            gone = true
        end
        if gone then
            for _, r in pairs(objs) do
                if r.entry then destroyEntry(r.entry) end
            end
            objs = {}
            lastScanStart = -1e9
            scanForced = true
            return
        end
    end
end

local function runScan()
    lastScanStart = tick()
    scanForced = false
    local ok, all = pcall(function() return Workspace:GetDescendants() end)
    if not ok or not all then return end

    local found = {}
    local i, n = 1, #all
    while i <= n and running do
        local deadline = tick() + CFG.sliceBudget
        while i <= n and tick() < deadline do
            local stop = i + 49
            if stop > n then stop = n end
            for j = i, stop do
                pcall(checkInst, all[j], found)
            end
            i = stop + 1
        end
        task.wait() -- let the render loop run between slices (no pcall around this yield)
    end
    if not running then return end

    for addr, rec in pairs(objs) do
        if not found[addr] then
            if rec.entry then destroyEntry(rec.entry) end
            objs[addr] = nil
        end
    end
    for addr, info in pairs(found) do
        -- Instance addresses are recycled once the previous round's map is thrown
        -- away, so a record from an earlier round can share a key with a brand new
        -- instance. Anything that is not the very same instance is rebuilt, or the
        -- new round's computers would inherit a dead record and never draw again.
        local rec = objs[addr]
        if rec and (rec.inst ~= info.inst or not rec.inst.Parent) then
            if rec.entry then destroyEntry(rec.entry) end
            objs[addr] = nil
            rec = nil
        end
        local k = KINDS[info.kind]
        if not rec then
            local newRec = { inst = info.inst, kind = info.kind, bounds = nil, entry = nil, stamp = 0, root = rootName(info.inst), rootInst = rootOf(info.inst) }
            pcall(function() newRec.bounds = objectBounds(info.inst, k and k.focus) end)
            objs[addr] = newRec
        elseif not rec.bounds then
            -- the model was still assembling when it was first measured, and a
            -- record without bounds can never draw, so measure it again
            pcall(function() rec.bounds = objectBounds(rec.inst, k and k.focus) end)
        end
    end
end

-- A finished terminal keeps no flag the client can read: the models look the
-- same before and after a hack, and the only state the game publishes is the
-- total in ComputersLeft. ComputerTrigger1.Value is true while somebody types at
-- a terminal, but it only fires for a hack started by the local player, so it
-- misses everyone else's. The second piece of evidence is the hacker themselves:
-- whoever finishes one is standing at that terminal. So a drop in ComputersLeft
-- marks the terminals that either had the local flag set or had a survivor
-- standing still next to them. When more terminals qualify than the count dropped
-- by, the nearest ones win only if there is a clear distance gap; otherwise the
-- guess is skipped rather than risk hiding a terminal that still needs hacking.

-- A finished terminal repaints its screen green (open terminals are blue). The
-- exact shade is not the same on every map, so this tests "green clearly wins"
-- instead of one hard coded colour, and returns nil when there is no screen part
-- to read (then the count based guess below is used instead).
local function computerDone(inst)
    local screen = inst:FindFirstChild("Screen")
    if not screen then return nil end
    local ok, c = pcall(function() return screen.Color end)
    if not ok or not c then return nil end
    if c.G >= 55 and c.G > c.R * 1.4 and c.G > c.B * 1.2 then return true end
    return false
end

local function computerBusy(inst)
    for _, ch in pairs(inst:GetChildren()) do
        if ch.Name == "ComputerTrigger1" then
            for _, v in pairs(ch:GetChildren()) do
                if v.Name == "Value" then
                    local ok, val = pcall(function() return v.Value end)
                    if ok then return val == true end
                end
            end
        end
    end
    return false
end

-- A round change is also announced in GameStatus, which does not depend on the
-- map folder name, so a change there drops the old objects and re-acquires them.
local lastStatus = nil
local lastLeft = nil
local busyPrev = {}

-- Whoever finishes a hack is standing at that terminal, so survivor positions are
-- sampled on the same beat as the count. Someone running past moves far more than
-- a few studs between samples and does not count.
local function samplePlayers()
    for _, rec in pairs(pcache) do
        local hrp, hum = rec.hrp, rec.hum
        if hrp and hrp.Parent and hum and hum.Health > 0 then
            local p = hrp.Position
            local moved = 99
            if rec.lastPos then moved = (p - rec.lastPos).Magnitude end
            rec.lastPos = p
            rec.curPos = p
            rec.movedNow = moved
        else
            rec.curPos = nil
            rec.movedNow = nil
        end
    end
end

local function stillNear(center)
    local best = nil
    for _, rec in pairs(pcache) do
        local p = rec.curPos
        if p and rec.tagged ~= true and rec.movedNow and rec.movedNow <= 6 then
            local d = (p - center).Magnitude
            if d <= 12 and (best == nil or d < best) then best = d end
        end
    end
    return best
end

task.spawn(function()
    while running do
        local status = readValue("GameStatus")
        if lastStatus ~= nil and status ~= lastStatus then
            lastScanStart = -1e9
            scanForced = true
            -- a fresh round picks a fresh beast, so the latched role is released
            for _, rec in pairs(pcache) do rec.tagged = nil end
        end
        lastStatus = status

        pcall(function()
            local left = readValue("ComputersLeft")
            if type(left) ~= "number" then return end
            samplePlayers()

            -- the screen colour is a real per terminal flag, so it decides first
            local compN, doneN = 0, 0
            for _, rec in pairs(objs) do
                if rec.kind == "computer" then
                    local d = computerDone(rec.inst)
                    if d ~= nil then rec.done = d end
                    compN = compN + 1
                    if rec.done == true then doneN = doneN + 1 end
                end
            end
            -- every terminal reading green while some are still hackable means the
            -- map paints its screens differently, so fall back to the guess there
            if compN > 0 and doneN == compN and left > 0 then
                for _, rec in pairs(objs) do
                    if rec.kind == "computer" then rec.done = nil end
                end
            end

            -- The game says terminals are still hackable but not one is known: the
            -- sweep ran before the map existed, so ask for another one straight
            -- away instead of waiting for the background refresh.
            if compN == 0 and left > 0 and tick() - lastScanStart >= CFG.scanCooldown then
                scanForced = true
            end

            local cur = {}
            for addr, rec in pairs(objs) do
                if rec.kind == "computer" and computerBusy(rec.inst) then cur[addr] = true end
            end

            if type(lastLeft) == "number" and left ~= lastLeft then
                if left < lastLeft and left > 0 then
                    local drop = lastLeft - left
                    local scored = {}
                    for addr, rec in pairs(objs) do
                        if rec.kind == "computer" and not rec.hacked then
                            local center = rec.bounds and rec.bounds.center
                            local d = center and stillNear(center) or nil
                            if (cur[addr] or busyPrev[addr]) and d == nil then d = 999 end
                            if d ~= nil then scored[#scored + 1] = { rec = rec, d = d } end
                        end
                    end
                    table.sort(scored, function(a, b) return a.d < b.d end)
                    if #scored == drop then
                        for i = 1, #scored do scored[i].rec.hacked = true end
                    elseif #scored > drop and scored[drop + 1].d - scored[drop].d >= 3 then
                        -- someone standing at two terminals is odd, so only the
                        -- nearer one(s) are treated as finished
                        for i = 1, drop do scored[i].rec.hacked = true end
                    end
                else
                    -- count went up: a fresh round, so nothing is finished yet and
                    -- the map may not have been fully built when it was scanned
                    for _, rec in pairs(objs) do rec.hacked = false; rec.done = nil end
                    scanForced = true
                end
            end
            lastLeft = left
            busyPrev = cur
        end)

        pcall(checkMap)
        if scanNeeded(tick()) then runScan() end
        task.wait(1)
    end
end)

-- ==========================================
-- Hot path (RenderStepped)
-- ==========================================
local function updatePlayer(rec, camPos, doText)
    local hrp, hum = rec.hrp, rec.hum
    if not (hrp and hum) then return end
    if not hrp.Parent then return end
    if hum.Health <= 0 then return end

    local isBeast = rec.tagged == true
    if isBeast then
        if not CFG.beastESP then return end
    elseif not CFG.survivorESP then
        return
    end

    local pos = hrp.Position

    -- skip anyone standing in the lobby / spawn area instead of in the round
    if inLobby(pos) then return end

    local dist = (camPos - pos).Magnitude
    if dist > CFG.maxDistance then return end

    -- Anchor on the head and the feet. Very close up the root part slips behind
    -- the camera and stops projecting, so fall back to whichever end still does.
    local head = rec.head
    local topPos = (head and head.Position + Vector3.new(0, 0.6, 0)) or (pos + Vector3.new(0, 2.6, 0))
    local botPos = pos - Vector3.new(0, 2.8, 0)
    local st, okT = WorldToScreen(topPos)
    local sb, okB = WorldToScreen(botPos)

    local sx, cy, height
    if okT and okB then
        sx = (st.X + sb.X) / 2
        cy = (st.Y + sb.Y) / 2
        height = sb.Y - st.Y
    else
        local est = 1500 / (dist > 1 and dist or 1)
        if okT then
            sx, height = st.X, est
            cy = st.Y + est / 2
        elseif okB then
            sx, height = sb.X, est
            cy = sb.Y - est / 2
        else
            return
        end
    end

    local scale = isBeast and CFG.beastScale or CFG.survivorScale
    if scale ~= 1 then height = height * scale end

    local maxH = vpY * 0.9
    if height < 20 then height = 20 elseif height > maxH then height = maxH end
    local width = height * 0.5
    local topY = cy - height / 2

    local e = rec.entry
    if not e then
        e = newPlayerEntry()
        rec.entry = e
    end

    e.box.Size = Vector2.new(width, height)
    e.box.Position = Vector2.new(sx - width / 2, topY)
    e.name.Position = Vector2.new(sx, math.max(topY - 17, 2))

    -- write the colour only when it actually changes, so a single stray frame can
    -- never blink the beast box in the survivor colour
    local color = isBeast and CFG.beast or CFG.survivor
    if e.color ~= color then
        e.color = color
        e.box.Color = color
        e.name.Color = color
    end

    if doText or e.lastName == "" then
        local label = rec.name
        if isBeast then label = "[BEAST] " .. label end
        local showDist = isBeast and CFG.beastDist or CFG.showDist
        if showDist then label = label .. "  " .. math.floor(dist) .. "m" end
        if e.lastName ~= label then
            e.lastName = label
            e.name.Text = label
        end
    end

    local tr = e.tracer
    if tr then
        if CFG.tracers == true then
            tr.From = Vector2.new(vpX / 2, vpY)
            tr.To = Vector2.new(sx, topY + height)
            tr.Color = color
            tr.Visible = true
        else
            tr.Visible = false
        end
    end

    rec.stamp = frame
    setShown(e, true)
end

local function updateObject(rec, camPos, doText)
    local k = KINDS[rec.kind]
    if not k or not CFG[k.enabler] then return end
    local b = rec.bounds
    if not b then return end
    if not rec.inst.Parent then return end
    -- A green screen is the game saying this terminal is finished, so it wins.
    -- The count based guess is only used on maps that never repaint the screen.
    if CFG.hideHacked and (rec.done == true or (rec.done == nil and rec.hacked)) then return end

    local c = b.center
    local top = Vector3.new(c.X, c.Y + b.halfY, c.Z)
    local bottom = Vector3.new(c.X, c.Y - b.halfY, c.Z)
    local st, okTop = WorldToScreen(top)
    local sb, okBottom = WorldToScreen(bottom)
    if not (okTop and okBottom and st and sb) then return end

    local dist = (camPos - c).Magnitude
    if dist > CFG.maxDistance then return end

    local e = rec.entry
    if not e then
        e = newObjectEntry(rec.kind)
        rec.entry = e
    end

    local fullHeight = sb.Y - st.Y
    if fullHeight < 8 then fullHeight = 8 end

    local scale = CFG[k.scaleId] or 0.2
    local height = fullHeight * scale
    if height < 8 then height = 8 elseif height > 600 then height = 600 end
    local width = height * b.aspect
    if width < 8 then width = 8 elseif width > 600 then width = 600 end

    local cx = (st.X + sb.X) / 2
    local cy = (st.Y + sb.Y) / 2
    local topY = cy - height / 2

    e.box.Size = Vector2.new(width, height)
    e.box.Position = Vector2.new(cx - width / 2, topY)
    e.box.Color = k.color
    e.text.Position = Vector2.new(cx, math.max(topY - 15, 2))
    e.text.Color = k.color

    if doText or e.lastLabel == nil then
        local label = k.label
        if CFG[k.distId] then label = label .. "  " .. math.floor(dist) .. "m" end
        if e.lastLabel ~= label then
            e.lastLabel = label
            e.text.Text = label
        end
    end

    rec.stamp = frame
    setShown(e, true)
end

local function sweep()
    for _, rec in pairs(pcache) do
        local e = rec.entry
        if e and rec.stamp ~= frame then
            setShown(e, false)
        end
    end
    for _, rec in pairs(objs) do
        local e = rec.entry
        if e and rec.stamp ~= frame then
            setShown(e, false)
        end
    end
end

local cleaned = false
local menuAll = {}
local function destroyAll()
    for uid, rec in pairs(pcache) do
        if rec.entry then destroyEntry(rec.entry) end
        pcache[uid] = nil
    end
    for addr, rec in pairs(objs) do
        if rec.entry then destroyEntry(rec.entry) end
        objs[addr] = nil
    end
    if not cleaned then
        cleaned = true
        for _, d in ipairs(menuAll) do pcall(function() d:Remove() end) end
    end
end

-- ==========================================
-- Menu (Drawing overlay; this VM cannot build Instances)
-- dark theme, red accent, tabbed sidebar + cards
-- ==========================================
local C = {
    win = Color3.fromRGB(12, 12, 15),
    winBorder = Color3.fromRGB(46, 46, 55),
    side = Color3.fromRGB(9, 9, 11),
    line = Color3.fromRGB(31, 31, 38),
    top = Color3.fromRGB(18, 18, 22),
    card = Color3.fromRGB(24, 24, 29),
    cardBorder = Color3.fromRGB(44, 44, 53),
    header = Color3.fromRGB(32, 32, 39),
    accent = Color3.fromRGB(236, 26, 36),
    text = Color3.fromRGB(236, 236, 242),
    dim = Color3.fromRGB(168, 168, 178),
    mute = Color3.fromRGB(116, 116, 126),
    track = Color3.fromRGB(52, 52, 60),
    knob = Color3.fromRGB(240, 240, 246),
}

local TOPBAR = 30    -- draggable strip along the top edge
local SIDEBAR = 132
local PADX = 14
local CARD_HDR = 26
local ROW_H = 22
local M = { open = true, x = 80, y = 80, w = 560, h = 240, minH = 240 }

local CUR_TAB = 1
local HITS = {}
local menuDirty = true
local listening = false -- waiting for the user to press a new menu key

-- keycodes offered while rebinding, with their display names
local KEY_NAMES = {
    [0x08] = "Backspace", [0x09] = "Tab", [0x0D] = "Enter", [0x10] = "Shift",
    [0x11] = "Ctrl", [0x12] = "Alt", [0x14] = "CapsLock", [0x1B] = "Escape",
    [0x20] = "Space", [0x21] = "PageUp", [0x22] = "PageDown", [0x23] = "End",
    [0x24] = "Home", [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down",
    [0x2D] = "Insert", [0x2E] = "Delete",
    [0xBA] = ";", [0xBB] = "=", [0xBC] = ",", [0xBD] = "-", [0xBE] = ".", [0xBF] = "/",
}
for c = 0x30, 0x39 do KEY_NAMES[c] = string.char(c) end
for c = 0x41, 0x5A do KEY_NAMES[c] = string.char(c) end
for i = 1, 12 do KEY_NAMES[0x70 + i - 1] = "F" .. i end

local KEY_LIST = {}
for code in pairs(KEY_NAMES) do KEY_LIST[#KEY_LIST + 1] = code end

local SECTIONS = {
    { label = "PLAYER", items = { { label = "ESP", tab = 1 } } },
    { label = "MAP", items = { { label = "Objects", tab = 2 } } },
    { label = "VISUALS", items = { { label = "World", tab = 3 } } },
    { label = "CONFIG", items = { { label = "Settings", tab = 4 } } },
}

local TAB_CARDS = {
    [1] = { "players", "beast", "computers" },
    [2] = { "exits", "pods" },
    [3] = { "visuals" },
    [4] = { "settings", "render" },
}

-- Config save/load. CFG also holds Color3 values, which JSON cannot carry, so
-- only booleans, numbers and strings are written; every other key keeps its
-- default. The file lands in the executor's sandboxed workspace folder.
local CONFIG_FILE = "flee-esp-config.json"

-- Both are deliberately silent: the button labels never change, so pressing Save
-- or Load shows nothing on screen. All file work is pcall'd, so a blocked write
-- fails quietly instead of erroring into the render loop.
local function saveConfig()
    local out = {}
    for k, v in pairs(CFG) do
        local t = type(v)
        if t == "boolean" or t == "number" or t == "string" then out[k] = v end
    end
    local ok, json = pcall(function() return game:GetService("HttpService"):JSONEncode(out) end)
    if not ok or type(json) ~= "string" then return end
    pcall(function() writefile(CONFIG_FILE, json) end)
end

local function loadConfig()
    local ok, data = pcall(function() return readfile(CONFIG_FILE) end)
    if not ok or type(data) ~= "string" or data == "" then return end
    local okD, tbl = pcall(function() return game:GetService("HttpService"):JSONDecode(data) end)
    if not okD or type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
        local cur = CFG[k]
        local t = type(v)
        if cur ~= nil and type(cur) == t and (t == "boolean" or t == "number" or t == "string") then
            CFG[k] = v
        end
    end
    menuDirty = true
end

local CARDS = {
    players = {
        title = "Survivor ESP",
        toggle = "survivorESP",
        rows = {
            { kind = "toggle", id = "showDist", label = "Distance" },
        },
    },
    beast = {
        title = "Beast ESP",
        toggle = "beastESP",
        rows = {
            { kind = "toggle", id = "beastDist", label = "Distance" },
        },
    },
    computers = {
        title = "Computer ESP",
        toggle = "computerESP",
        rows = {
            { kind = "toggle", id = "computerDist", label = "Distance" },
            { kind = "toggle", id = "hideHacked", label = "Hide Hacked" },
        },
    },
    exits = {
        title = "Exit ESP",
        toggle = "exitESP",
        rows = {
            { kind = "toggle", id = "exitDist", label = "Distance" },
        },
    },
    pods = {
        title = "Freeze Pod ESP",
        toggle = "podESP",
        rows = {
            { kind = "toggle", id = "podDist", label = "Distance" },
        },
    },
    visuals = {
        title = "Visuals",
        rows = {
            { kind = "toggle", id = "tracers", label = "Tracers" },
            { kind = "toggle", id = "hud", label = "Match HUD" },
        },
    },
    settings = {
        title = "Menu",
        rows = {
            { kind = "key", id = "menuKey", label = "Keybind" },
            { kind = "button", id = "saveConfig", label = "Save Config", fn = saveConfig },
            { kind = "button", id = "loadConfig", label = "Load Config", fn = loadConfig },
        },
    },
    render = {
        title = "Render",
        rows = {
            { kind = "slider", id = "maxDistance", label = "Range", min = 300, max = 5000, fmt = "%.0f" },
        },
    },
}

-- Two square pools (rounded for panels/pills, plain for hairlines) plus a text pool.
-- Drawings are created once and reused; the unused tail is hidden on every redraw.
local SQ_ROUND, SQ_PLAIN, TX_POOL = {}, {}, {}
local sqN, spN, txtN = 0, 0, 0

for i = 1, 140 do
    local s = Drawing.new("Square")
    s.Color = C.text
    s.Filled = true
    s.Thickness = 1
    s.ZIndex = 10
    -- never write Transparency on a Square: any write makes the shape disappear in this VM
    s.Visible = false
    pcall(function() s.Rounding = 4 end)
    SQ_ROUND[i] = s
    menuAll[#menuAll + 1] = s
end
for i = 1, 90 do
    local s = Drawing.new("Square")
    s.Color = C.text
    s.Filled = true
    s.Thickness = 1
    s.ZIndex = 9
    s.Visible = false
    SQ_PLAIN[i] = s
    menuAll[#menuAll + 1] = s
end
for i = 1, 110 do
    local t = Drawing.new("Text")
    t.Size = 12
    t.Color = C.text
    t.ZIndex = 11
    t.Outline = false
    t.Visible = false
    pcall(function() t.Font = BOLD_FONT end)
    TX_POOL[i] = t
    menuAll[#menuAll + 1] = t
end

local function rq(x, y, w, h, color, z)
    sqN = sqN + 1
    local s = SQ_ROUND[sqN]
    if not s then return nil end
    s.Position = Vector2.new(x, y)
    s.Size = Vector2.new(w, h)
    s.Color = color
    s.ZIndex = z or 10
    s.Visible = true
    return s
end

local function pq(x, y, w, h, color, z)
    spN = spN + 1
    local s = SQ_PLAIN[spN]
    if not s then return nil end
    s.Position = Vector2.new(x, y)
    s.Size = Vector2.new(w, h)
    s.Color = color
    s.ZIndex = z or 9
    s.Visible = true
    return s
end

local function stroke(x, y, w, h, color, z)
    pq(x, y, w, 1, color, z)
    pq(x, y + h - 1, w, 1, color, z)
    pq(x, y + 1, 1, h - 2, color, z)
    pq(x + w - 1, y + 1, 1, h - 2, color, z)
end

local function tx(x, y, text, size, color, center, z)
    txtN = txtN + 1
    local t = TX_POOL[txtN]
    if not t then return nil end
    t.Position = Vector2.new(x, y)
    t.Size = size
    t.Color = color
    t.Center = center == true
    t.Text = text
    t.ZIndex = z or 11
    t.Visible = true
    return t
end

local function drawCard(id, x, y, w)
    local card = CARDS[id]
    local rows = card.rows or {}
    local h = CARD_HDR + #rows * ROW_H + 8
    rq(x, y, w, h, C.card, 10)
    stroke(x, y, w, h, C.cardBorder, 10)
    rq(x, y, w, CARD_HDR, C.header, 10)
    rq(x + 10, y + 9, 8, 8, C.accent, 11)
    tx(x + 24, y + 7, card.title, 12, C.text, false, 11)

    if card.toggle then
        local on = CFG[card.toggle] == true
        local pw, ph = 24, 12
        local px, py = x + w - pw - 10, y + 7
        rq(px, py, pw, ph, on and C.accent or C.track, 11)
        rq(on and (px + pw - ph + 2) or (px + 2), py + 2, ph - 4, ph - 4, C.knob, 12)
        HITS[#HITS + 1] = { x = px - 4, y = py - 4, w = pw + 8, h = ph + 8, kind = "toggle", id = card.toggle }
    end

    -- Every row centres its content on the same line, so labels, pills and key
    -- boxes share one baseline instead of each kind picking its own offset.
    local ry = y + CARD_HDR + 5
    for _, row in ipairs(rows) do
        if row.kind == "toggle" then
            local on = CFG[row.id] == true
            tx(x + 12, ry + 5, row.label, 12, C.dim, false, 11)
            local bx = x + w - 22
            rq(bx, ry + 5, 11, 11, on and C.accent or C.track, 11)
            if on then rq(bx + 3, ry + 8, 5, 5, C.knob, 12) end
            HITS[#HITS + 1] = { x = bx - 8, y = ry + 3, w = 26, h = 16, kind = "toggle", id = row.id }
        elseif row.kind == "slider" then
            local tw = w - 24
            local val = CFG[row.id]
            local f = (val - row.min) / (row.max - row.min)
            if f < 0 then f = 0 elseif f > 1 then f = 1 end
            tx(x + 12, ry + 1, row.label, 12, C.dim, false, 11)
            tx(x + w - 26, ry + 2, string.format(row.fmt, val), 10, C.mute, true, 11)
            pq(x + 12, ry + 15, tw, 3, C.track, 11)
            if f > 0 then rq(x + 12, ry + 15, tw * f, 3, C.accent, 12) end
            rq(x + 12 + tw * f - 2, ry + 12, 5, 9, C.knob, 12)
            HITS[#HITS + 1] = { x = x + 8, y = ry + 8, w = tw + 8, h = 14, kind = "slider", id = row.id,
                min = row.min, max = row.max, fmt = row.fmt, tx = x + 12, tw = tw }
        elseif row.kind == "key" then
            tx(x + 12, ry + 5, row.label, 12, C.dim, false, 11)
            local bw, bh = 78, 16
            local bx, by = x + w - bw - 12, ry + 3
            rq(bx, by, bw, bh, C.track, 11)
            tx(bx + bw / 2, by + 3, listening and "PRESS KEY" or CFG.menuKeyName, 10,
                listening and C.accent or C.text, true, 12)
            HITS[#HITS + 1] = { x = bx - 4, y = by - 2, w = bw + 8, h = bh + 4, kind = "key", id = row.id }
        elseif row.kind == "button" then
            local bw, bh = w - 24, 16
            local bx, by = x + 12, ry + 3
            rq(bx, by, bw, bh, C.track, 11)
            local label = row.label or row.id
            tx(bx + bw / 2, by + 3, label, 10, C.accent, true, 12)
            HITS[#HITS + 1] = { x = bx, y = by, w = bw, h = bh, kind = "button", fn = row.fn }
        end
        ry = ry + ROW_H
    end
    return h
end

-- Window height follows the tab being shown: cards stack in two columns, so a
-- tab with three two-row cards or a fourth sidebar group would otherwise clip.
local function requiredHeight()
    local colH = { 0, 0 }
    local list = TAB_CARDS[CUR_TAB] or {}
    for i = 1, #list do
        local card = CARDS[list[i]]
        if card then
            local col = ((i - 1) % 2) + 1
            local ch = CARD_HDR + #(card.rows or {}) * ROW_H + 8
            if colH[col] > 0 then colH[col] = colH[col] + 12 end
            colH[col] = colH[col] + ch
        end
    end
    local sideH = TOPBAR + 16
    for _, section in ipairs(SECTIONS) do
        sideH = sideH + 20 + #section.items * 24 + 8
    end
    local need = math.max(sideH, TOPBAR + PADX * 2 + math.max(colH[1], colH[2]))
    if need < M.minH then need = M.minH end
    return need
end

local function drawMenu()
    sqN, spN, txtN = 0, 0, 0
    HITS = {}
    if not M.open then return end

    M.h = requiredHeight()
    local x, y, w, h = M.x, M.y, M.w, M.h

    rq(x, y, w, h, C.win, 8)
    stroke(x, y, w, h, C.winBorder, 8)
    rq(x, y, SIDEBAR, h, C.side, 9)
    pq(x + SIDEBAR, y + 1, 1, h - 2, C.line, 9)
    rq(x, y, w, TOPBAR, C.top, 9)
    pq(x, y + TOPBAR, w, 1, C.line, 9)
    rq(x + PADX, y + 10, 3, 9, C.accent, 11)
    tx(x + PADX + 10, y + 7, "FLEE THE FACILITY", 13, C.text, false, 11)

    local ty = y + TOPBAR + 16
    for _, section in ipairs(SECTIONS) do
        tx(x + PADX, ty, section.label, 10, C.mute, false, 10)
        ty = ty + 20
        for _, item in ipairs(section.items) do
            local active = item.tab == CUR_TAB
            if active then
                rq(x + 1, ty - 4, SIDEBAR - 2, 21, C.header, 10)
                pq(x + 1, ty - 4, 2, 21, C.accent, 11)
            end
            tx(x + PADX + 10, ty, item.label, 12, active and C.text or C.dim, false, 11)
            HITS[#HITS + 1] = { x = x, y = ty - 4, w = SIDEBAR - 2, h = 21, kind = "tab", id = item.tab }
            ty = ty + 24
        end
        ty = ty + 8
    end

    local list = TAB_CARDS[CUR_TAB] or {}
    local cx0 = x + SIDEBAR + PADX
    local availW = w - SIDEBAR - PADX * 2
    local colW = #list > 1 and (availW - 12) / 2 or availW
    local cy0 = y + TOPBAR + PADX
    local colY = { cy0, cy0 }
    for i = 1, #list do
        local col = (i - 1) % 2
        local cardH = drawCard(list[i], cx0 + col * (colW + 12), colY[col + 1], colW)
        colY[col + 1] = colY[col + 1] + cardH + 12
    end

    for i = sqN + 1, #SQ_ROUND do SQ_ROUND[i].Visible = false end
    for i = spN + 1, #SQ_PLAIN do SQ_PLAIN[i].Visible = false end
    for i = txtN + 1, #TX_POOL do TX_POOL[i].Visible = false end
end

-- ==========================================
-- Match HUD (bottom-left; built once, independent of the menu so it can stay up)
-- ==========================================
local HUD = { lines = {}, text = { "", "", "", "", "" } }
HUD.bg = Drawing.new("Square")
HUD.bg.Filled = true
HUD.bg.Thickness = 1
HUD.bg.Color = C.win
HUD.bg.ZIndex = 7
HUD.bg.Visible = false
pcall(function() HUD.bg.Rounding = 4 end)
HUD.bar = Drawing.new("Square")
HUD.bar.Filled = true
HUD.bar.Thickness = 1
HUD.bar.Color = C.accent
HUD.bar.ZIndex = 8
HUD.bar.Visible = false
HUD.title = newText(12)
HUD.title.Center = false
HUD.title.Outline = false
HUD.title.Color = C.text
HUD.title.ZIndex = 11
HUD.title.Visible = false
for i = 1, #HUD.text do
    local t = newText(12)
    t.Center = false
    t.Outline = false
    t.Color = C.dim
    t.ZIndex = 11
    t.Visible = false
    HUD.lines[i] = t
end

-- removed with the rest of the overlay on unload, so nothing is left on screen
menuAll[#menuAll + 1] = HUD.bg
menuAll[#menuAll + 1] = HUD.bar
menuAll[#menuAll + 1] = HUD.title
for i = 1, #HUD.lines do menuAll[#menuAll + 1] = HUD.lines[i] end

local function refreshHUD()
    local cam = Workspace.CurrentCamera
    local camp = cam and cam.CFrame.Position
    local localChar = LocalPlayer.Character
    local myPack = LocalPlayer:FindFirstChild("Backpack")
    local meBeast = (localChar ~= nil and hasBeastTag(localChar))
        or (myPack ~= nil and hasBeastTag(myPack))
    local survivors, beastName, beastDist = 0, nil, nil
    for _, rec in pairs(pcache) do
        local hrp, hum = rec.hrp, rec.hum
        if hrp and hrp.Parent and hum and hum.Health > 0 then
            local pos = hrp.Position
            if not inLobby(pos) then
                if rec.tagged then
                    beastName = rec.name
                    if camp then beastDist = (camp - pos).Magnitude end
                else
                    survivors = survivors + 1
                end
            end
        end
    end
    -- pcache never holds the local player, so add yourself back to the count
    if not meBeast then survivors = survivors + 1 end

    local compTotal = 0
    for _, rec in pairs(objs) do
        if rec.kind == "computer" and rec.inst.Parent then
            compTotal = compTotal + 1
        end
    end

    HUD.text[1] = "SURVIVORS  " .. survivors
    if meBeast then
        HUD.text[2] = "BEAST  you"
    elseif beastName then
        HUD.text[2] = "BEAST  " .. beastName .. "  " .. math.floor(beastDist or 0) .. "m"
    else
        HUD.text[2] = "BEAST  not in round"
    end
    -- round info straight from the game: computers still standing
    local left = readValue("ComputersLeft")
    HUD.text[3] = "COMPUTERS  " .. compTotal .. (type(left) == "number" and ("   LEFT " .. left) or "")
    HUD.text[4] = "FPS  " .. math.floor(fpsNow)
    HUD.text[5] = ""
end

local function drawHUD()
    local show = CFG.hud == true
    local rows = {}
    for i = 1, #HUD.text do
        if HUD.text[i] ~= "" then rows[#rows + 1] = HUD.text[i] end
    end
    local n = #rows
    local w, rh, hh = 216, 15, 24
    local h = hh + n * rh + 6
    local x, y = 16, vpY - h - 16
    if y < 16 then y = 16 end

    HUD.bg.Visible = show
    HUD.bar.Visible = show
    HUD.title.Visible = show
    for i = 1, #HUD.lines do HUD.lines[i].Visible = show and i <= n end
    if not show then return end

    HUD.bg.Position = Vector2.new(x, y)
    HUD.bg.Size = Vector2.new(w, h)
    HUD.bar.Position = Vector2.new(x, y)
    HUD.bar.Size = Vector2.new(3, h)
    HUD.title.Position = Vector2.new(x + 12, y + 5)
    HUD.title.Text = "FLEE THE FACILITY"
    for i = 1, n do
        local t = HUD.lines[i]
        if t.Text ~= rows[i] then t.Text = rows[i] end
        t.Position = Vector2.new(x + 12, y + hh + (i - 1) * rh)
    end
end

local function setMenuOpen(state)
    M.open = state
    menuDirty = true
    if state then
        drawMenu()
    else
        for i = 1, #SQ_ROUND do SQ_ROUND[i].Visible = false end
        for i = 1, #SQ_PLAIN do SQ_PLAIN[i].Visible = false end
        for i = 1, #TX_POOL do TX_POOL[i].Visible = false end
    end
end

local function mousePos()
    local ok, m = pcall(function() return LocalPlayer:GetMouse() end)
    if ok and m and m.X and m.Y then return m.X, m.Y end
    return -1, -1
end

local function applySlider(hit, mx)
    local f = (mx - hit.tx) / hit.tw
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    local val = hit.min + (hit.max - hit.min) * f
    if hit.fmt == "%d" then val = math.floor(val + 0.5) end
    CFG[hit.id] = val
end

local dragging, dragOffX, dragOffY = false, 0, 0
local sliderHit = nil
local prevClick, prevKey = false, false

-- Bind mode: remember which keys are already down, then take the first new one.
local armDown = {}

local function startBind()
    listening = true
    armDown = {}
    for i = 1, #KEY_LIST do
        local code = KEY_LIST[i]
        local ok, held = pcall(iskeypressed, code)
        if ok and held then armDown[code] = true end
    end
    menuDirty = true
end

local function pollBind()
    for i = 1, #KEY_LIST do
        local code = KEY_LIST[i]
        if not armDown[code] then
            local ok, held = pcall(iskeypressed, code)
            if ok and held then
                listening = false
                if code ~= 0x1B then -- Escape cancels
                    CFG.menuKey = code
                    CFG.menuKeyName = KEY_NAMES[code] or ("0x" .. string.format("%02X", code))
                end
                menuDirty = true
                return true
            end
        end
    end
    return false
end

local function menuStep()
    if listening then
        pollBind()
        local okC, c = pcall(ismouse1pressed)
        prevClick = okC and c == true
        prevKey = true
        return
    end

    local okK, held = pcall(iskeypressed, CFG.menuKey)
    local keyDown = okK and held == true
    if keyDown and not prevKey then setMenuOpen(not M.open) end
    prevKey = keyDown

    local okC, c = pcall(ismouse1pressed)
    local down = okC and c == true

    if not M.open then
        prevClick = down
        dragging, sliderHit = false, nil
        return
    end

    local mx, my = mousePos()

    if down and not prevClick then
        if mx >= M.x and mx <= M.x + M.w and my >= M.y and my <= M.y + TOPBAR then
            dragging = true
            dragOffX, dragOffY = mx - M.x, my - M.y
        else
            for i = 1, #HITS do
                local hit = HITS[i]
                if mx >= hit.x and mx <= hit.x + hit.w and my >= hit.y and my <= hit.y + hit.h then
                    if hit.kind == "tab" then
                        if CUR_TAB ~= hit.id then
                            CUR_TAB = hit.id
                            menuDirty = true
                        end
                    elseif hit.kind == "toggle" then
                        CFG[hit.id] = not CFG[hit.id]
                        menuDirty = true
                    elseif hit.kind == "slider" then
                        sliderHit = hit
                        applySlider(hit, mx)
                        menuDirty = true
                    elseif hit.kind == "key" then
                        startBind()
                    elseif hit.kind == "button" then
                        if hit.fn then pcall(hit.fn) end
                        menuDirty = true
                    end
                    break
                end
            end
        end
    elseif down and dragging then
        M.x = mx - dragOffX
        M.y = my - dragOffY
        menuDirty = true
    elseif down and sliderHit then
        applySlider(sliderHit, mx)
        menuDirty = true
    end

    if not down then
        dragging, sliderHit = false, nil
    end
    prevClick = down
end

setMenuOpen(true)

-- ==========================================
-- Render loop
-- ==========================================
RunService.RenderStepped:Connect(function()
    if not running then
        destroyAll()
        return
    end

    frame = frame + 1

    -- FPS is sampled once a second and shown in the HUD
    fpsFrames = fpsFrames + 1
    local nowTick = tick()
    if nowTick - fpsTime >= 1 then
        fpsNow = fpsFrames / (nowTick - fpsTime)
        fpsFrames, fpsTime = 0, nowTick
    end

    pcall(menuStep)
    if menuDirty then
        pcall(drawMenu)
        menuDirty = false
    end

    if frame % 15 == 0 then pcall(refreshHUD) end
    pcall(drawHUD)

    local Camera = Workspace.CurrentCamera
    if Camera then
        local camPos = Camera.CFrame.Position
        local doText = textDirty
        textDirty = false

        for _, rec in pairs(pcache) do
            if not pcall(updatePlayer, rec, camPos, doText) then
                rec.hrp = nil -- skip until the slow loop refreshes it
            end
        end
        for _, rec in pairs(objs) do
            pcall(updateObject, rec, camPos, doText)
        end
    end

    -- always runs: hides every entry that wasn't updated this frame
    sweep()
end)
