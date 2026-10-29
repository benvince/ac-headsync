-- Head Sync v1.1 — https://github.com/benvince/ac-headsync
-- Lets other players see your head move online (turn, nod, tilt).
-- Every player needs this app installed, on a server that relays CSP client
-- messages (AssettoServer with EnableClientMessages: true).

---------------------------------------------------------------------------
-- TWEAKS
---------------------------------------------------------------------------
local HEAD_FILTER = '{ DRIVER:RIG_Head }'  -- standard Kunos driver rig head bone
local SEND_HZ     = 15                     -- messages per second; keep it modest
local SMOOTHING   = 10                     -- higher = snappier, lower = smoother

local MAX_YAW     = math.rad(80)           -- clamps, so nobody goes full owl
local MAX_PITCH   = math.rad(40)
local MAX_ROLL    = math.rad(35)

local YAW_SIGN    = 1                      -- flip to -1 if a movement goes the wrong way
local PITCH_SIGN  = 1
local ROLL_SIGN   = 1
-- Auto-recentre: a VR recentre makes your head snap instantly, faster than any
-- real head can move, so a sudden jump in one frame is treated as a recentre.
local AUTO_RECENTRE     = true
local SNAP_ANGLE        = math.rad(25)     -- turn in a single frame that counts as a snap
local SNAP_DISTANCE     = 0.08             -- metres in a single frame that counts as a snap
local SNAP_SETTLE       = 0.3              -- seconds to wait before grabbing the new neutral
local RECENTRE_KEY      = nil              -- optionally bind a key, e.g. ui.KeyIndex.Home

local YAW_AXIS    = vec3(0, 1, 0)          -- bone-local rotation axes
local PITCH_AXIS  = vec3(1, 0, 0)
local ROLL_AXIS   = vec3(0, 0, 1)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local remote = {}          -- [carIndex] = smoothed + target values
local headNodes = {}
local baseTransforms = {}  -- [carIndex][i] = resting head transform (local)
local sendTimer = 0
local enabled, applyRoll = true, true
local rest = nil           -- our own resting roll, for recentring

local test = { on = false, sweep = false, t = 0, yaw = 0, pitch = 0, roll = 0 }

local FIELDS = { 'yaw', 'pitch', 'roll' }

local function findNodes(cache, carIndex, filter)
  local n = cache[carIndex]
  if n == nil then
    n = ac.findNodes('carRoot:' .. carIndex):findNodes(filter)
    cache[carIndex] = n
  end
  return n
end

local function nodeAt(group, i)
  local ok, n = pcall(function () return group:at(i) end)
  if ok and n then return n end
  return group
end

local function resetBones()
  headNodes, baseTransforms, rest = {}, {}, nil
end

---------------------------------------------------------------------------
-- Networking
---------------------------------------------------------------------------
local sendHead = ac.OnlineEvent({
  ac.StructItem.key('benHeadSync_v3'),
  yaw   = ac.StructItem.float(),
  pitch = ac.StructItem.float(),
  roll  = ac.StructItem.float(),
}, function (sender, msg)
  if sender == nil or sender.index == 0 then return end
  local r = remote[sender.index]
  if not r then
    r = { yaw = 0, pitch = 0, roll = 0, t = {} }
    remote[sender.index] = r
  end
  r.t.yaw   = math.clamp(msg.yaw,   -MAX_YAW,   MAX_YAW)
  r.t.pitch = math.clamp(msg.pitch, -MAX_PITCH, MAX_PITCH)
  r.t.roll  = math.clamp(msg.roll,  -MAX_ROLL,  MAX_ROLL)
  r.lastSeen = os.preciseClock()
end)

---------------------------------------------------------------------------
-- Reading our own head
-- CSP turns your own driver's head bone to follow VR, so we read it from there.
---------------------------------------------------------------------------
local function ownHeadWorld()
  local n = findNodes(headNodes, 0, HEAD_FILTER)
  if not n or #n == 0 then return nil end
  local ok, m = pcall(function () return n:getWorldTransformationRaw() end)
  if ok and m then return m end
  return nil
end

