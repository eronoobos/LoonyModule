require "class"

local Perlin = require "perlin"

-- localization

if not Game then
  Game = {
    squareSize = 8,
    gravity = 130,
    mapHardness = 100,
  }
end

local mRandom = math.random
if love then mRandom = love.math.random end
local mRandomSeed = math.randomseed
if love then mRandomSeed = love.math.setRandomSeed end

local mSqrt = math.sqrt
local mMin = math.min
local mMax = math.max
local mAtan2 = math.atan2
local mSin = math.sin
local mCos = math.cos
local mAsin = math.asin
local mAcos = math.acos
local mExp = math.exp
local mCeil = math.ceil
local mFloor = math.floor
local mAbs = math.abs

local tInsert = table.insert
local tRemove = table.remove
local tSort = table.sort

local debugEcho = print
if Spring then debugEcho = Spring.Echo end

local function mClamp(val, lower, upper)
    assert(val and lower and upper, "not very useful error message here")
    if lower > upper then lower, upper = upper, lower end -- swap if boundaries supplied the wrong way
    return mMax(lower, mMin(upper, val))
end

mClamp = math.clamp or mClamp

local function mSmoothstep(edge0, edge1, value)
  if value <= edge0 then return 0 end
  if value >= edge1 then return 1 end
  local x = (value - edge0) / (edge1 - edge0)
  local t = mClamp(x, 0, 1)
  return t * t * (3 - 2 * t)
end

mSmoothstep = math.smoothstep or mSmoothstep

local function mMix(x, y, a)
  return x * (1-a) + y * a
end

mMix = math.mix or mMix


-- local variables:

local outDir = ""
local yesMare = false -- send huge melt-floor-generating meteors before a shower?
local doNotStore = false

local diffDistances = {}
local diffDistancesSq = {}
local sqrts = {}
local gaussians = {}
local angles = {}

------------------------------------------------------------------------------

local AttributeDict = {
  [0] = { name = "None", rgb = {0,0,0} },
  [1] = { name = "Breccia", rgb = {128,128,128} },
  [2] = { name = "Peak", rgb = {0,255,0} },
  [3] = { name = "Ejecta", rgb = {0,255,255} },
  [4] = { name = "Melt", rgb = {128,64,64} },
  [5] = { name = "EjectaThin", rgb = {0,0,255} },
  [6] = { name = "Ray", rgb = {255,255,255} },
  [7] = { name = "Metal", rgb = {255,0,255} },
  [8] = { name = "Geothermal", rgb = {255,255,0} },
}

local AttributeOverlapExclusions = {
  [0] = {},
  [1] = {[7] = true, [8] = true},
  [2] = {[7] = true, [8] = true},
  [3] = {[7] = true, [8] = true},
  [4] = {[7] = true, [8] = true},
  [5] = {[7] = true, [8] = true},
  [6] = {[7] = true, [8] = true},
  [7] = {},
  [8] = {},
}

local AttributesByName = {}
for i, entry in pairs(AttributeDict) do
  local aRGB = entry.rgb
  local r = string.char(aRGB[1])
  local g = string.char(aRGB[2])
  local b = string.char(aRGB[3])
  local threechars = r .. g .. b
  AttributeDict[i].threechars = threechars
  AttributesByName[entry.name] = { index = i, rgb = aRGB, threechars = threechars}
end

-- for metal spot writing
local metalPixelCoords = {
  [1] = { 0, 0 },
  [2] = { 0, 1 },
  [3] = { 0, -1 },
  [4] = { 1, 0 },
  [5] = { -1, 0 },
  [6] = { 1, 1 },
  [7] = { -1, 1 },
  [8] = { 1, -1 },
  [9] = { -1, -1 },
  [10] = { 2, 0 },
  [11] = { -2, 0 },
  [12] = { 0, 2 },
  [13] = { 0, -2 },
}

local MirrorTypes = { "reflectionalx", "reflectionalz", "rotational", "none" }
local MirrorNames = {}
for i, name in pairs(MirrorTypes) do
  MirrorNames[name] = i
end

local WorldSaveBlackList = {
  "world",
  "impact",
  "renderers",
  "heightBuf",
  "mirrorMeteor",
  "rgb",
  "dispX",
  "dispY",
  "dispX2",
  "dispY2",
  "infoStr",
  "dispCraterRadius",
  "complexDiameter",
  "complexDiameterCutoff",
  "complexDepthScaleFactor",
  "blastRayAgeDivisor",
}

local WSBL = {}
for i, v in pairs(WorldSaveBlackList) do
  WSBL[v] = 1
end

local function OnWorldSaveBlackList(str)
  return WSBL[str]
end

local CommandWords = {
  meteor = function(words, myWorld, uiCommand)
    local radius = (words[5] or 10)
    myWorld:AddMeteor(words[3], words[4], radius*2)
  end,
  shower = function(words, myWorld, uiCommand)
    myWorld:MeteorShower(words[3], words[4], words[5], words[6], words[7], words[8], words[9], words[10], words[11], yesMare)
  end,
  clear = function(words, myWorld, uiCommand)
    myWorld:Clear()
  end,
  height = function(words, myWorld, uiCommand)
    myWorld:RenderHeightImage(uiCommand, mapRulerNames[words[3]] or heightMapRuler)
  end,
  attributes = function(words, myWorld, uiCommand)
    myWorld:RenderAttributes(uiCommand, mapRulerNames[words[3]] or heightMapRuler)
  end,
  heightpreview = function(words, myWorld, uiCommand)
    myWorld:RenderHeightImage(uiCommand, displayMapRuler)
  end,
  attributespreview = function(words, myWorld, uiCommand)
    myWorld:RenderAttributes(uiCommand, displayMapRuler)
  end,
  metal = function(words, myWorld, uiCommand)
    myWorld:RenderMetal(uiCommand)
  end,
  features = function(words, myWorld, uiCommand)
    myWorld:RenderFeatures(uiCommand)
  end,
  maretoggle = function(words, myWorld, uiCommand)
    yesMare = not yesMare
    spEcho("yesMare is now", tostring(yesMare))
  end,
  mirror = function(words, myWorld, uiCommand)
    myWorld.mirror = words[3]
    spEcho("mirror: " .. myWorld.mirror)
  end,
  mirrornext = function(words, myWorld, uiCommand)
    local mt = MirrorNames[myWorld.mirror]+1
    if mt == #MirrorTypes+1 then mt = 1 end
    myWorld.mirror = MirrorTypes[mt]
    spEcho("mirror: " .. myWorld.mirror)
  end,
  save = function(words, myWorld, uiCommand)
    myWorld:Save(words[3])
  end,
  load = function(words, myWorld, uiCommand)
    FReadOpen("world" .. (words[3] or ""), "lua", function(str) myWorld:Load(str) end)
  end,
  resetages = function(words, myWorld, uiCommand)
    myWorld:ResetMeteorAges()
  end,
  renderall = function(words, myWorld, uiCommand)
    local mapRuler = mapRulerNames[words[3]] or heightMapRuler
    myWorld:RenderFeatures()
    myWorld:RenderMetal()
    myWorld:RenderAttributes(nil, mapRuler)
    myWorld:RenderHeightImage(uiCommand, mapRuler)
  end,
  exit = function(words, myWorld, uiCommand)
    love.event.quit()
  end,
  quit = function(words, myWorld, uiCommand)
    love.event.quit()
  end,
}

------------------------------------------------------------------------------

-- local functions:

