-- Head Sync v1.0 — https://github.com/benvince/ac-headsync
-- Lets other players see your head move online: turning, nodding and tilting.
-- Every player needs this app installed, on a server that relays CSP client
-- messages (AssettoServer with EnableClientMessages: true).

---------------------------------------------------------------------------
-- TWEAKS
---------------------------------------------------------------------------
local HEAD_FILTER = '{ DRIVER:RIG_Head }'  -- standard Kunos driver rig head bone
local SEND_HZ     = 15                     -- messages per second; keep it modest
local SMOOTHING   = 10                     -- higher = snappier, lower = smoother

local MAX_YAW     = math.rad(90)           -- clamps, so nobody goes full owl
local MAX_PITCH   = math.rad(40)
local MAX_ROLL    = math.rad(35)

local YAW_SIGN    = 1                      -- flip to -1 if a movement goes the wrong way
local PITCH_SIGN  = -1
local ROLL_SIGN   = 1

local YAW_AXIS    = vec3(0, 1, 0)          -- bone-local rotation axes
local PITCH_AXIS  = vec3(1, 0, 0)
local ROLL_AXIS   = vec3(0, 0, 1)

-- Message format name. Only players with the same name here see each other,
-- so change it whenever the message layout changes.
local MESSAGE_KEY = 'benHeadSync_v4'

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local remote = {}          -- [carIndex] = { yaw, pitch, roll, t = targets, lastSeen }
local headNodes = {}       -- cached head bones per car
local baseTransforms = {}  -- [carIndex][i] = resting head transform
local sendTimer = 0
local enabled, showTilt = true, true
local restRoll = nil       -- your own head tilt when sitting normally
local sentCount, receivedCount, lastReceived = 0, 0, nil

local test = { on = false, sweep = false, t = 0, yaw = 0, pitch = 0, roll = 0 }

local function getHeadNode(carIndex)
  local n = headNodes[carIndex]
  if n == nil then
    n = ac.findNodes('carRoot:' .. carIndex):findNodes(HEAD_FILTER)
    headNodes[carIndex] = n
  end
  return n
end

local function newRemote()
  return { yaw = 0, pitch = 0, roll = 0, t = { yaw = 0, pitch = 0, roll = 0 } }
end

---------------------------------------------------------------------------
-- Networking
---------------------------------------------------------------------------
local sendHead = ac.OnlineEvent({
  ac.StructItem.key(MESSAGE_KEY),
  yaw   = ac.StructItem.float(),
  pitch = ac.StructItem.float(),
  roll  = ac.StructItem.float(),
}, function (sender, msg)
  if sender == nil or sender.index == 0 then return end  -- ignore server / ourselves
  local r = remote[sender.index]
  if not r then
    r = newRemote()
    remote[sender.index] = r
  end
  r.t.yaw   = math.clamp(msg.yaw,   -MAX_YAW,   MAX_YAW)
  r.t.pitch = math.clamp(msg.pitch, -MAX_PITCH, MAX_PITCH)
  r.t.roll  = math.clamp(msg.roll,  -MAX_ROLL,  MAX_ROLL)
  r.lastSeen = os.preciseClock()
  receivedCount, lastReceived = receivedCount + 1, r.lastSeen
end)

---------------------------------------------------------------------------
-- Reading your own head
-- CSP turns your own driver's head bone to follow VR, so we read it from there.
---------------------------------------------------------------------------
local function readOwnHead()
  local n = getHeadNode(0)
  if not n or #n == 0 then return nil end
  local ok, m = pcall(function () return n:getWorldTransformationRaw() end)
  if not ok or not m then return nil end

  local car = ac.getCar(0)
  local look = m.look:clone():normalize()
  local side = m.side:clone():normalize()
  local up   = m.up:clone():normalize()

  local yaw   = math.atan2(look:dot(car.side), look:dot(car.look))
  local pitch = math.asin(math.clamp(look:dot(car.up), -1, 1))
  local roll  = math.atan2(side:dot(car.up), up:dot(car.up))

  -- The first reading (or a Recentre) counts as "head upright"
  if not restRoll then restRoll = roll end

  return {
    yaw   = yaw * YAW_SIGN,
    pitch = pitch * PITCH_SIGN,
    roll  = (roll - restRoll) * ROLL_SIGN,
  }
end