-- Head angles relative to the car, in radians.
local function readOwnHead()
  local m = ownHeadWorld()
  if not m then return nil end
  local car = ac.getCar(0)
  local look = m.look:clone():normalize()
  local side = m.side:clone():normalize()
  local up   = m.up:clone():normalize()

  local yaw   = math.atan2(look:dot(car.side), look:dot(car.look))
  local pitch = math.asin(math.clamp(look:dot(car.up), -1, 1))
  local roll  = math.atan2(side:dot(car.up), up:dot(car.up))

  -- First reading (or after Recentre) becomes "neutral" for roll
  if not rest then rest = { roll = roll } end

  return {
    yaw   = yaw * YAW_SIGN,
    pitch = pitch * PITCH_SIGN,
    roll  = (roll - rest.roll) * ROLL_SIGN,
  }
end

-- Watch for the instant jump a VR recentre causes, then grab a fresh neutral
local prevRaw, settleTimer, lastRecentre = nil, nil, nil

local function checkRecentre(dt)
  if RECENTRE_KEY and ac.isKeyPressed(RECENTRE_KEY) then
    rest, lastRecentre = nil, os.preciseClock()
  end
  if not AUTO_RECENTRE then return end

  if settleTimer then
    settleTimer = settleTimer - dt
    if settleTimer <= 0 then
      settleTimer, rest, lastRecentre = nil, nil, os.preciseClock()
    end
  end

  local m = ownHeadWorld()
  if not m then prevRaw = nil; return end
  local car = ac.getCar(0)
  local look = m.look:clone():normalize()
  local d = m.position - car.position
  local raw = {
    yaw = math.atan2(look:dot(car.side), look:dot(car.look)),
    pos = vec3(d:dot(car.side), d:dot(car.up), d:dot(car.look)),
  }
  if prevRaw then
    local dYaw = math.abs((raw.yaw - prevRaw.yaw + math.pi) % (2 * math.pi) - math.pi)
    local dPos = raw.pos:distance(prevRaw.pos)
    if dYaw > SNAP_ANGLE or dPos > SNAP_DISTANCE then
      settleTimer = SNAP_SETTLE
    end
  end
  prevRaw = raw
end

---------------------------------------------------------------------------
-- Applying other people's heads
---------------------------------------------------------------------------
local function applyHead(idx, r)
  local heads = findNodes(headNodes, idx, HEAD_FILTER)
  if not heads or #heads == 0 then return end

  local rot = mat4x4.rotation(r.pitch, PITCH_AXIS):mul(mat4x4.rotation(r.yaw, YAW_AXIS))
  if applyRoll then rot = mat4x4.rotation(r.roll, ROLL_AXIS):mul(rot) end

  baseTransforms[idx] = baseTransforms[idx] or {}
  local bases = baseTransforms[idx]
  for i = 1, #heads do
    local head = nodeAt(heads, i)
    local m = head:getTransformationRaw()
    if not bases[i] then bases[i] = m:clone() end

    -- Always rotate from the resting pose (nothing resets the bone each frame)
    m:set(rot:mul(bases[i]))

    if head == heads then break end
  end
end

---------------------------------------------------------------------------
-- Per-frame
---------------------------------------------------------------------------
function script.update(dt)
  if not enabled or not ac.getSim().isOnlineRace then return end

  if not test.on then checkRecentre(dt) end

  -- Test mode: fake values, sent to others and shown on your own driver
  local fake = nil
  if test.on then
    if test.sweep then
      test.t = test.t + dt
      test.yaw   = math.sin(test.t * 1.2) * 60
      test.pitch = math.sin(test.t * 0.7) * 20
      test.roll  = math.sin(test.t * 0.9) * 20
    end
    fake = { yaw = math.rad(test.yaw), pitch = math.rad(test.pitch), roll = math.rad(test.roll) }
    remote[0] = remote[0] or { yaw = 0, pitch = 0, roll = 0, t = {} }
    for _, f in ipairs(FIELDS) do remote[0].t[f] = fake[f] end
    remote[0].lastSeen = os.preciseClock()
  else
    remote[0] = nil
  end

  -- Send ours
  sendTimer = sendTimer + dt
  if sendTimer > 1 / SEND_HZ then
    sendTimer = 0
    local h = fake or readOwnHead()
    if h then sendHead(h) end
  end

  -- Apply everyone else's
  local now = os.preciseClock()
  local k = math.min(1, dt * SMOOTHING)
  for idx, r in pairs(remote) do
    local stale = now - (r.lastSeen or 0) > 2   -- drift back to centre if they've gone quiet
    for _, f in ipairs(FIELDS) do
      r[f] = math.lerp(r[f], stale and 0 or (r.t[f] or 0), k)
    end
    applyHead(idx, r)
  end