local function tRemoveRandom(fromTable)
  return tRemove(fromTable, mRandom(1, #fromTable))
end

local function tGetRandom(fromTable)
  return fromTable[mRandom(1, #fromTable)]
end

-- simple duplicate, does not handle nesting
local function tDuplicate(sourceTable)
  local duplicate = {}
  for k, v in pairs(sourceTable) do
    duplicate[k] = v
  end
  return duplicate
end

local function splitIntoWords(s)
  local words = {}
  for w in s:gmatch("%S+") do tInsert(words, w) end
  return words
end

local function DiceRoll(dice)
  local n = 0
  for d = 1, dice do
    n = n + (mRandom() / dice)
  end
  return n
end

local function NewSeed()
  return mCeil(mRandom()*9999)
end

local function NextSeed(seed)
  return mMax(1, (mCeil(seed) + 1) % 10000)
end

local function PreviousSeed(seed)
  return mMax(1, mMin(9999, (mCeil(seed) - 1) % 10000))
end

local function CreateSeedPacket(seedSeed, number)
  mRandomSeed(seedSeed)
  local packet = {}
  for i = 1, number do
    tInsert(packet, NewSeed())
  end
  return packet
end

local function pairsByKeys (t, f)
  local a = {}
  for n in pairs(t) do tInsert(a, n) end
  tSort(a, f)
  local i = 0      -- iterator variable
  local iter = local function ()   -- iterator local function
    i = i + 1
    if a[i] == nil then return nil
    else return a[i], t[a[i]]
    end
  end
  return iter
end

local function AngleAdd(angle1, angle2)
  return (angle1 + angle2) % twicePi
end

local function AngleXYXY(x1, y1, x2, y2)
  local dx = x2 - x1
  local dy = y2 - y1
  return mAtan2(dy, dx)
end

local function CirclePos(cx, cy, dist, angle)
  angle = angle or mRandom() * twicePi
  local x = cx + dist * mCos(angle)
  local y = cy + dist * mSin(angle)
  return x, y
end

local function AngleDist(angle1, angle2)
  return mAbs((angle1 + pi -  angle2) % twicePi - pi)
end

local function MinMaxRandom(minimum, maximum)
  return (mRandom() * (maximum - minimum)) + minimum
end

local function RandomVariance(variance)
  return (1-variance) + (mRandom() * variance * 2)
end

local function VaryWithinBounds(value, variance, minimum, maximum)
  if not value then return nil end
  return mMax(mMin(value*RandomVariance(variance), maximum), minimum)
end

local function uint32little(n)
  return string.char( n%256, (n%65536)/256, (n%16777216)/65536, n/16777216 )
end

local function uint16little(n)
  return string.char( n%256, (n%65536)/256 )
end

local function uint16big(n)
  return string.char( (n%65536)/256, n%256 )
end

local function uint8(n)
  return string.char( n%256 )
end

local function FWriteOpen(name, ext, mode)
  name = name or ""
  ext = ext or "txt"
  mode = mode or "wb"
  currentFilename = name .. "." .. ext
  currentFilename = outDir .. currentFilename
  currentFile = assert(io.open(currentFilename,mode), "Unable to save to "..currentFilename)
end

local function FWrite(...)
  local send = ""
  for i, str in ipairs({...}) do
    send = send .. str
  end
  currentFile:write(send)
end

local function FWriteClose()
  currentFile:close()
  print(currentFilename .. " written")
end

local function serialize(o)
  if type(o) == "number" then
    FWrite(o)
  elseif type(o) == "boolean" then
    FWrite(tostring(o))
  elseif type(o) == "string" then
    FWrite(string.format("%q", o))
  elseif type(o) == "table" then
    FWrite("{")
    for k,v in pairs(o) do
      if not (type(k) == "string" and OnWorldSaveBlackList(k)) then
        local kStr = k
        if type(k) == "number" then kStr = "[" .. k .. "]" end
        FWrite("\n  ", kStr, " = ")
        serialize(v)
        FWrite(",")
      end
    end
    FWrite("}")
  else
    -- debugEcho("cannot serialize a " .. type(o))
    FWrite("\"" .. type(o) .. "\"")
  end
end

local function sqrt(number)
  if doNotStore then return mSqrt(number) end
  sqrts[number] = sqrts[number] or mSqrt(number)
  return sqrts[number]
end

local function AngleDXDY(dx, dy)
  if doNotStore then return mAtan2(dy, dx) end
  angles[dx] = angles[dx] or {}
  angles[dx][dy] = angles[dx][dy] or mAtan2(dy, dx)
  return angles[dx][dy]
end

local function Gaussian(x, c)
  if doNotStore then return mExp(  -( (x^2) / (2*(c^2)) )  ) end
  gaussians[x] = gaussians[x] or {}
  gaussians[x][c] = gaussians[x][c] or mExp(  -( (x^2) / (2*(c^2)) )  )
  return gaussians[x][c]
end

local function EndCommand(command)

end

local function WriteMetalSpot(dataTarget, x, z, metal)
    local pixels = 5
    if metal <= 1 then
      pixels = 5
    elseif metal <= 2 then
      pixels = 9
    else
      pixels = 13
    end
    local mAmount = (1000 / pixels) * metal
    local mx, mz = mFloor(x/16), mFloor(z/16)
    for p = 1, pixels do
      local metalX = mx + metalPixelCoords[p][1]
      local metalY = mz + metalPixelCoords[p][2]
      dataTarget[metalX] = dataTarget[metalX] or {}
      dataTarget[metalX][metalY] = mAmount
    end
end

local function ClearSpeedupStorage()
  diffDistances = {}
  diffDistancesSq = {}
  sqrts = {}
  gaussians = {}
  angles = {}
end

------------------------------------------------------------------------------

-- classes and methods organized by class: -----------------------------------

local World = class(function(a, mapSize512X, mapSize512Z, metersPerElmo, baselevel, gravity, density, mirror, underlyingPerlin, erosion)
  a.mapSize512X = mapSize512X or 8
  a.mapSize512Z = mapSize512Z or 8
  a.metersPerElmo = metersPerElmo or 1 -- meters per elmo for meteor simulation model only
  a.baselevel = baselevel or 0
  a.gravity = gravity or (Game.gravity / 130) * 9.8
  a.density = density or (Game.mapHardness / 100) * 2500
  a.mirror = mirror or "none"
  a.minMetalMeteorDiameter = 2
  a.metalMeteorDiameter = 50
  a.metalMeteorTarget = 20
  a.metalSpotAmount = 2.0
  a.metalSpotRadius = 50 -- elmos
  a.metalSpotDepth = 20
  a.minGeothermalMeteorDiameter = 20
  a.maxGeothermalMeteorDiameter = 100
  a.geothermalMeteorTarget = 4
  a.geothermalRadius = 16 -- elmos
  a.geothermalDepth = 10
  a.metalAttribute = true -- draw metal spots on the attribute map?
  a.geothermalAttribute = true -- draw geothermal vents on the attribute map?
  a.rimTerracing = true
  a.blastRayAge = 4
  a.underlyingPerlin = underlyingPerlin
  a.erosion = true -- erosion
  -- local echostr = ""
  -- for k, v in pairs(a) do echostr = echostr .. tostring(k) .. "=" .. tostring(v) .. " " end
  -- debugEcho(echostr)
  a:Calculate()
  a:Clear()
end)

function World:Calculate()
  self.mapSizeX = self.mapSize512X * 512
  self.mapSizeZ = self.mapSize512Z * 512
  heightMapRuler = MapRuler(self, nil, (self.mapSizeX / Game.squareSize) + 1, (self.mapSizeZ / Game.squareSize) + 1)
  metalMapRuler = MapRuler(self, 16, (self.mapSizeX / 16), (self.mapSizeZ / 16))
  L3DTMapRuler = MapRuler(self, 4, (self.mapSizeX / 4), (self.mapSizeZ / 4))
  fullMapRuler = MapRuler(self, 1)

  mapRulerNames = {
    full = fullMapRuler,
    l3dt = L3DTMapRuler,
    height = heightMapRuler,
    spring = heightMapRuler,
    metal = metalMapRuler,
  }

  ResetDisplay(self)

  self.complexDiameter = 3200 / (self.gravity / 9.8)
  local Dc = self.complexDiameter / 1000
  self.complexDiameterCutoff = ((Dc / 1.17) * (Dc ^ 0.13)) ^ (1/1.13)
  self.complexDiameterCutoff = self.complexDiameterCutoff * 1000
  self.complexDepthScaleFactor = ((self.gravity / 1.6) + 1) / 2
  self.blastRayAgeDivisor = 100 / self.blastRayAge
  self:ResetMeteorAges()
end

function World:Clear()
  self.heightBuf = HeightBuffer(self, heightMapRuler)
  self.meteors = {}
  self.renderers = {}
  self.metalSpotCount = 0
  self.geothermalMeteorCount = 0
end

function World:Save(name)
  name = name or ""
  FWriteOpen("world"..name, "lua", "w")
  FWrite("return ")
  serialize(self)
  FWriteClose()
end

function World:Load(luaStr)
  self:Clear()
  local loadWorld = loadstring(luaStr)
  local newWorld = loadWorld()
  for k, v in pairs(newWorld) do
    self[k] = v
  end
  self.meteors = {}
  self:Calculate()
  for i, m in pairs(newWorld.meteors) do
    local newM = Meteor(self, m.sx, m.sz, m.diameterImpactor, m.velocityImpactKm, m.angleImpact, m.densityImpactor, m.age, m.metal, m.geothermal, m.seedSeed, m.ramps, m.mirrorMeteor)
    newM:Collide()
    self.meteors[i] = newM
  end
  if self.heightBuf then self.heightBuf.changesPending = true end
  debugEcho("world loaded with " .. #self.meteors .. " meteors")
end

function World:RendererFrame(frame)
  local renderer = self.renderers[1]
  if renderer then
    renderer:Frame(frame)
    if renderer.complete then
      tRemove(self.renderers, 1)
      return renderer
    end
  end
end

function World:MeteorShower(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity, underlyingMare)
  number = number or 3
  minDiameter = minDiameter or 1
  maxDiameter = maxDiameter or 500
  minVelocity = minVelocity or 10
  maxVelocity = maxVelocity or 72
  -- minDiameter = minDiameter^0.01
  -- maxDiameter = maxDiameter^0.01
  minAngle = minAngle or 30
  maxAngle = maxAngle or 60
  minDensity = minDensity or 4000
  maxDensity = maxDensity or 10000
  if underlyingMare then
    self:AddMeteor(self.mapSizeX/2, self.mapSizeZ/2, MinMaxRandom(600, 800), 50, 60, 8000, 100, 0, nil, nil, nil, nil, true)
  end
  local hundredConv = 100 / number
  local diameterDif = maxDiameter - minDiameter
  for n = 1, number do
    -- local diameter = MinMaxRandom(minDiameter, maxDiameter)^100
    local diameter = minDiameter + (mAbs(DiceRoll(65)-0.5) * diameterDif * 2)
    -- debugEcho(diameter)
    local velocity = MinMaxRandom(minVelocity, maxVelocity)
    local angle = MinMaxRandom(minAngle, maxAngle)
    local density = MinMaxRandom(minDensity, maxDensity)
    local x = mFloor(mRandom() * self.mapSizeX)
    local z = mFloor(mRandom() * self.mapSizeZ)
    self:AddMeteor(x, z, diameter, velocity, angle, density, mFloor((number-n)*hundredConv))
  end
  for i = #self.meteors, 1, -1 do
    local m = self.meteors[i]
    m:MetalGeothermal()
  end
  self:ResetMeteorAges()
  debugEcho(#self.meteors, self.metalSpotCount, self.geothermalMeteorCount)
end

function World:ResetMeteorAges()
  if not self.meteors then return end
  for i, m in pairs(self.meteors) do
    m:SetAge(((#self.meteors-i)/#self.meteors)*100)
  end
end

function World:AddMeteor(sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, seedSeed, ramps, mirrorMeteor, noMirror)
  local m = Meteor(self, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, seedSeed, ramps, mirrorMeteor)
  tInsert(self.meteors, m)
  if self.mirror ~= "none" and not mirrorMeteor and not noMirror then
    m:Mirror(true)
  end
  if self.heightBuf then self.heightBuf.changesPending = true end
  m:Collide()
  return m
end

function World:RenderAttributes(uiCommand, mapRuler)
  mapRuler = mapRuler or heightMapRuler
  if mapRuler == fullMapRuler then
    doNotStore = true
    ClearSpeedupStorage()
    self.heightBuf = nil
  end
  local renderer = Renderer(self, mapRuler, 8000, "Attributes", uiCommand)
  tInsert(self.renderers, renderer)
end

function World:RenderHeightImage(uiCommand, mapRuler)
  mapRuler = mapRuler or L3DTMapRuler
  doNotStore = true
  ClearSpeedupStorage()
  self.heightBuf = nil
  local tempHeightBuf = HeightBuffer(self, mapRuler)
  tInsert(self.renderers, Renderer(self, mapRuler, 4000, "Height", uiCommand, tempHeightBuf))
  if mapRuler ~= displayMapRuler then
    tInsert(self.renderers, Renderer(self, mapRuler, 15000, "HeightImage", uiCommand, tempHeightBuf, true))
  end
end

function World:RenderHeightPreview(uiCommand)
  local tempHeightBuf = HeightBuffer(self, displayMapRuler)
  tInsert(self.renderers, Renderer(self, displayMapRuler, 4000, "Height", uiCommand, tempHeightBuf))
end

function World:RenderMetal(uiCommand)
  local renderer = Renderer(self, metalMapRuler, 16000, "Metal", uiCommand, nil, true)
  tInsert(self.renderers, renderer)
end

function World:RenderFeatures(uiCommand)
  FWriteOpen("features", "lua", "w")
  FWrite("local setcfg = {\n\tunitlist = {\n\t},\n\tbuildinglist = {\n\t},\n\tobjectlist = {\n")
  for i, m in pairs(self.meteors) do
    if m.geothermal then
      FWrite("\t\t{ name = 'GeoVent', x = " .. m.sx .. ", z = " .. m.sz .. ", rot = \"180\" },\n")
    end
  end
  FWrite("\t},\n}\nreturn setcfg")
  FWriteClose()
  debugEcho("wrote features lua")
end

function World:MirrorXZ(x, z)
  local nx, nz
  if self.mirror == "reflectionalx" then
    nx = self.mapSizeX - x
    nz = z+0
  elseif self.mirror == "reflectionalz" then
    nx = x+0
    nz = self.mapSizeZ - z
  elseif self.mirror == "rotational" then
    nx = self.mapSizeX - x
    nz = self.mapSizeZ - z
  end
  return nx, nz
end

function World:InterpretCommand(msg)
  if not msg then return end
  if msg == "" then return end
  msg = "loony " .. msg
  local words = splitIntoWords(msg)
  local where = words[1]
  if where == "loony" then
    local commandWord = words[2]
    local uiCommand = string.sub(msg, 7)
    if CommandWords[commandWord] then
      CommandWords[commandWord](words, self, uiCommand)
      return true
    end
  end
  return false
end

----------------------------------------------------------

local MapRuler = class(function(a, world, elmosPerPixel, width, height)
  elmosPerPixel = elmosPerPixel or world.mapSizeX / (width-1)
  width = width or mCeil(world.mapSizeX / elmosPerPixel)
  height = height or mCeil(world.mapSizeZ / elmosPerPixel)
  a.world = world
  a.elmosPerPixel = elmosPerPixel
  a.width = width
  a.height = height
  if elmosPerPixel == 1 then
    a.elmosPerPixelPowersOfTwo = 0
  elseif elmosPerPixel == 2 then
    a.elmosPerPixelPowersOfTwo = 1
  elseif elmosPerPixel == 4 then
    a.elmosPerPixelPowersOfTwo = 2
  elseif elmosPerPixel == 8 then
    a.elmosPerPixelPowersOfTwo = 3
  elseif elmosPerPixel == 16 then
    a.elmosPerPixelPowersOfTwo = 4
  end
end)

function MapRuler:XZtoXY(x, z)
  if self.elmosPerPixel == 1 then
    return x+1, z+1
  else
    local hx = mFloor(x / self.elmosPerPixel) + 1
    local hy = mFloor(z / self.elmosPerPixel) + 1
    return hx, hy
  end
end

function MapRuler:XYtoXZ(x, y)
  if self.elmosPerPixel == 1 then
    return x-1, y-1
  else
    local sx = mFloor((x-1) * self.elmosPerPixel)
    local sz = mFloor((y-1) * self.elmosPerPixel)
    return sx, sz
  end
end

function MapRuler:RadiusBounds(x, y, radius)
  local w, h = self.width, self.height
  local xmin = mFloor(x - radius)
  local xmax = mCeil(x + radius)
  local ymin = mFloor(y - radius)
  local ymax = mCeil(y + radius)
  if xmin < 1 then xmin = 1 end
  if xmax > w then xmax = w end
  if ymin < 1 then ymin = 1 end
  if ymax > h then ymax = h end
  return xmin, xmax, ymin, ymax
end

----------------------------------------------------------

local HeightBuffer = class(function(a, world, mapRuler)
  a.world = world
  a.mapRuler = mapRuler
  a.elmosPerPixel = mapRuler.elmosPerPixel
  a.w, a.h = mapRuler.width, mapRuler.height
  a.heights = {}
  for x = 1, a.w do
    a.heights[x] = {}
    for y = 1, a.h do
      a.heights[x][y] = 0
    end
  end
  a.maxHeight = 0
  a.minHeight = 0
  a.antiAlias = false
  debugEcho("new height buffer created", a.w, " by ", a.h)
end)

function HeightBuffer:CoordsOkay(x, y)
  if not self.heights[x] then
    -- debugEcho("no row at ", x)
    return
  end
  if not self.heights[x][y] then
    -- debugEcho("no pixel at ", x, y)
    return
  end
  return true
end

function HeightBuffer:MinMaxCheck(height)
  if height > self.maxHeight then self.maxHeight = height end
  if height < self.minHeight then self.minHeight = height end
end

function HeightBuffer:Write(x, y, height)
  local sx, sz = self.mapRuler:XYtoXZ(x, y)
  spLevelHeightMap(sx, sz, sx+8, sz-8, self.world.baselevel+height)
end

function HeightBuffer:Add(x, y, height, alpha)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  local newHeight = self.heights[x][y] + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
  self:Write(x, y, newHeight)
end

function HeightBuffer:Blend(x, y, height, alpha, secondary)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  if alpha < 1 and self.heights[x][y] > height then alpha = alpha * alpha end
  local orig = 1 - alpha
  local newHeight = (self.heights[x][y] * orig) + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
  self:Write(x, y, newHeight)
  if not secondary and self.antiAlias then
    for xx = -1, 1 do
      for yy = -1, 1 do
        if not (xx == 0 and yy == 0 ) then
          if xx == 0 or yy == 0 then
            self:Blend(x+xx, y+yy, height, alpha*0.5, true)
          else
            -- self:Blend(x+xx, y+yy, height, alpha*0.355, true)
          end
        end
      end
    end
  end
end

function HeightBuffer:Set(x, y, height)
  if not self:CoordsOkay(x, y) then return end
  self.heights[x][y] = height
  self:MinMaxCheck(height)
  self:Write(x, y, height)
end

function HeightBuffer:Get(x, y)
  if not self:CoordsOkay(x, y) then return end
  return self.heights[x][y]
end

function HeightBuffer:GetCircle(x, y, radius)
  local xmin, xmax, ymin, ymax = self.mapRuler:RadiusBounds(x, y, radius)
  local totalHeight = 0
  local totalWeight = 0
  local minHeight = 99999
  local maxHeight = -99999
  for x = xmin, xmax do
    for y = ymin, ymax do
      local height = self:Get(x, y)
      totalHeight = totalHeight + height
      totalWeight = totalWeight + 1
      if height < minHeight then minHeight = height end
      if height > maxHeight then maxHeight = height end
    end
  end
  return totalHeight / totalWeight, minHeight, maxHeight
end

function HeightBuffer:SendFile(uiCommand)
  if self.changesPending then
    tInsert(self.world.renderers, Renderer(self.world, self.mapRuler, 4000, "Height", uiCommand, self))
  end
  tInsert(self.world.renderers, Renderer(self.world, self.mapRuler, 15000, "HeightImage", uiCommand, self, true))
end

function HeightBuffer:Clear()
  for x = 1, self.w do
    for y = 1, self.h do
      -- self:Set(x, y, 0)
      self.heights[x][y] = 0
    end
  end
  self.minHeight = 0
  self.maxHeight = 0
end

----------------------------------------------------------

local Renderer = class(function(a, world, mapRuler, pixelsPerFrame, renderType, uiCommand, heightBuf, noCraters, radius)
  a.uiCommand = uiCommand or ""
  a.world = world
  a.mapRuler = mapRuler
  a.pixelsPerFrame = pixelsPerFrame
  a.renderType = renderType
  a.heightBuf = heightBuf
  a.radius = radius
  a.craters = {}
  a.totalCraterArea = 0
  if not noCraters then
    for i, m in ipairs(world.meteors) do
      local crater = Crater(m.impact, a)
      tInsert(a.craters, crater)
      a.totalCraterArea = a.totalCraterArea + crater.area
    end
  end
  a.pixelsRendered = 0
  a.pixelsToRenderCount = mapRuler.width * mapRuler.height
  a.totalPixels = a.pixelsToRenderCount+0
  a.PreinitFunc = a[a.renderType .. "Preinit"] or a.EmptyPreinit
  a.InitFunc = a[a.renderType .. "Init"] or a.EmptyInit
  a.FrameFunc = a[a.renderType .. "Frame"] -- if there's no framefunc what's the point
  a.FinishFunc = a[a.renderType .. "Finish"] or a.EmptyFinish
  a:Preinitialize()
end)

function Renderer:Preinitialize()
  self:PreinitFunc()
  self.preInitialized = true
end

function Renderer:Initialize(frame)
  self.startFrame = frame
  self.totalProgress = self.totalPixels
  self:InitFunc()
  self.initialized = true
end

function Renderer:Frame(frame)
  if not self.initialized then self:Initialize(frame) end
  local progress = self:FrameFunc()
  if progress then
    self.progress = (self.progress or 0) + progress
  end
  if self.progress > self.totalProgress or not progress then
    self:Finish(frame)
  end
  if self.complete then return self.data end
end

function Renderer:Finish(frame)
  self:FinishFunc()
  if not self.dontEndUiCommand then EndCommand(self.uiCommand) end
  local timeDiff = frame - self.startFrame
  debugEcho(self.renderType .. " (" .. self.mapRuler.width .. "x" .. self.mapRuler.height .. ") rendered in " .. timeDiff .. " seconds")
  self.complete = true
end

function Renderer:EmptyPreinit()
  return
end

function Renderer:EmptyInit()
  -- debugEcho("emptyinit")
  return
end

 function Renderer:EmptyFinish()
  -- debugEcho("emptyfinish")
  return
end

function Renderer:HeightInit()
  self.totalProgress = self.totalCraterArea
  self.metalSpots = {}
end

function Renderer:HeightFrame()
  local pixelsRendered = 0
  while pixelsRendered < self.pixelsPerFrame and #self.craters > 0 do
    local c = self.craters[1]
    c:AddAgeNoise()
    c:GiveStartingHeight()
    while c.currentPixel <= c.area and pixelsRendered < self.pixelsPerFrame do
      local x, y, height, alpha, add = c:OneHeightPixel()
      if height then
        -- if add then
          -- self.heightBuf:Add(x, y, height, alpha)
        -- else
          self.heightBuf:Blend(x, y, height+c.startingHeight, alpha)
        -- end
        pixelsRendered = pixelsRendered + 1
      end
    end
    if c.currentPixel > c.area then
      c.complete = true
      tRemove(self.craters, 1)
      c = nil
    end
    if pixelsRendered == self.pixelsPerFrame then break end
  end
  return pixelsRendered
end

function Renderer:HeightFinish()
  self.dontEndUiCommand = true
  self.heightBuf.changesPending = nil
  if self.uiCommand == "heightpreview" then
    self.data = self.heightBuf
  end
end

function Renderer:HeightImageInit()
  FWriteOpen("height_" .. self.mapRuler.width .. "x" .. self.mapRuler.height, "pgm")
  FWrite("P5 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " " .. 65535 .. " ")
end

function Renderer:HeightImageFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  local heightBuf = self.heightBuf
  local heightDif = (heightBuf.maxHeight - heightBuf.minHeight)
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    -- local y = self.mapRuler.height - mFloor(p / self.mapRuler.width) --pgm goes backwards y?
    local y = mFloor(p / self.mapRuler.width) + 1
    local pixelHeight = heightBuf:Get(x, y) or self.world.baselevel
    local pixelColor = mFloor(((pixelHeight - heightBuf.minHeight) / heightDif) * 65535)
    local twochars = uint16big(pixelColor)
    FWrite(twochars)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:HeightImageFinish()
  FWriteClose()
  debugEcho("height File sent")
  FWriteOpen("heightrange", "txt", "w")
  FWrite(
    "min: " .. self.heightBuf.minHeight .. "\n\r" ..
    "max: " .. self.heightBuf.maxHeight .. "\n\r" ..
    "range: " .. (self.heightBuf.maxHeight - self.heightBuf.minHeight))
  FWriteClose()
  if self.mapRuler ~= heightMapRuler then
    doNotStore = false
    local world = self.heightBuf.world
    self.heightBuf = nil
    world.heightBuf = HeightBuffer(world, heightMapRuler)
  end
end

function Renderer:AttributesInit()
  if self.uiCommand == "attributespreview" then
    self.data = {}
  else
    FWriteOpen("attrib_" .. self.mapRuler.width .. "x" .. self.mapRuler.height, "pbm")
    FWrite("P6 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " 255 ")
  end
end

function Renderer:AttributesFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = mFloor(p / self.mapRuler.width) + 1
    if p < 2000 then debugEcho(p, x, y) end
    local attribute = 0
    for i, c in ipairs(self.craters) do
      local a = c:AttributePixel(x, y)
      if a ~= 0 and not AttributeOverlapExclusions[a][attribute] then
        attribute = a
      end
    end
    if self.uiCommand == "attributespreview" then
      self.data[x] = self.data[x] or {}
      self.data[x][y] = attribute
    else
      FWrite(threechars)
    end
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:AttributesFinish()
  if self.uiCommand == "attributespreview" then

  else
    FWriteClose()
  end
end

function Renderer:MetalPreinit()
  self.metalSpots = {}
  for i, meteor in pairs(self.world.meteors) do
    if meteor.metal > 0 then
      for i, spot in pairs(meteor.impact.metalSpots) do
        tInsert(self.metalSpots, spot)
      end
    end
  end
  debugEcho(#self.metalSpots .. " metal spots")
end

function Renderer:MetalInit()
  FWriteOpen("metal", "lua", "w")
  FWrite("return {\n\tspots = {\n")
  for i, spot in pairs(self.metalSpots) do
    FWrite("\t\t{x = " .. spot.x .. ", z = " .. spot.z .. ", metal = " .. spot.metal .. "},\n")
    WriteMetalSpot(self.data, spot.x, spot.z, spot.metal)
  end
  FWrite("\t}\n}")
  FWriteClose()
  debugEcho("wrote metal to data and wrote metal config lua")
  FWriteOpen("metal", "pbm")
  FWrite("P6 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " 255 ")
  self.zeroTwoChars = string.char(0) .. string.char(0)
  self.blackThreeChars = string.char(0) .. string.char(0) .. string.char(0)
end

function Renderer:MetalFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width)
    local y = mFloor(p / self.mapRuler.width)
    local threechars = self.blackThreeChars
    local mAmount = self.data[x][y]
    if mAmount > 0 then
      threechars = string.char(mAmount) .. self.zeroTwoChars
    end
    FWrite(threechars)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:MetalFinish()
  FWriteClose()
end

----------------------------------------------------------

-- Crater actually gets rendered. scales horizontal distances to the frame being rendered (does resolution-dependent calculations, based on an Impact)
local Crater = class(function(a, impact, renderer)
  local world = impact.world
  local elmosPerPixel = renderer.mapRuler.elmosPerPixel
  local elmosPerPixelP2 = renderer.mapRuler.elmosPerPixelPowersOfTwo
  a.impact = impact
  a.renderer = renderer
  local meteor = impact.meteor

  a.seedPacket = CreateSeedPacket(impact.craterSeedSeed, 100)

  a.x, a.y = renderer.mapRuler:XZtoXY(meteor.sx, meteor.sz)
  a.radius = impact.craterRadius / elmosPerPixel

  a.falloff = impact.craterRadius * 1.5 / elmosPerPixel
  a.peakC = (a.radius / 8) ^ 2
  a.totalradius = a.radius + a.falloff
  a.totalradiusSq = a.totalradius * a.totalradius
  a.totalradiusPlusWobble = a.totalradius*(1+impact.distWobbleAmount)
  a.totalradiusPlusWobbleSq = a.totalradiusPlusWobble ^ 2
  a.xmin, a.xmax, a.ymin, a.ymax = renderer.mapRuler:RadiusBounds(a.x, a.y, a.totalradiusPlusWobble)
  a.radiusSq = a.radius * a.radius
  a.falloffSq = a.totalradiusSq - a.radiusSq
  a.falloffSqHalf = a.falloffSq / 2
  a.falloffSqFourth = a.falloffSq / 4
  a.brecciaRadiusSq = (a.radius * 0.85) ^ 2
  a.blastRadius = a.totalradius * 4
  a.blastRadiusSq = a.blastRadius ^ 2
  a.xminBlast, a.xmaxBlast, a.yminBlast, a.ymaxBlast = renderer.mapRuler:RadiusBounds(a.x, a.y, a.blastRadius)

  a.ramps = {}
  for i, ramp in pairs(meteor.ramps) do
    -- l = 2r * sin(θ/2)
    -- θ = 2 * asin(l/2r)
    local width = ramp.width / elmosPerPixel
    local halfTheta = mAsin(width / (2 * a.totalradiusPlusWobble))
    local cRamp = { angle = ramp.angle, width = width, halfTheta = halfTheta,
      widthNoise = LinearNoise(10, 0.1, a:PopSeed(), 0.5, 2),
      angleNoise = LinearNoise(25, 0.05, a:PopSeed(), 0.5, 4) }
    tInsert(a.ramps, cRamp)
  end

  a.metalSpots = {}
  if meteor.metal > 0 and world.metalAttribute then -- note: this needs to be expanded for multiple metal spots
    for i, spot in pairs(impact.metalSpots) do
      local x, y = renderer.mapRuler:XZtoXY(spot.x, spot.z)
      local radius = mCeil(world.metalSpotRadius / elmosPerPixel)
      local noise = NoisePatch(x, y, radius, a:PopSeed(), world.metalSpotDepth, 0.3, 5-elmosPerPixelP2, 1, 0.4)
      local cSpot = { x = x, y = y, metal = spot.metal, radius = radius, radiusSq = radius^2, noise = noise }
      tInsert(a.metalSpots, cSpot)
    end
  end
  if meteor.geothermal and world.geothermalAttribute then
    a.geothermalRadius = mCeil(world.geothermalRadius / elmosPerPixel)
    a.geothermalRadiusSq = a.geothermalRadius^2
    a.geothermalNoise = WrapNoise(22, 1, a:PopSeed(), 1, 1)
  end


  if impact.complex and not meteor.geothermal then
    a.peakRadius = impact.peakRadius / elmosPerPixel
    a.peakRadiusSq = a.peakRadius ^ 2
    local baseN = 8 + mFloor(impact.peakRadius / 300)
    a.peakNoise = NoisePatch(a.x, a.y, a.peakRadius, a:PopSeed(), impact.craterPeakHeight, 0.3, baseN-elmosPerPixelP2, 1, 0.5, 1, a:PopSeed(), 16, 0.75)
  end

  if impact.terraceSeeds then
    local tmin = a.radiusSq * 0.35
    local tmax = a.radiusSq * 0.8
    local tdif = tmax - tmin
    local terraceWidth = tdif / #impact.terraceSeeds
    local terraceFlatWidth = terraceWidth * 0.5
    a.terraces = {}
    for i = 1, #impact.terraceSeeds do
      a.terraces[i] = { max = tmin + (i*terraceWidth), noise = WrapNoise(12, terraceWidth*2, impact.terraceSeeds[i], 0.5, 2) }
    end
    a.terraceMin = tmin
  end

  a.width = a.xmax - a.xmin + 1
  a.height = a.ymax - a.ymin + 1
  a.area = a.width * a.height
  a.currentPixel = 0
end)

function Crater:AddAgeNoise()
  if self.ageNoise then return end
  if self.impact.meteor.age > 0 and self.totalradiusPlusWobble < 1000 then -- otherwise, way too much memory
    self.ageNoise = NoisePatch(self.x, self.y, self.totalradiusPlusWobble, self:PopSeed(), 0.5-(self.impact.ageRatio*0.25), 0.33, 10-self.renderer.mapRuler.elmosPerPixelPowersOfTwo)
  end
end

function Crater:PopSeed()
  return tRemove(self.seedPacket)
end

function Crater:DistanceSq(x, y)
  local dx, dy = mAbs(x-self.x), mAbs(y-self.y)
  if doNotStore then return ((dx*dx) + (dy*dy)) end
  diffDistancesSq[dx] = diffDistancesSq[dx] or {}
  diffDistancesSq[dx][dy] = diffDistancesSq[dx][dy] or ((dx*dx) + (dy*dy))
  return diffDistancesSq[dx][dy]
end

function Crater:Distance(x, y)
  local dx, dy = mAbs(x-self.x), mAbs(y-self.y)
  if doNotStore then return sqrt((dx*dx) + (dy*dy)) end
  diffDistances[dx] = diffDistances[dx] or {}
  if not diffDistances[dx][dy] then
    local distSq = self:DistanceSq(x, y)
    diffDistances[dx][dy] = sqrt(distSq)
  end
  return diffDistances[dx][dy], diffDistancesSq[dx][dy]
end

function Crater:TerraceDistMod(distSq, angle)
  if self.terraces then
    local terracesByDist = {}
    for i, t in ipairs(self.terraces) do
      local d = t.max - t.noise:Radial(angle)
      local dist = d - distSq
      terracesByDist[mAbs(dist)] = {t = t, dist = dist, d = d}
    end
    local below, above, aboveMax, belowMax
    for absDist, td in pairsByKeys(terracesByDist) do
      if td.dist > 0 then
        above = td.d
        aboveMax = td.t.max
      end
      if td.dist < 0 then
        below = td.d
        belowMax = td.t.max
      end
      if below and above then break end
    end
    if above and below then
      local ratio = mSmoothstep(below, above, distSq)
      distSq = mMix(below, above, ratio)
    end
  end
  return distSq
end

function Crater:HeightPixel(x, y)
  if x < self.xmin or x > self.xmax or y < self.ymin or y > self.ymax then return 0, 0, false end
  local impact = self.impact
  local meteor = self.impact.meteor
  local world = meteor.world
  local dx, dy = x-self.x, y-self.y
  local angle = AngleDXDY(dx, dy)
  local distWobbly = impact.distNoise:Radial(angle) + 1
  local realDistSq = self:DistanceSq(x, y)
  if realDistSq > self.totalradiusPlusWobbleSq then return 0, 0, false end
  local distSq = mMix(realDistSq, realDistSq * distWobbly, mMin(1, (realDistSq/self.radiusSq))^2)
  -- local distSq = realDistSq * distWobbly
  distSq = self:TerraceDistMod(distSq, angle)
  local rimRatio = distSq / self.radiusSq
  local heightWobbly = (impact.heightNoise:Radial(angle) * rimRatio) + 1
  local height = 0
  local alpha = 1
  local rimHeight = impact.craterRimHeight * heightWobbly
  local bowlPower = impact.bowlPower
  if impact.curveNoise then bowlPower = mMax(1, bowlPower * (impact.curveNoise:Radial(angle) + 1)) end
  local rimRatioPower = rimRatio ^ bowlPower
  local angleRatioSmooth = 1
  if #self.ramps > 0 then
    local dist = mSqrt(realDistSq)
    local totalRatio = dist / self.totalradius
    for i, ramp in pairs(self.ramps) do
      local halfThetaHere = ramp.halfTheta / totalRatio
      halfThetaHere = halfThetaHere * (1+ramp.widthNoise:Rational(totalRatio))
      local rampAngle = ramp.angle * (1+ramp.angleNoise:Rational(totalRatio))
      local angleDist = AngleDist(angle, rampAngle)
      if angleDist < halfThetaHere then
        local angleRatio = angleDist / halfThetaHere
        angleRatioSmooth = mSmoothstep(0, 1, angleRatio)
        local smooth = mSmoothstep(0, 1, (dist / self.radius))
        rimRatioPower = mMix(smooth, rimRatioPower, angleRatioSmooth)
      end
    end
  end
  local add = false
  if distSq <= self.radiusSq then
    if meteor.age > 0 then
      local smooth = mSmoothstep(0, 1, rimRatio)
      rimRatioPower = mMix(rimRatioPower, smooth, impact.ageRatio)
    end
    height = rimHeight - ((1 - rimRatioPower)*impact.craterDepth)
    --[[
    if self.geothermalNoise then
      if realDistSq < self.geothermalRadiusSq * 2 then
        local geoWobbly = self.geothermalNoise:Radial(angle) + 1
        local geoRadiusSqWobbled = self.geothermalRadiusSq * geoWobbly
        local geoRatio = mMin(1, (realDistSq / geoRadiusSqWobbled) ^ 0.5)
        height = height - ((1-geoRatio) * world.geothermalDepth)
      end
    end
    if meteor.metal > 0 then
      for i, spot in pairs(self.metalSpots) do
        local metal = spot.noise:Get(x, y)
        height = height - metal
      end
    end
    ]]--
    if impact.complex then
      if self.peakNoise then
        local peak = self.peakNoise:Get(x, y)
        height = height + peak
      end
      if height < impact.meltSurface then height = impact.meltSurface end
    elseif meteor.age < 15 then
      local rayWobbly = impact.rayNoise:Radial(angle) + 1
      local rayWidth = impact.rayWidth * rayWobbly
      local rayWidthMult = twicePi / rayWidth
      local rayHeight = mMax(mSin(rayWidthMult * angle) - 0.75, 0) * impact.rayHeight * heightWobbly * rimRatio * (1-(meteor.age / 15))
      height = height - rayHeight
    end
  else
    add = true
    height = rimHeight
    local fallDistSq = distSq - self.radiusSq
    if fallDistSq <= self.falloffSq then
      local gaussDecay = Gaussian(fallDistSq, self.falloffSqFourth)
      local linearGrowth = mMin(fallDistSq / self.falloffSq, 1)
      local linearDecay = 1 - linearGrowth
      local secondPower = 0.5
      if angleRatioSmooth < 1 then
        secondPower = 1 - (angleRatioSmooth * 0.5)
      end
      local secondDecay = 1 - (linearGrowth^secondPower)
      alpha = (gaussDecay * linearGrowth) + (secondDecay * linearDecay)
      if meteor.age > 0 then
        local smooth = mSmoothstep(0, 1, linearDecay)
        alpha = mMix(alpha, smooth, impact.ageRatio)
      end
    else
      alpha = 0
    end
  end
  if self.ageNoise then height = mMix(height, height * self.ageNoise:Get(x, y), impact.ageRatio) end
  return height, alpha, add
end

function Crater:OneHeightPixel()
  local p = self.currentPixel
  local x = (p % self.width) + self.xmin
  local y = mFloor(p / self.width) + self.ymin
  self.currentPixel = self.currentPixel + 1
  local height, alpha, add = self:HeightPixel(x, y)
  return x, y, height, alpha, add
end

function Crater:AttributePixel(x, y)
  local impact = self.impact
  local meteor = self.impact.meteor
  local world = self.impact.world
  if meteor.age >= world.blastRayAge and (x < self.xmin or x > self.xmax or y < self.ymin or y > self.ymax) then return 0 end 
  if x < self.xminBlast or x > self.xmaxBlast or y < self.yminBlast or y > self.ymaxBlast then return 0 end
  local dx, dy = x-self.x, y-self.y
  local angle = AngleDXDY(dx, dy)
  local distWobbly = impact.distNoise:Radial(angle) + 1
  local realDistSq = self:DistanceSq(x, y)
  -- local realRimRatio = realDistSq / radiusSq
  local distSq = realDistSq * distWobbly
  distSq = self:TerraceDistMod(distSq, angle)
  if meteor.age >= world.blastRayAge and distSq > self.totalradiusSq then return 0 end
  if distSq > self.blastRadiusSq then return 0 end
  local rimRatio = distSq / self.radiusSq
  local heightWobbly = (impact.heightNoise:Radial(angle) * rimRatio) + 1
  local rimHeight = impact.craterRimHeight * heightWobbly
  local bowlPower = impact.bowlPower
  if impact.curveNoise then bowlPower = mMax(1, bowlPower * (impact.curveNoise:Radial(angle) + 1)) end
  local rimRatioPower = rimRatio ^ bowlPower
  local angleRatioSmooth = 1
  if #self.ramps > 0 then
    local dist = mSqrt(realDistSq)
    local totalRatio = dist / self.totalradius
    for i, ramp in pairs(self.ramps) do
      local halfThetaHere = ramp.halfTheta / totalRatio
      halfThetaHere = halfThetaHere * (1+ramp.widthNoise:Rational(totalRatio))
      local rampAngle = ramp.angle * (1+ramp.angleNoise:Rational(totalRatio))
      local angleDist = AngleDist(angle, rampAngle)
      if angleDist < halfThetaHere then
        local angleRatio = angleDist / halfThetaHere
        angleRatioSmooth = mSmoothstep(0, 1, angleRatio)
        local smooth = mSmoothstep(0, 1, (dist / self.radius))
        rimRatioPower = mMix(smooth, rimRatioPower, angleRatioSmooth)
      end
    end
  end
  local height
  if distSq <= self.radiusSq then
    height = rimHeight - ((1 - rimRatioPower)*impact.craterDepth)
    if self.geothermalNoise then
      if realDistSq < self.geothermalRadiusSq * 2 then
        local geoWobbly = self.geothermalNoise:Radial(angle) + 1
        local geoRadiusSqWobbled = self.geothermalRadiusSq * geoWobbly
        local geoRatio = (realDistSq / geoRadiusSqWobbled) ^ 0.5
        if mRandom() > geoRatio then return 8 end
      end
    end
    if meteor.metal > 0 then
      for i, spot in pairs(self.metalSpots) do
        local metal = spot.noise:Get(x, y)
        if metal > 1 then return 7 end
      end
    end
    if impact.complex then
      if self.peakNoise then
        local peak = self.peakNoise:Get(x, y)
        if peak > impact.craterPeakHeight * 0.5 or mRandom() < peak / (impact.craterPeakHeight * 0.5) then
          return 2
        end
      end
      if height <= impact.meltSurface or mRandom() > (height - impact.meltSurface) / (impact.meltThickness) then
        return 4
      end
    elseif meteor.age < 15 then
      local rayWobbly = impact.rayNoise:Radial(angle) + 1
      local rayWidth = impact.rayWidth * rayWobbly
      local rayWidthMult = twicePi / rayWidth
      local rayHeight = mMax(mSin(rayWidthMult * angle) - 0.75, 0) * heightWobbly * rimRatio * (1-(meteor.age / 15))
      -- if rayHeight > 0.1 then return 6 end
      if mRandom() < rayHeight / 0.2 then return 6 end
    end
    if height > 0 and mRandom() < (height / rimHeight) then return 3 end
    return 1
  else
    local alpha = 0
    local fallDistSq = distSq - self.radiusSq
    if fallDistSq <= self.falloffSq then
      local gaussDecay = Gaussian(fallDistSq, self.falloffSqFourth)
      local linearGrowth = mMin(fallDistSq / self.falloffSq, 1)
      local linearDecay = 1 - linearGrowth
      local secondPower = 0.5
      if angleRatioSmooth < 1 then
        secondPower = 1 - (angleRatioSmooth * 0.5)
      end
      local secondDecay = 1 - (linearGrowth^secondPower)
      alpha = (gaussDecay * linearGrowth) + (secondDecay * linearDecay)
      -- height = diameterTransientFourth / (112 * (fallDistSq^1.5))
      if mRandom() < alpha then return 3 end
    end
    if impact.blastNoise then
      local blastWobbly = impact.blastNoise:Radial(angle) + 0.5
      local blastRadiusSqWobbled = self.blastRadiusSq * blastWobbly
      local blastRatio = (distSq / blastRadiusSqWobbled)
      if mRandom() * mMax(1-(impact.ageRatio*world.blastRayAgeDivisor), 0) > blastRatio then return 5 end
    end
  end
  return 0
end

function Crater:GiveStartingHeight()
  if self.startingHeight then return end
  if not self.renderer.heightBuf then return end
  local havg, hmin, hmax = self.renderer.heightBuf:GetCircle(self.x, self.y, self.radius)
  self.startingHeight = havg
end

----------------------------------------------------------

-- Meteor stores data, does not do any calcuations
local Meteor = class(function(a, world, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, seedSeed, ramps, mirrorMeteor)
  debugEcho(sx, sz, diameterImpactor, age, mirrorMeteor)
  -- coordinates sx and sz are in spring coordinates (elmos)
  a.world = world
  a.sx, a.sz = mFloor(sx), mFloor(sz)
  a.dispX, a.dispY = displayMapRuler:XZtoXY(a.sx, a.sz)
  a.diameterImpactor = diameterImpactor or 10
  -- debugEcho(mFloor(a.diameterImpactor) .. " meter object")
  a.velocityImpactKm = velocityImpactKm or 30
  a.angleImpact = angleImpact or 45
  a.densityImpactor = densityImpactor or 8000
  a.age = mMax(mMin(mFloor(age or 0), 100), 0)
  a.metal = metal or 0
  a.geothermal = geothermal
  a.seedSeed = seedSeed or NewSeed()
  a.ramps = ramps or {}
  a.mirrorMeteor = mirrorMeteor
end)

function Meteor:Collide()
  self.impact = Impact(self)
  self:PrepareDraw()
end

function Meteor:SetAge(age)
  self.age = age
  self:Collide()
end

function Meteor:Delete(noMirror)
  for i, m in pairs(self.world.meteors) do
    if m == self then
      tRemove(self.world.meteors, i)
      break
    end
  end
  if not noMirror and self.mirrorMeteor then
    self.mirrorMeteor:Delete(true)
  end
  self.impact = nil
  self = nil
end

function Meteor:NextSeed()
  self.seedSeed = NextSeed(self.seedSeed)
  self:Collide()
end

function Meteor:PreviousSeed()
  self.seedSeed = PreviousSeed(self.seedSeed)
  self:Collide()
end

function Meteor:ShiftUp()
  local newMeteors = {}
  local shiftDown
  for i, m in ipairs(self.world.meteors) do
    if m == self then
      if i == #self.world.meteors then
        -- can't shift up
        return
      end
      newMeteors[i+1] = self
      shiftDown = self.world.meteors[i+1]
      newMeteors[i] = shiftDown
    elseif m ~= shiftDown then
      newMeteors[i] = m
    end
  end
  self.world.meteors = newMeteors
  self.world:ResetMeteorAges()
  self:PrepareDraw()
end

function Meteor:ShiftDown()
  local newMeteors = {}
  local shiftUp
  for i = #self.world.meteors, 1, -1 do
    local m = self.world.meteors[i]
    if m == self then
      if i == 1 then
        -- can't shift down
        return
      end
      newMeteors[i-1] = self
      shiftUp = self.world.meteors[i-1]
      newMeteors[i] = shiftUp
    elseif m ~= shiftUp then
      newMeteors[i] = m
    end
  end
  self.world.meteors = newMeteors
  self.world:ResetMeteorAges()
  self:PrepareDraw()
end

function Meteor:Move(sx, sz, noMirror)
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= "boolean" then
    local nsx, nsz = self.world:MirrorXZ(sx, sz)
    if nsx then self.mirrorMeteor:Move(nsx, nsz, true) end
  end
  self.sx, self.sz = sx, sz
  self:Collide()
end

function Meteor:Resize(multiplier, noMirror)
  local targetRadius = self.impact.craterRadius * multiplier
  local targetRadiusM = targetRadius * self.world.metersPerElmo
  local targetDiameterM = targetRadiusM * 2
  local newDiameterImpactor
  local DensVeloGravAngle = ((self.densityImpactor / self.world.density) ^ 0.33) * (self.impact.velocityImpact ^ 0.44) * (self.world.gravity ^ -0.22) * (mSin(self.impact.angleImpactRadians) ^ 0.33)
  if targetRadius * 2 > self.world.complexDiameter then
    local targetDiameterKm = targetDiameterM / 1000
    local DcKm = self.world.complexDiameter / 1000
    -- debugEcho("complex")
    newDiameterImpactor = ((((targetDiameterKm*(DcKm^0.13))/1.17)^0.885)*1000 / (1.161*1.25*DensVeloGravAngle)) ^ 1.282
    newDiameterImpactor = newDiameterImpactor * 1.3805 -- obviously i screwed something up here, but it's a god enough approximation
  else
    -- debugEcho("simple")
    newDiameterImpactor = (  targetDiameterM / (  1.161 * 1.25 * DensVeloGravAngle )  ) ^ 1.282
  end
  self.diameterImpactor = newDiameterImpactor
  self:Collide()
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= "boolean" then
    self.mirrorMeteor:Resize(multiplier, true)
  end
end

function Meteor:IncreaseMetal()
  self:SetMetalSpotCount(self.metal+1)
end

function Meteor:DecreaseMetal()
  self:SetMetalSpotCount(mMax(self.metal-1, 0))
end

function Meteor:SetMetalSpotCount(spotCount, noMirror)
  local diff = spotCount - self.metal
  self.metal = spotCount
  self.world.metalSpotCount = self.world.metalSpotCount + diff
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= "boolean" then
    self.mirrorMeteor:SetMetalSpotCount(spotCount, true)
  end
  self:Collide()
end

function Meteor:GeothermalToggle(noMirror)
  self.geothermal = not self.geothermal
  if self.geothermal then
    self.world.geothermalMeteorCount = self.world.geothermalMeteorCount + 1
  else
    self.world.geothermalMeteorCount = self.world.geothermalMeteorCount - 1
  end
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= "boolean" then self.mirrorMeteor:GeothermalToggle(true) end
  self:Collide()
end

function Meteor:MetalGeothermal(noMirror, overwrite)
  if self.metalGeothermalSet and not overwrite then return end
  local world = self.world
  if self.diameterImpactor > world.minGeothermalMeteorDiameter and self.diameterImpactor < world.maxGeothermalMeteorDiameter then
    if world.geothermalMeteorCount < world.geothermalMeteorTarget then
      if not self.geothermal then world.geothermalMeteorCount = world.geothermalMeteorCount + 1 end
      self.geothermal = true
    end
  end
  if self.diameterImpactor > world.minMetalMeteorDiameter then
    if world.metalSpotCount < world.metalMeteorTarget then
      self:SetMetalSpotCount(mCeil(self.diameterImpactor / world.metalMeteorDiameter))
    end
  end
  self.metalGeothermalSet = true
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= boolean then
    self.mirrorMeteor:MetalGeothermal(true)
  end
end

function Meteor:AddRamp(angle, width)
  -- width in meters
  local ramp = { angle = angle, width = width }
  tInsert(self.ramps, ramp)
  self:Collide()
end

function Meteor:ClearRamps()
  self.ramps = {}
  self:Collide()
end

function Meteor:Mirror(binding)
  local nsx, nsz = self.world:MirrorXZ(self.sx, self.sz)
  if nsx then
    local bind
    if binding then bind = self end
    local mm = self.world:AddMeteor(nsx, nsz, VaryWithinBounds(self.diameterImpactor, 0.1, 1, 9999), VaryWithinBounds(self.velocityImpactKm, 0.1, 1, 120), VaryWithinBounds(self.angleImpact, 0.1, 1, 89), VaryWithinBounds(self.densityImpactor, 0.1, 1000, 10000), self.age, self.metal, self.geothermal, nil, nil, bind, true)
    if binding then self.mirrorMeteor = mm end
  end
end

function Meteor:PrepareDraw()
  self.rgb = { 0, (1-self.impact.ageRatio)*255, self.impact.ageRatio*255 }
  self.dispX, self.dispY = displayMapRuler:XZtoXY(self.sx, self.sz)
  self.dispCraterRadius = mCeil(self.impact.craterRadius / displayMapRuler.elmosPerPixel)
  for r, ramp in pairs(self.ramps) do
    ramp.dispX2, ramp.dispY2 = CirclePos(self.dispX, self.dispY, self.dispCraterRadius, ramp.angle)
    self.ramps[r] = ramp
  end
  self.infoStr = self.dispX .. ", " .. self.dispY .. "\n" .. self.dispCraterRadius .. " radius" .. "\n" .. self.metal .. " metal" .. "\n" .. self.age .. " age" .. "\n" .. self.seedSeed .. " seed"
  if self.geothermal then self.infoStr = self.infoStr .. "\ngeothermal" end
  if self.impact and self.impact.blastNoise then self.infoStr = self.infoStr .. "\nblast rays" end
  self.infoX = self.dispX - (self.dispCraterRadius * 1.5)
  self.infoY = self.dispY - (self.dispCraterRadius * 1.5)
end

----------------------------------------------------------

-- Impact does resolution-independent impact model calcuations, based on parameters from Meteor
-- impact model equations based on http://impact.ese.ic.ac.uk/ImpactEffects/effects.pdf
local Impact = class(function(a, meteor)
  a.meteor = meteor
  a.world = meteor.world
  a.seedPacket = CreateSeedPacket(meteor.seedSeed, 100)
  a:Model()
end)

function Impact:PopSeed()
  return tRemove(self.seedPacket)
end

function Impact:Model()
  local world = self.world
  local meteor = self.meteor

  self.craterSeedSeed = self:PopSeed()
  mRandomSeed(self:PopSeed())

  self.ageRatio = self.meteor.age / 100

  self.velocityImpact = meteor.velocityImpactKm * 1000
  self.angleImpactRadians = meteor.angleImpact * radiansPerDegree
  self.diameterTransient = 1.161 * ((meteor.densityImpactor / world.density) ^ 0.33) * (meteor.diameterImpactor ^ 0.78) * (self.velocityImpact ^ 0.44) * (world.gravity ^ -0.22) * (mSin(self.angleImpactRadians) ^ 0.33)
  self.diameterSimple = self.diameterTransient * 1.25
  self.depthTransient = self.diameterTransient / twoSqrtTwo
  self.rimHeightTransient = self.diameterTransient / 14.1
  self.rimHeightSimple = 0.07 * ((self.diameterTransient ^ 4) / (self.diameterSimple ^ 3))
  self.brecciaVolume = 0.032 * (self.diameterSimple ^ 3)
  self.brecciaDepth = 2.8 * self.brecciaVolume * ((self.depthTransient + self.rimHeightTransient) / (self.depthTransient * self.diameterSimple * self.diameterSimple))
  self.depthSimple = self.depthTransient - self.brecciaDepth

  self.rayWidth = 0.07 -- in radians

  self.craterRimHeight = self.rimHeightSimple / world.metersPerElmo

  self.heightWobbleAmount = MinMaxRandom(0.15, 0.35)
  self.rayWobbleAmount = MinMaxRandom(0.3, 0.4)

  self.complex = self.diameterTransient > world.complexDiameterCutoff
  if self.complex then
    self.bowlPower = 3
    local Dtc = self.diameterTransient / 1000
    local Dc = world.complexDiameter / 1000
    self.diameterComplex = 1.17 * ((Dtc ^ 1.13) / (Dc ^ 0.13))
    self.depthComplex = (1.04 / world.complexDepthScaleFactor) * (self.diameterComplex ^ 0.301)
    self.diameterComplex = self.diameterComplex * 1000
    self.depthComplex = self.depthComplex * 1000
    self.craterDepth = (self.depthComplex + self.rimHeightSimple) / world.metersPerElmo
    if world.rimTerracing then
      self.craterDepth = self.craterDepth * 0.6
      -- local terraceNum = mMin(4, mCeil(self.diameterTransient / world.complexDiameterCutoff))
      local terraceNum = 2 -- i can't figure out how to make more than two work
      self.terraceSeeds = {}
      for i = 1, terraceNum do self.terraceSeeds[i] = self:PopSeed() end
    end
    self.mass = (pi * (meteor.diameterImpactor ^ 3) / 6) * meteor.densityImpactor
    self.energyImpact = 0.5 * self.mass * (self.velocityImpact^2)
    self.meltVolume = 8.9 * 10^(-12) * self.energyImpact * mSin(self.angleImpactRadians)
    self.meltThickness = (4 * self.meltVolume) / (pi * (self.diameterTransient ^ 2))
    self.craterRadius = (self.diameterComplex / 2) / world.metersPerElmo
    self.craterMeltThickness = self.meltThickness / world.metersPerElmo
    self.meltSurface = self.craterRimHeight + self.craterMeltThickness - self.craterDepth
    -- debugEcho(self.energyImpact, self.meltVolume, self.meltThickness)
    self.craterPeakHeight = self.craterDepth * 0.5
    self.peakRadialNoise = WrapNoise(16, 0.75, self:PopSeed())
    self.distWobbleAmount = MinMaxRandom(0.075, 0.15)
    self.distNoise = WrapNoise(mMax(mCeil(self.craterRadius / 20), 8), self.distWobbleAmount, self:PopSeed(), 0.5, 3)
    -- debugEcho( mFloor(self.diameterImpactor), mFloor(self.diameterComplex), mFloor(self.depthComplex), self.diameterComplex/self.depthComplex, mFloor(self.diameterTransient), mFloor(self.depthTransient) )
    self.peakRadius = self.craterRadius / 5.5
  else
    self.bowlPower = 1
    self.craterDepth = ((self.depthSimple + self.rimHeightSimple)  ) / world.metersPerElmo
    -- self.craterDepth = self.craterDepth * mMin(1-self.ageRatio, 0.5)
    self.craterRadius = (self.diameterSimple / 2) / world.metersPerElmo
    self.craterFalloff = self.craterRadius * 0.66
    self.rayHeight = (self.craterRimHeight / 2)
    self.distWobbleAmount = MinMaxRandom(0.05, 0.15)
    self.distNoise = WrapNoise(mMax(mCeil(self.craterRadius / 35), 8), self.distWobbleAmount, self:PopSeed(), 0.3, 5)
    self.rayNoise = WrapNoise(24, self.rayWobbleAmount, self:PopSeed(), 0.5, 3)
  end

  self.metalSpots = {}
  if meteor.metal > 0 then
    local slots = meteor.metal
    local begin = 1
    if meteor.geothermal then
      slots = slots + 1
    end
    local dist = 0
    local metalSpotDiameter = world.metalSpotRadius * 2
    local metalSpotSeparation = metalSpotDiameter * 2.5
    if slots > 1 then dist = metalSpotSeparation / 1.9 end
    if self.peakRadius and not meteor.geothermal then
      dist = self.peakRadius * (1+self.peakRadialNoise.intensity)
    end
    local idealSlotsThisTier = mCeil((dist * 2 * pi * 0.9) / metalSpotSeparation)
    local slotsThisTier = mMin(idealSlotsThisTier, meteor.metal)
    local currentSlot = 1
    local remainingSpots = meteor.metal
    local angleOffset = 0
    for i = 1, meteor.metal do
      local x, z
      if dist == 0 then
        x, z = meteor.sx, meteor.sz
      else
        local angle = AngleAdd(((currentSlot-1) / slotsThisTier) * twicePi, angleOffset)
        x, z = CirclePos(meteor.sx, meteor.sz, dist, angle)
      end
      local spot = { x = x, z = z, metal = world.metalSpotAmount }
      tInsert(self.metalSpots, spot)
      currentSlot = currentSlot + 1
      remainingSpots = remainingSpots - 1
      if currentSlot > slotsThisTier and i < meteor.metal then
        dist = dist + metalSpotSeparation
        idealSlotsThisTier = mCeil((dist * 2 * pi * 0.9) / metalSpotSeparation)
        slotsThisTier = mMin(idealSlotsThisTier, remainingSpots)
        angleOffset = (twicePi / slotsThisTier) / 2
        currentSlot = 1
      end
    end
  end

  if self.complex and world.erosion then
    self.curveNoise = WrapNoise(mMax(mCeil(self.craterRadius / 25), 8), self.ageRatio * 0.5, self:PopSeed(), 0.3, 5)
  end

  self.heightNoise = WrapNoise(mMax(mCeil(self.craterRadius / 45), 8), self.heightWobbleAmount, self:PopSeed())
  if meteor.age < world.blastRayAge then
    self.blastNoise = WrapNoise(mMin(mMax(mCeil(self.craterRadius), 32), 512), 0.5, self:PopSeed(), 1, 1)
    -- debugEcho(self.blastNoise.length)
  end
end

----------------------------------------------------------

local WrapNoise = class(function(a, length, intensity, seed, persistence, N, amplitude)
  intensity = intensity or 1
  seed = seed or NewSeed()
  persistence = persistence or 0.25
  N = N or 6
  amplitude = amplitude or 1
  a.intensity = intensity
  a.angleDivisor = twicePi / length
  a.length = length
  a.halfLength = length / 2
  a.outValues = {}
  local values = {}
  local absMaxValue = 0
  local radius = mCeil(length / pi)
  local diameter = radius * 2
  local yx = Perlin.TwoD(seed, diameter+1, diameter+1, persistence, N, amplitude)
  local i = 1
  local angleIncrement = twicePi / length
  for angle = -pi, pi, angleIncrement do
    local x = mFloor(radius + (radius * mCos(angle))) + 1
    local y = mFloor(radius + (radius * mSin(angle))) + 1
    local val = yx[y][x]
    if mAbs(val) > absMaxValue then absMaxValue = mAbs(val) end
    values[i] = val
    i = i + 1
  end
  for n, v in pairs(values) do
    a.outValues[n] = (v / absMaxValue) * intensity
  end
end)

function WrapNoise:Smooth(n)
  local n1 = mFloor(n)
  local n2 = mCeil(n)
  if n1 == n2 then return self:Output(n1) end
  local val1, val2 = self:Output(n1), self:Output(n2)
  local d = val2 - val1
  return val1 + (mSmoothstep(n1, n2, n) * d)
end

function WrapNoise:Rational(ratio)
  return self:Smooth((ratio * (self.length - 1)) + 1)
end

function WrapNoise:Radial(angle)
  local n = ((angle + pi) / self.angleDivisor) + 1
  return self:Smooth(n)
end

function WrapNoise:Output(n)
  return self.outValues[self:Clamp(n)]
end

function WrapNoise:Dist(n1, n2)
  return mAbs((n1 + self.halfLength - n2) % self.length - self.halfLength)
end

function WrapNoise:Clamp(n)
  if n < 1 then
    n = n + self.length
  elseif n > self.length then
    n = n - self.length
  end
  return n
end

----------------------------------------------------------

local LinearNoise = class(function(a, length, intensity, seed, persistence, N, amplitude)
  intensity = intensity or 1
  seed = seed or NewSeed()
  persistence = persistence or 0.25
  N = N or 6
  amplitude = amplitude or 1
  a.outValues = {}
  a.length = length
  local values, min, max = Perlin.OneD(seed, length, persistence, N, amplitude)
  local absMaxValue = mMax(mAbs(max), mAbs(min))
  for n, v in ipairs(values) do
    a.outValues[n] = (v / absMaxValue) * intensity
  end
end)

function LinearNoise:Smooth(n)
  local n1 = mFloor(n)
  local n2 = mCeil(n)
  if n1 == n2 then return self:Output(n1) end
  local val1, val2 = self:Output(n1), self:Output(n2)
  local d = val2 - val1
  return val1 + (mSmoothstep(n1, n2, n) * d)
end

function LinearNoise:Rational(ratio)
  return self:Smooth((ratio * (self.length - 1)) + 1)
end

function LinearNoise:Output(n)
  return self.outValues[mCeil(n)] or 0
end

----------------------------------------------------------

local TwoDimensionalNoise = class(function(a, seed, sideLength, intensity, persistence, N, amplitude, blackValue, whiteValue)
  sideLength = mCeil(sideLength)
  intensity = intensity or 1
  persistence = persistence or 0.25
  N = N or 5
  amplitude = amplitude or 1
  seed = seed or NewSeed()
  blackValue = blackValue or 0
  whiteValue = whiteValue or 1
  local yx, vmin, vmax = Perlin.TwoD( seed, sideLength+1, sideLength+1, persistence, N, amplitude )
  local vd = vmax - vmin
  -- debugEcho("vmin", vmin, "vmax", vmax, "vd" , vd)
  a.xy = {}
  for y, xx in pairs(yx) do
    for x, v in pairs(xx) do
      a.xy[x] = a.xy[x] or {}
      local nv = (v - vmin) / vd
      nv = mMax(nv - blackValue, 0) / (1-blackValue)
      nv = mMin(nv, whiteValue) / whiteValue
      a.xy[x][y] = nv * intensity
    end
  end
  yx = nil
end)

function TwoDimensionalNoise:Get(x, y)
  x, y = mFloor(x), mFloor(y)
  if not self.xy[x] then return 0 end
  if not self.xy[x][y] then return 0 end
  return self.xy[x][y]
end

----------------------------------------------------------

local NoisePatch = class(function(a, x, y, radius, seed, intensity, persistence, N, amplitude, blackValue, whiteValue, wrapSeed, wrapLength, wrapIntensity, wrapPersistence, wrapN, wrapAmplitude)
  a.x = x
  a.y = y
  a.radius = radius * ((wrapIntensity or 0) + 1)
  a.radiusSq = a.radius*a.radius
  a.xmin = x - a.radius
  a.xmax = x + a.radius
  a.ymin = y - a.radius
  a.ymax = y + a.radius
  -- debugEcho(radius, wrapIntensity or 0, a.radius, a.radiusSq)
  a.twoD = TwoDimensionalNoise(seed, a.radius * 2, intensity, persistence, N, amplitude, blackValue, whiteValue)
  if wrapSeed then
    a.wrap = WrapNoise(wrapLength, wrapIntensity, wrapSeed, wrapPersistence, wrapN, wrapAmplitude)
  end
end)

function NoisePatch:Get(x, y)
  if x < self.xmin or x > self.xmax or y < self.ymin or y > self.ymax then return 0 end
  local dx = x - self.x
  local dy = y - self.y
  local distSq = (dx*dx) + (dy*dy)
  local radiusSqHere = self.radiusSq+0
  if self.wrap then
    local angle = AngleDXDY(dx, dy)
    local mult = (1+self.wrap:Radial(angle))
    distSq = distSq * mult
    radiusSqHere = radiusSqHere * mult
  end
  if distSq > radiusSqHere then return 0 end
  local ratio = 1 - (distSq / radiusSqHere)
  ratio = mSmoothstep(0, 1, ratio)
  local px, py = x - self.xmin, y - self.ymin
  return self.twoD:Get(px, py) * ratio
end

-- end classes and methods organized by class --------------------------------

local function SetOutputDirectory(outDirNew)
  outDir = outDirNew
end

-- export module

local Loony = {
  World = World,
  MapRuler = MapRuler,
  HeightBuffer = HeightBuffer,
  Renderer = Renderer,
  Crater = Crater,
  Impact = Impact,
  Meteor = Meteor,
  WrapNoise = WrapNoise,
  LinearNoise = LinearNoise,
  TwoDimensionalNoise = TwoDimensionalNoise,
  NoisePatch = NoisePatch,

  SetOutputDirectory = SetOutputDirectory,
}

return Loony