---------------------------------------------------------------------------
-- Turning other people's heads
---------------------------------------------------------------------------
local function applyHead(idx, r)
  local heads = getHeadNode(idx)
  if not heads or #heads == 0 then return end

  local rot = mat4x4.rotation(r.pitch, PITCH_AXIS):mul(mat4x4.rotation(r.yaw, YAW_AXIS))
  if showTilt then rot = mat4x4.rotation(r.roll, ROLL_AXIS):mul(rot) end

  -- Cars carry more than one copy of the driver (levels of detail), so turn
  -- every head we find. Nothing resets the bone each frame, so always rotate
  -- from its resting pose rather than from last frame (which spins forever).
  baseTransforms[idx] = baseTransforms[idx] or {}
  local bases = baseTransforms[idx]
  for i = 1, #heads do
    local ok, head = pcall(function () return heads:at(i) end)
    if not ok or not head then head = heads end
    local m = head:getTransformationRaw()
    if not bases[i] then bases[i] = m:clone() end
    m:set(rot:mul(bases[i]))
    if head == heads then break end
  end
end

---------------------------------------------------------------------------
-- Per-frame
---------------------------------------------------------------------------
function script.update(dt)
  if not enabled or not ac.getSim().isOnlineRace then return end

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
    remote[0] = remote[0] or newRemote()
    remote[0].t.yaw, remote[0].t.pitch, remote[0].t.roll = fake.yaw, fake.pitch, fake.roll
    remote[0].lastSeen = os.preciseClock()
  else
    remote[0] = nil
  end

  -- Send yours
  sendTimer = sendTimer + dt
  if sendTimer > 1 / SEND_HZ then
    sendTimer = 0
    local h = fake or readOwnHead()
    if h then
      sendHead(h)
      sentCount = sentCount + 1
    end
  end

  -- Apply everyone else's
  local now = os.preciseClock()
  local k = math.min(1, dt * SMOOTHING)
  for idx, r in pairs(remote) do
    local stale = now - (r.lastSeen or 0) > 2   -- drift back to centre if they've gone quiet
    r.yaw   = math.lerp(r.yaw,   stale and 0 or r.t.yaw,   k)
    r.pitch = math.lerp(r.pitch, stale and 0 or r.t.pitch, k)
    r.roll  = math.lerp(r.roll,  stale and 0 or r.t.roll,  k)
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
  if ui.checkbox('Show head tilt', showTilt) then showTilt = not showTilt end

  ui.separator()
  if ui.checkbox('Test mode (fake head)', test.on) then test.on = not test.on end
  if test.on then
    if ui.checkbox('Auto sweep', test.sweep) then test.sweep = not test.sweep end
    if not test.sweep then
      test.yaw   = ui.slider('##yaw',   test.yaw,   -90, 90, 'Yaw: %.0f°')
      test.pitch = ui.slider('##pitch', test.pitch, -40, 40, 'Pitch: %.0f°')
      test.roll  = ui.slider('##roll',  test.roll,  -35, 35, 'Tilt: %.0f°')
      if ui.button('Centre') then test.yaw, test.pitch, test.roll = 0, 0, 0 end
    end
  end

  ui.separator()
  local h = readOwnHead()
  if h then
    ui.text(string.format('You: yaw %.0f°  pitch %.0f°  tilt %.0f°',
      math.deg(h.yaw), math.deg(h.pitch), math.deg(h.roll)))
  else
    ui.text('You: head bone not found')
  end
  if ui.button('Recentre tilt (sit upright)') then restRoll = nil end

  local count = 0
  for i in pairs(remote) do if i ~= 0 then count = count + 1 end end
  ui.text('Players sending heads: ' .. count)
  ui.text(string.format('Sent %d  ·  Received %d%s', sentCount, receivedCount,
    lastReceived and string.format('  (last %.1fs ago)', os.preciseClock() - lastReceived) or ''))
  ui.text('Message format: ' .. MESSAGE_KEY)
  if ui.button('Re-find head bones') then headNodes, baseTransforms, restRoll = {}, {}, nil end

  ui.separator()
  local n0 = getHeadNode(0)
  ui.text('Head bones on your car: ' .. (n0 and #n0 or 0))
  if ui.button('Scan for head bones') then scanBones() end
  ui.sameLine()
  if ui.button('Dump node tree') then dumpTree() end
  for _, line in ipairs(scanResults) do ui.text(line) end
  if dumpStatus ~= '' then ui.textWrapped(dumpStatus) end
end