end

---------------------------------------------------------------------------
-- Debug tools: find the head bone on unusual driver models
---------------------------------------------------------------------------
local scanResults = {}
local CANDIDATES = {
  'DRIVER:RIG_Head', 'DRIVER:HEAD', 'HEAD', 'Head', 'head', 'NECK', 'Neck',
  '?HEAD?', '?Head?', '?head?', '?NECK?', '?Neck?', '?Nek?',
}

local function scanBones()
  scanResults = {}
  local root = ac.findNodes('carRoot:0')
  for _, f in ipairs(CANDIDATES) do
    local ok, nodes = pcall(function () return root:findNodes('{ ' .. f .. ' }') end)
    if ok and nodes and #nodes > 0 then
      local names = {}
      for i = 1, math.min(#nodes, 4) do
        local okn, nm = pcall(function () return nodes:name(i) end)
        names[#names + 1] = okn and tostring(nm) or '?'
      end
      scanResults[#scanResults + 1] = f .. ' -> ' .. #nodes .. ': ' .. table.concat(names, ', ')
    end
  end
  if #scanResults == 0 then scanResults = { 'Nothing matched any candidate' } end
end

local dumpStatus = ''
local function dumpTree()
  local lines = {}
  local function walk(node, depth)
    if depth > 40 or #lines > 20000 then return end
    local okn, nm = pcall(function () return node:name(1) end)
    lines[#lines + 1] = string.rep('  ', depth) .. (okn and tostring(nm) or '?')
    local okc, count = pcall(function () return node:getChildrenCount() end)
    if okc and count then
      for i = 1, count do
        local ok, child = pcall(function () return node:getChild(i) end)
        if ok and child then walk(child, depth + 1) end
      end
    end
  end
  walk(ac.findNodes('carRoot:0'), 0)
  local path = (__dirname or '.') .. '/nodes.txt'
  local ok = pcall(function () io.save(path, table.concat(lines, '\n')) end)
  dumpStatus = ok and ('Saved ' .. #lines .. ' nodes to ' .. path) or 'Save failed'
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
function windowMain(dt)
  if ui.checkbox('Enabled', enabled) then enabled = not enabled end
  if ui.checkbox('Show head tilt (roll)', applyRoll) then applyRoll = not applyRoll end

  ui.separator()
  if ui.checkbox('Test mode (fake head)', test.on) then test.on = not test.on end
  if test.on then
    if ui.checkbox('Auto sweep', test.sweep) then test.sweep = not test.sweep end
    if not test.sweep then
      test.yaw   = ui.slider('##yaw',   test.yaw,   -80, 80, 'Yaw: %.0f°')
      test.pitch = ui.slider('##pitch', test.pitch, -40, 40, 'Pitch: %.0f°')
      test.roll  = ui.slider('##roll',  test.roll,  -35, 35, 'Roll: %.0f°')
      if ui.button('Centre') then test.yaw, test.pitch, test.roll = 0, 0, 0 end
    end
  end

  ui.separator()
  local h = readOwnHead()
  if h then
    ui.text(string.format('You: yaw %.0f°  pitch %.0f°  roll %.0f°',
      math.deg(h.yaw), math.deg(h.pitch), math.deg(h.roll)))
  else
    ui.text('You: head bone not found')
  end
  if ui.button('Recentre (sit normally, look ahead)') then rest, lastRecentre = nil, os.preciseClock() end
  if ui.checkbox('Auto-recentre with VR recentre', AUTO_RECENTRE) then AUTO_RECENTRE = not AUTO_RECENTRE end
  if lastRecentre then
    ui.text(string.format('Last recentred %.0fs ago', os.preciseClock() - lastRecentre))
  end

  local count = 0
  for i in pairs(remote) do if i ~= 0 then count = count + 1 end end
  ui.text('Players sending heads: ' .. count)
  if ui.button('Re-find head bones') then resetBones() end

  ui.separator()
  local n0 = findNodes(headNodes, 0, HEAD_FILTER)
  ui.text('Head bones on your car: ' .. (n0 and #n0 or 0))
  if ui.button('Scan for head bones') then scanBones() end
  ui.sameLine()
  if ui.button('Dump node tree') then dumpTree() end
  for _, line in ipairs(scanResults) do ui.text(line) end
  if dumpStatus ~= '' then ui.textWrapped(dumpStatus) end
end
