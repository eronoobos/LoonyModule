local classPath = "LoonyModule/class.lua"
local perlinPath = "LoonyModule/perlin.lua"
if not require then
  require = include
end
if package and package.path then package.path = package.path .. ';LoonyModule/?.lua' end
if love then
  classPath = "LoonyModule.class"
  perlinPath = "LoonyModule.perlin"
end
if VFS then
  require = VFS.Include
end
require(classPath)
local Perlin = require(perlinPath)

local M = {} -- module

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

local pi = math.pi
local twicePi = math.pi * 2
local piHalf = math.pi / 2
local piEighth = math.pi / 8
local piTwelfth = math.pi / 12
local piSixteenth = math.pi / 16
local twoSqrtTwo = 2 * math.sqrt(2)
local naturalE = math.exp(1)
local radiansPerDegree = math.pi / 180

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

local outDir = outDir or "output/"
local yesMare = false -- send huge melt-floor-generating meteors before a shower?
local doNotStore = true
local myWorld

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
  local ratioRGB = { aRGB[1] / 255, aRGB[2] / 255, aRGB[3] / 255 }
  AttributesByName[entry.name].ratioRGB = ratioRGB
  AttributeDict[i].ratioRGB = ratioRGB
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
    myWorld:MeteorShowerAuto(words[3], words[4], words[5], words[6], words[7], words[8], words[9], words[10], words[11], yesMare)
  end,
  clear = function(words, myWorld, uiCommand)
    myWorld:Clear()
  end,
  height = function(words, myWorld, uiCommand)
    myWorld:RenderHeightImage(myWorld.mapRulerNames[words[3]] or myWorld.heightMapRuler, uiCommand)
  end,
  attributes = function(words, myWorld, uiCommand)
    myWorld:RenderAttributes(myWorld.mapRulerNames[words[3]] or myWorld.heightMapRuler, "file", uiCommand)
  end,
  metal = function(words, myWorld, uiCommand)
    myWorld:RenderMetalFiles(uiCommand)
  end,
  features = function(words, myWorld, uiCommand)
    myWorld:RenderFeatures(uiCommand)
  end,
  maretoggle = function(words, myWorld, uiCommand)
    yesMare = not yesMare
    debugEcho("yesMare is now", tostring(yesMare))
  end,
  mirror = function(words, myWorld, uiCommand)
    myWorld.mirror = words[3]
    debugEcho("mirror: " .. myWorld.mirror)
  end,
  mirrornext = function(words, myWorld, uiCommand)
    local mt = MirrorNames[myWorld.mirror]+1
    if mt == #MirrorTypes+1 then mt = 1 end
    myWorld.mirror = MirrorTypes[mt]
    debugEcho("mirror: " .. myWorld.mirror)
  end,
  mirrorall = function(words, myWorld, uiCommand)
    myWorld:MirrorAll(words[3], words[4], words[5], words[6], words[7], words[8])
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
    local mapRuler = myWorld.mapRulerNames[words[3]] or myWorld.heightMapRuler
    myWorld:RenderFeatures()
    myWorld:RenderMetal()
    myWorld:RenderAttributes(mapRuler, "file")
    myWorld:RenderHeightImage(mapRuler, uiCommand)
  end,
}

------------------------------------------------------------------------------

-- local functions:

local function FeedWatchDog()
  if Spring and Spring.ClearWatchDogTimer then
    Spring.ClearWatchDogTimer()
  end
end

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
  local iter = function ()   -- iterator local function
    i = i + 1
    if a[i] == nil then return nil
    else return a[i], t[a[i]]
    end
  end
  return iter
end

local function DistanceSq(x1, y1, x2, y2)
  local dx = mAbs(x2 - x1)
  local dy = mAbs(y2 - y1)
  return (dx*dx) + (dy*dy)
end

local function AngleAdd(angle1, angle2)
  return (angle1 + angle2) % twicePi
end

local function AngleXYXY(x1, y1, x2, y2)
  local dx = x2 - x1
  local dy = y2 - y1
  return mAtan2(dy, dx), dx, dy
end

local function CirclePos(cx, cy, dist, angle)
  angle = angle or mRandom() * twicePi
  local x = cx + dist * mCos(angle)
  local y = cy + dist * mSin(angle)
  return mFloor(x), mFloor(y)
end

local function AngleMirror(angle, mirrorIndex)
  if mirrorIndex < 0 then
    return AngleAdd(angle, -mirrorIndex*radiansPerDegree)
  end
  local mirrorX, mirrorY
  if mirrorIndex == 1 or mirrorIndex == 3 then mirrorX = true end
  if mirrorIndex == 2 or mirrorIndex == 3 then mirrorZ = true end
  local dx, dy = CirclePos(0, 0, twoSqrtTwo, angle)
  if mirrorX then dx = -dx end
  if mirrorY then dy = -dy end
  return mAtan2(dy, dx)
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
  return mMax(mMin(value+RandomVariance(variance), maximum), minimum)
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
  debugEcho(currentFilename .. " written")
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

M.World = class(function(a, mapSize512X, mapSize512Z, metersPerElmo, gravity, density, mirror, metalTarget, geothermalTarget, showerRamps, noInit)
  a.mapSize512X = mapSize512X or 8
  a.mapSize512Z = mapSize512Z or 8
  a.metersPerElmo = metersPerElmo or 1 -- meters per elmo for meteor simulation model only
  a.gravity = gravity or (Game.gravity / 130) * 9.8
  a.density = density or (Game.mapHardness / 100) * 2500
  a.mirror = mirror or "none"
  a.metalTarget = metalTarget or 20
  a.geothermalTarget = geothermalTarget or 4
  a.showerRamps = showerRamps
  a.rampMinRadius = 300 -- elmos
  a.rampDefaultNumber = 2
  a.metalSpotMaxPerCrater = 3
  a.metalSpotAmount = 2.0
  a.metalSpotRadius = 50 -- elmos
  a.metalSpotDepth = 10
  a.metalSpotMinRadius = 100 -- elmos, the smallest crater radius that can contain a metal spot
  a.geothermalMinRadius = 200 -- elmos, the smallest crater radius that can contain a geo
  a.geothermalRadius = 16 -- elmos
  a.geothermalDepth = 10
  a.metalHeight = true -- draw metal depressions on the height map?
  a.geothermalHeight = true -- draw geothermal depressions on the height map?
  a.metalAttribute = true -- draw metal spots on the attribute map?
  a.geothermalAttribute = true -- draw geothermal vents on the attribute map?
  a.rimTerracing = false
  a.rayCraterNumber = 4
  a.blastRayCraterNumber = 3
  a.generateBlastNoise = true -- generate the noise used for attribute map blast rays
  a.generateAgeNoise = true
  a.erosion = true -- add bowl power noise to complex craters
  a.underlyingPerlin = false
  a.underlyingPerlinHeight = 50
  a.noMirrorRadius = 50 -- elmos, craters smaller than this are not mirrored by meteor showers
  -- local echostr = ""
  -- for k, v in pairs(a) do echostr = echostr .. tostring(k) .. "=" .. tostring(v) .. " " end
  -- debugEcho(echostr)
  if not noInit then
    a:Calculate()
    a:Clear()
  end
end)

function M.World:Calculate()
  self.mapSizeX = self.mapSize512X * 512
  self.mapSizeZ = self.mapSize512Z * 512
  self.centerX = self.mapSizeX / 2
  self.centerZ = self.mapSizeZ / 2
  self.smallestDimension = mMin(self.mapSizeX, self.mapSizeZ)
  self.halfSmallestDimension = self.smallestDimension / 2
  self.heightMapRuler = M.MapRuler(self, nil, (self.mapSizeX / Game.squareSize) + 1, (self.mapSizeZ / Game.squareSize) + 1)
  self.metalMapRuler = M.MapRuler(self, 16, (self.mapSizeX / 16), (self.mapSizeZ / 16))
  self.L3DTMapRuler = M.MapRuler(self, 4, (self.mapSizeX / 4), (self.mapSizeZ / 4))
  self.fullMapRuler = M.MapRuler(self, 1)

  self.mapRulerNames = {
    full = self.fullMapRuler,
    l3dt = self.L3DTMapRuler,
    height = self.heightMapRuler,
    spring = self.heightMapRuler,
    metal = self.metalMapRuler,
  }

  self.metalSpotDiameter = self.metalSpotRadius * 2
  self.metalSpotSeparation = self.metalSpotDiameter * 2.5
  self.metalSpotTotalArea = pi * (self.metalSpotSeparation ^ 2)
  self.complexDiameter = 3200 / (self.gravity / 9.8)
  local Dc = self.complexDiameter / 1000
  self.complexDiameterCutoff = ((Dc / 1.17) * (Dc ^ 0.13)) ^ (1/1.13)
  self.complexDiameterCutoff = self.complexDiameterCutoff * 1000
  self.complexDepthScaleFactor = ((self.gravity / 1.6) + 1) / 2
  self.rayAge = mCeil( (100 / 10) * self.rayCraterNumber )
  self.blastRayAge = mCeil( (100 / 10) * self.blastRayCraterNumber )
  self.blastRayAgeDivisor = 100 / self.blastRayAge
  self:ResetMeteorAges()
  M.UpdateWorld(self)
end

function M.World:Clear()
  self.meteors = {}
  self.renderers = {}
  self.metalSpotCount = 0
  self.geothermalMeteorCount = 0
end

function M.World:Save(name)
  name = name or ""
  FWriteOpen("world"..name, "lua", "w")
  FWrite("return ")
  serialize(self)
  FWriteClose()
end

function M.World:Load(luaStr)
  self:Clear()
  local loadWorld = loadstring(luaStr)
  local newWorld = loadWorld()
  for k, v in pairs(newWorld) do
    self[k] = v
  end
  self.meteors = {}
  self:Calculate()
  for i, m in pairs(newWorld.meteors) do
    local newM = M.Meteor(self, m.sx, m.sz, m.diameterImpactor, m.velocityImpactKm, m.angleImpact, m.densityImpactor, m.age, m.metal, m.geothermal, m.seedSeed, m.ramps, m.mirrorMeteor)
    newM:Collide()
    self.meteors[i] = newM
  end
  debugEcho("world loaded with " .. #self.meteors .. " meteors")
end

function M.World:RendererFrame(frame)
  local renderer = self.renderers[1]
  if renderer then
    FeedWatchDog()
    renderer:Frame(frame)
    M.FrameRenderer(renderer)
    if renderer.complete then
      tRemove(self.renderers, 1)
    end
  end
end

function M.World:MeteorShowerAuto(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity, underlyingMare)
  self:MeteorShower(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity, underlyingMare)
  self:SetMetalGeothermalRamp()
end

function M.World:MeteorShower(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity, underlyingMare)
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
  local diameters = {}
  local d = maxDiameter
  -- local div = maxDiameter ^ (1/(number-1))
  -- local root = maxDiameter ^ (1/((number-1)*2))
  for n = 1, number do
    tInsert(diameters, d)
    -- d = d / div
    d = d ^ (1/1.15)
  end
  local hundredConv = 100 / number
  local diameterDif = maxDiameter - minDiameter
  for n = 1, number do
    -- local diameter = minDiameter + (mAbs(DiceRoll(65)-0.5) * diameterDif * 2)
    local diameter = tRemoveRandom(diameters)
    local velocity = MinMaxRandom(minVelocity, maxVelocity)
    local angle = MinMaxRandom(minAngle, maxAngle)
    local density = MinMaxRandom(minDensity, maxDensity)
    local x = mFloor(mRandom() * self.mapSizeX)
    local z = mFloor(mRandom() * self.mapSizeZ)
    local m = self:AddMeteor(x, z, diameter, velocity, angle, density, mFloor((number-n)*hundredConv))
    if m.mirrorMeteor then
      -- block mirroring meteors that overlap eachother
      if DistanceSq(m.sx, m.sz, m.mirrorMeteor.sx, m.mirrorMeteor.sz) < (m.impact.craterRadius + m.mirrorMeteor.impact.craterRadius) ^ 2 then
        if m.impact.craterRadius < mMin(self.mapSizeX, self.mapSizeZ) / 3 then
          -- try again for craters less than a third of the smallest map axis
          m:Delete()
          tInsert(diameters, diameter)
          number = number + 1
        else
          -- move big craters to the center and delete their mirror
          m.mirrorMeteor:Delete(true)
          x = self.mapSizeX/2 + RandomVariance(20)
          z = self.mapSizeZ/2 + RandomVariance(20)
          m:Move(x, z)
        end
      elseif m.impact.craterRadius < self.noMirrorRadius then
        -- allow tiny craters to not be mirrored
        m.mirrorMeteor:Delete(true)
      end
    end
  end
  self:ResetMeteorAges()
  debugEcho("shower done", #self.meteors .. " meteors")
end

function M.World:SetMetalGeothermalRamp(overwrite)
  for i = #self.meteors, 1, -1 do
    local m = self.meteors[i]
    m:MetalGeothermalRamp(nil, overwrite)
  end
end

function M.World:ResetMeteorAges()
  if not self.meteors then return end
  self.rayAge = mCeil( (100 / #self.meteors) * self.rayCraterNumber )
  self.blastRayAge = mCeil( (100 / #self.meteors) * self.blastRayCraterNumber )
  self.blastRayAgeDivisor = 100 / self.blastRayAge
  for i, m in pairs(self.meteors) do
    m:SetAge(((#self.meteors-i)/#self.meteors)*100)
  end
end

function M.World:AddMeteor(sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, seedSeed, ramps, mirrorMeteor, noMirror)
  local m = M.Meteor(self, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, seedSeed, ramps, mirrorMeteor)
  tInsert(self.meteors, m)
  if self.mirror ~= "none" and not mirrorMeteor and not noMirror then
    m:Mirror(true)
  end
  m:Collide()
  if m.geothermal then self.geothermalMeteorCount = self.geothermalMeteorCount + 1 end
  self.metalSpotCount = self.metalSpotCount + m.metal
  return m
end

function M.World:AddStartMeteor(sx, sz, diameterImpactor)
  local m = self:AddMeteor(sx, sz, diameterImpactor, nil, nil, nil, nil, 3, false)
  if self.showerRamps then m:AddSomeRamps() end
  m.metalGeothermalRampSet = true
  m.start = true
end

function M.World:AddMirrorMeteor(meteor, binding, mirrorIndex)
  local bind
  if binding then bind = meteor end
  local mm = meteor:Mirror(binding, mirrorIndex)
  tInsert(self.meteors, mm)
  mm.metalGeothermalRampSet = meteor.metalGeothermalRampSet
  mm.start = meteor.start
  if meteor.start then
    if self.showerRamps then mm:AddSomeRamps() end
    mm:Collide()
  end
  if binding then meteor.mirrorMeteor = mm end
  return mm
end

-- mirrorIndex
-- 1 == x only, 2 == z only, 3 == x and z, -120 = rotate by 120 degrees
function M.World:MirrorAll(...) -- mirrorIndex, mirrorIndex, mirrorIndex
  local meteorsCopy = tDuplicate(self.meteors) -- so that we don't infinite mirror
  self.meteors = {}
  local newMeteors = {}
  local mirrorIndices = {...}
  if type(mirrorIndices[1]) == "table" then
    mirrorIndices = mirrorIndices[1]
  end
  for i = #meteorsCopy, 1, -1 do
    local m = meteorsCopy[i]
    local mms = {}
    if not m.dontMirror and m.impact.craterRadius >= self.noMirrorRadius then
      for ii, mirrorIndex in pairs(mirrorIndices) do
        local mm = m:Mirror(false, mirrorIndex)
        -- block mirroring meteors that overlap eachother
        if not m.impact then m:Collide() end
        mm:Collide()
        if DistanceSq(m.sx, m.sz, mm.sx, mm.sz) < (m.impact.craterRadius + mm.impact.craterRadius) ^ 2 then
          -- remove craters less than a third of the smallest map axis
          m = nil
          tRemove(meteorsCopy, i)
          break
        else
          tInsert(mms, {mi = mirrorIndex, mm = mm})
        end
      end
    end
    if m then
      tInsert(newMeteors, m)
      m.mirrorAlled = {}
      for i, entry in pairs(mms) do
        local mirrorIndex = entry.mi
        local mm = entry.mm
        m.mirrorAlled[mirrorIndex] = m.mirrorAlled[mirrorIndex] or {}
        tInsert(m.mirrorAlled[mirrorIndex], mm)
        tInsert(newMeteors, mm)
      end
    end
  end
  for i = #newMeteors, 1, -1 do
    local m = newMeteors[i]
    tInsert(self.meteors, m)
  end
end

function M.World:SetMetalGeothermalRampPostMirrorAll()
  for i = #self.meteors, 1, -1 do
    local m = self.meteors[i]
    if m.mirrorAlled then
      m:MetalGeothermalRamp()
      for mirrorIndex, mms in pairs(m.mirrorAlled) do
        for ii, mm in pairs(mms) do
          m:CopyMetalGeothermalRamp(mm, mirrorIndex)
        end
      end
    end
  end
end

function M.World:RenderAttributes(mapRuler, renderSubtype, uiCommand)
  mapRuler = mapRuler or self.heightMapRuler
  renderSubtype = renderSubtype or "file"
  local renderer = M.Renderer(self, mapRuler, 8000, "Attributes", renderSubtype, uiCommand)
  tInsert(self.renderers, renderer)
end

function M.World:RenderHeightImage(mapRuler, uiCommand)
  mapRuler = mapRuler or self.L3DTMapRuler
  local tempHeightBuf = M.HeightBuffer(self, mapRuler)
  tInsert(self.renderers, M.Renderer(self, mapRuler, 4000, "Height", "data", uiCommand, tempHeightBuf))
  tInsert(self.renderers, M.Renderer(self, mapRuler, 15000, "HeightImage", "file", uiCommand, tempHeightBuf))
end

function M.World:RenderHeight(mapRuler, uiCommand)
  mapRuler = mapRuler or self.heightMapRuler
  local tempHeightBuf = M.HeightBuffer(self, mapRuler)
  tInsert(self.renderers, M.Renderer(self, mapRuler, 4000, "Height", "data", uiCommand, tempHeightBuf))
end

function M.World:RenderMetal(uiCommand)
  local renderer = M.Renderer(self, self.metalMapRuler, 16000, "Metal", "data", uiCommand)
  tInsert(self.renderers, renderer)
end

function M.World:RenderMetalFiles(uiCommand)
  local renderer = M.Renderer(self, self.metalMapRuler, 16000, "Metal", "file", uiCommand)
  tInsert(self.renderers, renderer)
end

function M.World:RenderFeatures()
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

function M.World:GetFeaturelist()
  local objectlist = {}
  for i, m in pairs(self.meteors) do
    if m.geothermal then
      tInsert(objectlist, {name = 'GeoVent', x = m.sx, z = m.sz, rot = "180"})
    end
  end
  return objectlist
end

function M.World:GetMetalSpots()
  local metalSpots = {}
  for i, meteor in pairs(self.meteors) do
    if meteor.metal > 0 then
      for i, spot in pairs(meteor.impact.metalSpots) do
        tInsert(metalSpots, spot)
      end
    end
  end
  return metalSpots
end

function M.World:MirrorXZ(x, z, mirrorIndex)
  if not mirrorIndex then
    if self.mirror == "relfectionalx" then
      mirrorIndex = 1
    elseif self.mirror == "relfectionalz" then
      mirrorIndex = 2
    elseif self.mirror == "rotational" then
      mirrorIndex = 3
    end
  end
  if not mirrorIndex or mirrorIndex == 0 then return x, z end
  local nx, nz
  if mirrorIndex < 0 then
    local angle, dx, dz = AngleXYXY(self.centerX, self.centerZ, x, z)
    local dist = mFloor(mSqrt((dx*dx)+(dz*dz)))
    local nangle = AngleAdd(angle, -mirrorIndex*radiansPerDegree)
    nx, nz = CirclePos(self.centerX, self.centerZ, dist, nangle)
    -- debugEcho(x, z, self.centerX, self.centerZ, dist, angle, nangle, nx, nz)
  elseif mirrorIndex == 1 then
    nx = self.mapSizeX - x
    nz = z+0
  elseif mirrorIndex == 2 then
    nx = x+0
    nz = self.mapSizeZ - z
  elseif mirrorIndex == 3 then
    nx = self.mapSizeX - x
    nz = self.mapSizeZ - z
  end
  return nx, nz
end

function M.World:InterpretCommand(msg)
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

M.MapRuler = class(function(a, world, elmosPerPixel, width, height)
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

function M.MapRuler:XZtoXY(x, z)
  if self.elmosPerPixel == 1 then
    return x+1, z+1
  else
    local hx = mFloor(x / self.elmosPerPixel) + 1
    local hy = mFloor(z / self.elmosPerPixel) + 1
    return hx, hy
  end
end

function M.MapRuler:XYtoXZ(x, y)
  if self.elmosPerPixel == 1 then
    return x-1, y-1
  else
    local sx = mFloor((x-1) * self.elmosPerPixel)
    local sz = mFloor((y-1) * self.elmosPerPixel)
    return sx, sz
  end
end

function M.MapRuler:RadiusBounds(x, y, radius)
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

M.HeightBuffer = class(function(a, world, mapRuler)
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

function M.HeightBuffer:CoordsOkay(x, y)
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

function M.HeightBuffer:MinMaxCheck(height)
  if height > self.maxHeight then self.maxHeight = height end
  if height < self.minHeight then self.minHeight = height end
end

function M.HeightBuffer:Add(x, y, height, alpha)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  alpha = mMin(1, mMax(0, alpha))
  local newHeight = self.heights[x][y] + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
end

function M.HeightBuffer:Blend(x, y, height, alpha, secondary)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  alpha = mMin(1, mMax(0, alpha))
  if alpha < 1 and self.heights[x][y] > height then alpha = alpha * alpha end
  local orig = 1 - alpha
  local newHeight = (self.heights[x][y] * orig) + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
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

function M.HeightBuffer:Set(x, y, height)
  if not self:CoordsOkay(x, y) then return end
  self.heights[x][y] = height
  self:MinMaxCheck(height)
end

function M.HeightBuffer:Get(x, y)
  if not self:CoordsOkay(x, y) then return end
  return self.heights[x][y]
end

function M.HeightBuffer:GetCircle(x, y, radius)
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

function M.HeightBuffer:Clear()
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

M.Renderer = class(function(a, world, mapRuler, pixelsPerFrame, renderType, renderSubtype, uiCommand, heightBuf)
  a.world = world
  a.mapRuler = mapRuler or world.heightMapRuler
  a.pixelsPerFrame = pixelsPerFrame or 1000
  a.renderType = renderType or "Height"
  a.renderSubtype = renderSubtype or "none"
  a.uiCommand = uiCommand or ""
  a.heightBuf = heightBuf
  a.craters = {}
  a.totalCraterArea = 0
  a.pixelsRendered = 0
  a.pixelsToRenderCount = mapRuler.width * mapRuler.height
  a.totalPixels = a.pixelsToRenderCount+0
  a.PreinitFunc = a[a.renderType .. "Preinit"] or a.Empty
  a.InitFunc = a[a.renderType .. "Init"] or a.Empty
  a.FrameFunc = a[a.renderType .. "Frame"] -- if there's no framefunc what's the point
  a.FinishFunc = a[a.renderType .. "Finish"] or a.Empty
  a:Preinitialize()
end)

function M.Renderer:GetCraters()
  for i, m in ipairs(self.world.meteors) do
    m:Collide()
    local crater = M.Crater(m.impact, self)
    tInsert(self.craters, crater)
    self.totalCraterArea = self.totalCraterArea + crater.area
  end
end

function M.Renderer:Preinitialize()
  self:PreinitFunc()
  self.preInitialized = true
end

function M.Renderer:Initialize(frame)
  self.startFrame = frame
  self.totalProgress = self.totalPixels
  self:InitFunc()
  self.initialized = true
end

function M.Renderer:Frame(frame)
  if not self.initialized then self:Initialize(frame) end
  local progress = self:FrameFunc()
  if progress then
    self.progress = (self.progress or 0) + progress
  end
  if self.progress > self.totalProgress or not progress then
    self:Finish(frame)
  end
end

function M.Renderer:Finish(frame)
  self:FinishFunc()
  if not self.dontEndUiCommand then M.EndUiCommand(self.uiCommand) end
  local timeDiff = frame - self.startFrame
  debugEcho(self.renderType .. " (" .. self.mapRuler.width .. "x" .. self.mapRuler.height .. ") rendered in " .. timeDiff .. " render frames")
  self.complete = true
  M.CompleteRenderer(self)
end

function M.Renderer:Empty()
end

function M.Renderer:HeightInit()
  self:GetCraters()
  self.totalProgress = self.totalCraterArea
  if self.world.underlyingPerlin then
    --seed, sideLength, intensity, persistence, N, amplitude, blackValue, whiteValue)
    local baseN = 10 + mFloor(self.world.underlyingPerlinHeight / 200)
    local persistence = baseN * 0.028
    debugEcho("baseN " .. baseN, "persistence " .. persistence)
    local perlin = M.TwoDimensionalNoise(NewSeed(), mMax(self.mapRuler.width, self.mapRuler.height), self.world.underlyingPerlinHeight, persistence, baseN-self.mapRuler.elmosPerPixelPowersOfTwo)
    self.heightBuf.heights = perlin.xy
  end
end

function M.Renderer:HeightFrame()
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

function M.Renderer:HeightFinish()
  self.dontEndUiCommand = true
  if self.renderSubtype == "data" then
    self.data = self.heightBuf.heights
  end
end

function M.Renderer:HeightImageInit()
  FWriteOpen("height_" .. self.mapRuler.width .. "x" .. self.mapRuler.height, "pgm")
  FWrite("P5 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " " .. 65535 .. " ")
end

function M.Renderer:HeightImageFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  local heightBuf = self.heightBuf
  local heightDif = (heightBuf.maxHeight - heightBuf.minHeight)
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    -- local y = self.mapRuler.height - mFloor(p / self.mapRuler.width) --pgm goes backwards y?
    local y = mFloor(p / self.mapRuler.width) + 1
    local pixelHeight = heightBuf:Get(x, y) or 0
    local pixelColor = mFloor(((pixelHeight - heightBuf.minHeight) / heightDif) * 65535)
    local twochars = uint16big(pixelColor)
    FWrite(twochars)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function M.Renderer:HeightImageFinish()
  FWriteClose()
  debugEcho("height File sent")
  FWriteOpen("heightrange", "txt", "w")
  FWrite(
    "min: " .. self.heightBuf.minHeight .. "\n\r" ..
    "max: " .. self.heightBuf.maxHeight .. "\n\r" ..
    "range: " .. (self.heightBuf.maxHeight - self.heightBuf.minHeight))
  FWriteClose()
end

function M.Renderer:AttributesInit()
  self:GetCraters()
  if self.renderSubtype == "data" then
    self.data = {}
  elseif self.renderSubtype == "file" then
    FWriteOpen("attrib_" .. self.mapRuler.width .. "x" .. self.mapRuler.height, "pbm")
    FWrite("P6 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " 255 ")
  end
end

function M.Renderer:AttributesFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = mFloor(p / self.mapRuler.width) + 1
    local attribute = 0
    for i, c in ipairs(self.craters) do
      local a = c:AttributePixel(x, y)
      if a ~= 0 and not AttributeOverlapExclusions[a][attribute] then
        attribute = a
      end
    end
    if self.renderSubtype == "data" then
      self.data[x] = self.data[x] or {}
      self.data[x][y] = attribute
    elseif self.renderSubtype == "file" then
      FWrite(AttributeDict[attribute].threechars)
    end
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function M.Renderer:AttributesFinish()
  if self.renderSubtype == "file" then
    FWriteClose()
  end
end

function M.Renderer:MetalPreinit()
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

function M.Renderer:MetalInit()
  self.data = {}
  for x = 0, self.mapRuler.width-1 do
    self.data[x] = {}
    for y = 0, self.mapRuler.height-1 do
      self.data[x][y] = 0
    end
  end
  if self.renderSubtype == "file" then
    FWriteOpen("metal", "lua", "w")
    FWrite("return {\n\tspots = {\n")
  end
  for i, spot in pairs(self.metalSpots) do
    if self.renderSubtype == "file" then
      FWrite("\t\t{x = " .. spot.x .. ", z = " .. spot.z .. ", metal = " .. spot.metal .. "},\n")
    end
    WriteMetalSpot(self.data, spot.x, spot.z, spot.metal)
  end
  if self.renderSubtype == "file" then
    FWrite("\t}\n}")
    FWriteClose()
    debugEcho("wrote metal to data and wrote metal config lua")
    FWriteOpen("metal", "pbm")
    FWrite("P6 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " 255 ")
    self.zeroTwoChars = string.char(0) .. string.char(0)
    self.blackThreeChars = string.char(0) .. string.char(0) .. string.char(0)
  end
end

function M.Renderer:MetalFrame()
  if self.renderSubtype == "data" then
    return self.totalProgress + 1
  end
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

function M.Renderer:MetalFinish()
  if self.renderSubtype == "file" then FWriteClose() end
end

----------------------------------------------------------

-- M.Crater actually gets rendered. scales horizontal distances to the frame being rendered (does resolution-dependent calculations, based on an M.Impact)
M.Crater = class(function(a, impact, renderer)
  local world = impact.world
  local elmosPerPixel = renderer.mapRuler.elmosPerPixel
  local elmosPerPixelP2 = renderer.mapRuler.elmosPerPixelPowersOfTwo
  a.impact = impact
  a.renderer = renderer
  local meteor = impact.meteor
  a.impact:GenerateNoise()

  a.seedPacket = CreateSeedPacket(impact.craterSeedSeed, 100)

  a.x, a.y = renderer.mapRuler:XZtoXY(meteor.sx, meteor.sz)
  a.radius = impact.craterRadius / elmosPerPixel

  a.falloff = impact.craterFalloff / elmosPerPixel
  a.peakC = (a.radius / 8) ^ 2
  a.totalradius = a.radius + a.falloff
  a.totalradiusSq = a.totalradius * a.totalradius
  a.totalradiusPlusWobble = a.totalradius*(1+impact.distNoise.intensity)
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
      -- length, intensity, seed, persistence, N, amplitude
      widthNoise = M.LinearNoise(10, 0.2, a:PopSeed(), 0.25),
      angleNoise = M.LinearNoise(25, 0.05, a:PopSeed(), 0.25) }
    tInsert(a.ramps, cRamp)
  end

  a.metalSpots = {}
  if meteor.metal > 0 and world.metalAttribute then -- note: this needs to be expanded for multiple metal spots
    for i, spot in pairs(impact.metalSpots) do
      local x, y = renderer.mapRuler:XZtoXY(spot.x, spot.z)
      local radius = mCeil(world.metalSpotRadius / elmosPerPixel)
      local noise = M.NoisePatch(x, y, radius, a:PopSeed(), world.metalSpotDepth, 0.3, 5-elmosPerPixelP2, 1, 0.4)
      local cSpot = { x = x, y = y, metal = spot.metal, radius = radius, radiusSq = radius^2, noise = noise }
      tInsert(a.metalSpots, cSpot)
    end
  end
  if meteor.geothermal and world.geothermalAttribute then
    a.geothermalRadius = mCeil(world.geothermalRadius / elmosPerPixel)
    a.geothermalRadiusSq = a.geothermalRadius^2
    a.geothermalNoise = M.WrapNoise(22, 1, a:PopSeed(), 1, 1)
  end


  if impact.complex and not meteor.geothermal then
    a.peakRadius = impact.peakRadius / elmosPerPixel
    a.peakRadiusSq = a.peakRadius ^ 2
    local baseN = 8 + mFloor(impact.peakRadius / 300)
    -- x, y, radius, seed, intensity, persistence, N, amplitude, blackValue, whiteValue)
    a.peakNoise = M.NoisePatch(a.x, a.y, a.peakRadius, a:PopSeed(), impact.craterPeakHeight, 0.3, baseN-elmosPerPixelP2, 1, 0.5)
  end

  if impact.terraceSeeds then
    local tmin = a.radiusSq * 0.35
    local tmax = a.radiusSq * 0.8
    local tdif = tmax - tmin
    local terraceWidth = tdif / #impact.terraceSeeds
    local terraceFlatWidth = terraceWidth * 0.5
    a.terraces = {}
    for i = 1, #impact.terraceSeeds do
      a.terraces[i] = { max = tmin + (i*terraceWidth), noise = M.WrapNoise(12, terraceWidth*2, impact.terraceSeeds[i], 0.5, 2) }
    end
    a.terraceMin = tmin
  end

  a.width = a.xmax - a.xmin + 1
  a.height = a.ymax - a.ymin + 1
  a.area = a.width * a.height
  a.currentPixel = 0
end)

function M.Crater:AddAgeNoise()
  if not self.impact.world.generateAgeNoise then return end
  if self.ageNoise then return end
  if self.impact.meteor.age > 0 and self.totalradiusPlusWobble < 1000 then -- otherwise, way too much memory
    self.ageNoise = M.NoisePatch(self.x, self.y, self.totalradiusPlusWobble, self:PopSeed(), 1, 0.33, 10-self.renderer.mapRuler.elmosPerPixelPowersOfTwo)
  end
end

function M.Crater:PopSeed()
  return tRemove(self.seedPacket)
end

function M.Crater:DistanceSq(x, y, dx, dy)
  dx = dx or mAbs(x-self.x)
  dy = dy or mAbs(y-self.y)
  if doNotStore then return ((dx*dx) + (dy*dy)) end
  diffDistancesSq[dx] = diffDistancesSq[dx] or {}
  diffDistancesSq[dx][dy] = diffDistancesSq[dx][dy] or ((dx*dx) + (dy*dy))
  return diffDistancesSq[dx][dy]
end

function M.Crater:Distance(x, y)
  local dx, dy = mAbs(x-self.x), mAbs(y-self.y)
  if doNotStore then return sqrt((dx*dx) + (dy*dy)) end
  diffDistances[dx] = diffDistances[dx] or {}
  if not diffDistances[dx][dy] then
    local distSq = self:DistanceSq(x, y)
    diffDistances[dx][dy] = sqrt(distSq)
  end
  return diffDistances[dx][dy], diffDistancesSq[dx][dy]
end

function M.Crater:TerraceDistMod(distSq, angle)
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

function M.Crater:HeightPixel(x, y)
  if x < self.xmin or x > self.xmax or y < self.ymin or y > self.ymax then return 0, 0, false end
  local impact = self.impact
  local meteor = self.impact.meteor
  local world = meteor.world
  local dx, dy = x-self.x, y-self.y
  local angle = AngleDXDY(dx, dy)
  local distWobbly = impact.distNoise:Radial(angle) + 1
  local realDistSq = self:DistanceSq(nil, nil, mAbs(dx), mAbs(dy))
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
    if impact.complex then
      if self.peakNoise then
        local peak = self.peakNoise:Get(x, y)
        height = height + peak
      end
      if height < impact.meltSurface then height = impact.meltSurface end
    elseif meteor.age < world.rayAge then
      local rayWobbly = impact.rayNoise:Radial(angle) + 1
      local rayWidth = impact.rayWidth * rayWobbly
      local rayWidthMult = twicePi / rayWidth
      local rayHeight = mMax(mSin(rayWidthMult*angle) - 0.75, 0) * impact.rayHeight * heightWobbly * rimRatio * impact.rayAgeRatio
      height = height - rayHeight
    end
  else
    add = true
    height = rimHeight
    local fallDistSq = distSq - self.radiusSq
    if fallDistSq <= self.falloffSq then
      -- alpha = (fallDistSq+1) ^ (-3)
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
  if world.geothermalHeight and self.geothermalNoise then
    if realDistSq < self.geothermalRadiusSq * 2 then
      local geoWobbly = self.geothermalNoise:Radial(angle) + 1
      local geoRadiusSqWobbled = self.geothermalRadiusSq * geoWobbly
      local geoRatio = mMin(1, (realDistSq / geoRadiusSqWobbled) ^ 0.5)
      height = height - ((1-geoRatio) * world.geothermalDepth)
    end
  end
  if world.metalHeight and meteor.metal > 0 then
    for i, spot in pairs(self.metalSpots) do
      local metal = spot.noise:Get(x, y)
      height = height - metal
    end
  end
  return height, alpha, add
end

function M.Crater:OneHeightPixel()
  local p = self.currentPixel
  local x = (p % self.width) + self.xmin
  local y = mFloor(p / self.width) + self.ymin
  self.currentPixel = self.currentPixel + 1
  local height, alpha, add = self:HeightPixel(x, y)
  return x, y, height, alpha, add
end

function M.Crater:AttributePixel(x, y)
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

function M.Crater:GiveStartingHeight()
  if self.startingHeight then return end
  if not self.renderer.heightBuf then return end
  local havg, hmin, hmax = self.renderer.heightBuf:GetCircle(self.x, self.y, self.radius)
  self.startingHeight = havg
end

----------------------------------------------------------

-- M.Meteor stores data, does not do any calcuations
M.Meteor = class(function(a, world, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, seedSeed, ramps, mirrorMeteor)
  -- debugEcho(sx, sz, diameterImpactor, age, mirrorMeteor)
  -- coordinates sx and sz are in spring coordinates (elmos)
  a.world = world
  a.sx, a.sz = mFloor(sx), mFloor(sz)
  a.diameterImpactor = diameterImpactor or 10
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

function M.Meteor:Collide()
  self.impact = M.Impact(self)
  M.UpdateMeteor(self)
end

function M.Meteor:SetAge(age)
  self.age = age
  self:Collide()
end

function M.Meteor:Delete(noMirror)
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

function M.Meteor:NextSeed()
  self.seedSeed = NextSeed(self.seedSeed)
  self:Collide()
end

function M.Meteor:PreviousSeed()
  self.seedSeed = PreviousSeed(self.seedSeed)
  self:Collide()
end

function M.Meteor:ShiftUp()
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
end

function M.Meteor:ShiftDown()
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
end

function M.Meteor:Move(sx, sz, noMirror)
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= "boolean" then
    local nsx, nsz = self.world:MirrorXZ(sx, sz)
    if nsx then self.mirrorMeteor:Move(nsx, nsz, true) end
  end
  self.sx, self.sz = sx, sz
  self:Collide()
end

function M.Meteor:Resize(targetRadius, noMirror)
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

function M.Meteor:IncreaseMetal()
  self:SetMetalSpotCount(self.metal+1)
end

function M.Meteor:DecreaseMetal()
  self:SetMetalSpotCount(mMax(self.metal-1, 0))
end

function M.Meteor:SetMetalSpotCount(spotCount, noMirror)
  local diff = spotCount - self.metal
  self.metal = spotCount
  self.world.metalSpotCount = self.world.metalSpotCount + diff
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= "boolean" then
    self.mirrorMeteor:SetMetalSpotCount(spotCount, true)
  end
  self:Collide()
end

function M.Meteor:GeothermalToggle(noMirror)
  self.geothermal = not self.geothermal
  if self.geothermal then
    self.world.geothermalMeteorCount = self.world.geothermalMeteorCount + 1
  else
    self.world.geothermalMeteorCount = self.world.geothermalMeteorCount - 1
  end
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= "boolean" then self.mirrorMeteor:GeothermalToggle(true) end
  self:Collide()
end

function M.Meteor:BlockedMetalGeothermal()
  if not self.impact then self:Collide() end
  local meteors = self.world.meteors
  local blocked = false
  local metalRingRadius = (self.impact.metalRingRadius or self.world.geothermalMinRadius) + self.world.metalSpotRadius
  if self.mirrorAlled then
    -- prevent rotationally mirrored maps from putting metal & geos on craters that will be mirrored off the map edge
    for mirrorIndex, mms in pairs(self.mirrorAlled) do
      if mirrorIndex < 0 then
        local distSq = DistanceSq(self.world.centerX, self.world.centerZ, self.sx, self.sz) 
        if distSq > (self.world.halfSmallestDimension-(metalRingRadius)) ^ 2 then
          -- debugEcho("metalgeo block radial symmetry")
          return true
        else
          break
        end
      end
    end
  end
  if self.sx < metalRingRadius or self.sx > self.world.mapSizeX-metalRingRadius or self.sz < metalRingRadius or self.sz > self.world.mapSizeZ-metalRingRadius then
    return true
  end
  for i = #meteors, 1, -1 do
    local m = meteors[i]
    if m == self then break end
    if not m.impact then m:Collide() end
    local distSq = DistanceSq(self.sx, self.sz, m.sx, m.sz)
    local radiiSq = (m.impact.craterRadius + self.impact.craterRadius) ^ 2
    if m.impact.craterRadius >= self.world.noMirrorRadius and distSq < radiiSq then
      blocked = true
      -- debugEcho(self.sx, self.sz, self.impact.craterRadius, "blocked by", m.sx, m.sz, m.impact.craterRadius)
      break
    end
    if self.mirrorMeteor or self.mirrorAlled then
      local mirrorList = self.mirrorAlled or {[0] = {self.mirrorMeteor}}
      for mirrorIndex, mms in pairs(mirrorList) do
        for i, mm in pairs(mms) do
          if not mm.impact then mm:Collide() end
          distSq = DistanceSq(mm.sx, mm.sz, m.sx, m.sz)
          radiiSq = (m.impact.craterRadius + mm.impact.craterRadius) ^ 2
          if distSq < radiiSq then
            blocked = true
            -- debugEcho(self.sx, self.sz, self.impact.craterRadius, "blocked by", m.sx, m.sz, m.impact.craterRadius)
            break
          end
        end
        if blocked then break end
      end
    end
    if blocked then break end
  end
  return blocked
end

function M.Meteor:MetalGeothermalRamp(noMirror, overwrite)
  if self.metalGeothermalRampSet and not overwrite then return end
  if not self.impact then self:Collide() end
  local world = self.world
  local impact = self.impact
  local metalMinRadius = world.metalSpotMinRadius
  local blocked = self:BlockedMetalGeothermal()
  local unequal = world.mirror ~= "none" and not self.mirrorMeteor
  if not unequal and not blocked and impact.craterRadius > world.geothermalMinRadius then
      if world.geothermalMeteorCount < world.geothermalTarget then
        if self.sx > world.geothermalMinRadius and self.sx < world.mapSizeX - world.geothermalMinRadius and self.sz > world.geothermalMinRadius and self.sz < world.mapSizeZ - world.geothermalMinRadius then
          if not self.geothermal then
            world.geothermalMeteorCount = world.geothermalMeteorCount + 1
          end
          self.geothermal = true
          metalMinRadius = world.metalSpotSeparation
        end
      end
  end
  if not unequal and not blocked and impact.craterRadius > metalMinRadius then
    if world.metalSpotCount < world.metalTarget then
      local num = mCeil( (pi*(impact.craterRadius ^ 2)) / world.metalSpotTotalArea )
      num = mMin(num, world.metalSpotMaxPerCrater)
      self:SetMetalSpotCount(num, true)
    end
  end
  if world.showerRamps and impact.craterRadius > world.rampMinRadius then
    self:AddSomeRamps()
  end
  self.metalGeothermalRampSet = true
  if not noMirror and self.mirrorMeteor and type(self.mirrorMeteor) ~= boolean then
    self:CopyMetalGeothermalRamp(self.mirrorMeteor)
  end
end

function M.Meteor:CopyMetalGeothermalRamp(targetMeteor, mirrorIndex)
  if not targetMeteor.geothermal and self.geothermal then
    self.world.geothermalMeteorCount = self.world.geothermalMeteorCount + 1
  end
  targetMeteor.geothermal = self.geothermal
  targetMeteor:SetMetalSpotCount(self.metal, true)
  for r, ramp in pairs(self.ramps) do
    targetMeteor:AddRamp(AngleMirror(ramp.angle, mirrorIndex), ramp.width)
  end
  targetMeteor.metalGeothermalRampSet = true
end

function M.Meteor:AddSomeRamps(number)
  number = number or self.world.rampDefaultNumber
  local inc = twicePi / number
  local angle, width = self:AddRamp()
  for i = 1, number-1 do
    self:AddRamp(AngleAdd(angle, inc*i))
  end
end

function M.Meteor:AddRamp(angle, width)
  angle = angle or MinMaxRandom(0, twicePi)
  width = width or 800
  -- width in meters
  local ramp = { angle = angle, width = width }
  tInsert(self.ramps, ramp)
  self:Collide()
  return angle, width
end

function M.Meteor:ClearRamps()
  self.ramps = {}
  self:Collide()
end

function M.Meteor:Mirror(binding, mirrorIndex)
  local x, z = self.world:MirrorXZ(self.sx, self.sz, mirrorIndex)
  local nsx = VaryWithinBounds(x, 10, 0, self.world.mapSizeX)
  local nsz = VaryWithinBounds(z, 10, 0, self.world.mapSizeZ)
  local bind
  if binding then bind = self end
  -- world, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, seedSeed, ramps, mirrorMeteor)
  local mm = M.Meteor(self.world, nsx, nsz, VaryWithinBounds(self.diameterImpactor, 3, 1, 9999), VaryWithinBounds(self.velocityImpactKm, 5, 1, 120), VaryWithinBounds(self.angleImpact, 5, 1, 89), VaryWithinBounds(self.densityImpactor, 100, 1000, 10000), self.age, self.metal, self.geothermal, nil, nil, bind)
  self:CopyMetalGeothermalRamp(mm, mirrorIndex)
  mm.start = self.start
  if binding then self.mirrorMeteor = mm end
  return mm
end

----------------------------------------------------------

-- M.Impact does resolution-independent impact model calcuations, based on parameters from M.Meteor
-- impact model equations based on http://impact.ese.ic.ac.uk/ImpactEffects/effects.pdf
M.Impact = class(function(a, meteor)
  a.meteor = meteor
  a.world = meteor.world
  a.seedPacket = CreateSeedPacket(meteor.seedSeed, 100)
  a:Model()
end)

function M.Impact:PopSeed()
  return tRemove(self.seedPacket)
end

function M.Impact:Model()
  local world = self.world
  local meteor = self.meteor

  self.craterSeedSeed = self:PopSeed()
  self.noiseSeed = self:PopSeed()

  self.ageRatio = meteor.age / 100

  self.velocityImpact = meteor.velocityImpactKm * 1000
  self.angleImpactRadians = meteor.angleImpact * radiansPerDegree
  self.diameterTransient = 1.161 * ((meteor.densityImpactor / world.density) ^ 0.33) * (meteor.diameterImpactor ^ 0.78) * (self.velocityImpact ^ 0.44) * (world.gravity ^ -0.22) * (mSin(self.angleImpactRadians) ^ 0.33)
  self.diameterSimple = self.diameterTransient * 1.25
  self.depthTransient = self.diameterTransient / twoSqrtTwo
  self.depthTransientSq = self.depthTransient ^ 2
  self.rimHeightTransient = self.diameterTransient / 14.1
  self.rimHeightSimple = 0.07 * ((self.diameterTransient ^ 4) / (self.diameterSimple ^ 3))
  self.brecciaVolume = 0.032 * (self.diameterSimple ^ 3)
  self.brecciaDepth = 2.8 * self.brecciaVolume * ((self.depthTransient + self.rimHeightTransient) / (self.depthTransient * self.diameterSimple * self.diameterSimple))
  self.depthSimple = self.depthTransient - self.brecciaDepth

  self.rayWidth = 0.07 -- in radians

  self.craterRimHeight = self.rimHeightSimple / world.metersPerElmo

  self.complex = self.diameterTransient > world.complexDiameterCutoff
  if meteor.start then self.complex = false end
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
    end
    self.mass = (pi * (meteor.diameterImpactor ^ 3) / 6) * meteor.densityImpactor
    self.energyImpact = 0.5 * self.mass * (self.velocityImpact^2)
    self.meltVolume = 8.9 * 10^(-12) * self.energyImpact * mSin(self.angleImpactRadians)
    self.meltThickness = (4 * self.meltVolume) / (pi * (self.diameterTransient ^ 2))
    self.craterRadius = (self.diameterComplex / 2) / world.metersPerElmo
    self.craterMeltThickness = self.meltThickness / world.metersPerElmo
    self.meltSurface = self.craterRimHeight + self.craterMeltThickness - self.craterDepth
    -- debugEcho(self.energyImpact, self.meltVolume, self.meltThickness)
    self.craterPeakHeight = self.craterDepth * 0.67
    -- debugEcho( mFloor(self.diameterImpactor), mFloor(self.diameterComplex), mFloor(self.depthComplex), self.diameterComplex/self.depthComplex, mFloor(self.diameterTransient), mFloor(self.depthTransient) )
    self.peakRadius = self.craterRadius / 4
  else
    self.bowlPower = 1
    self.craterDepth = ((self.depthSimple + self.rimHeightSimple)  ) / world.metersPerElmo
    -- self.craterDepth = self.craterDepth * mMin(1-self.ageRatio, 0.5)
    self.craterRadius = (self.diameterSimple / 2) / world.metersPerElmo
    self.rayHeight = (self.craterRimHeight / 2)
    if meteor.age < world.rayAge then
      self.rayAgeRatio = 1 - (meteor.age / world.rayAge)
    end
  end

  self.craterFalloff = self.craterRadius * 1.5
  -- self.craterFalloff = ((self.diameterTransient ^ 2) / 200) / world.metersPerElmo
  -- local minEjectaHeight = self.craterRimHeighbt / 0.001
  -- self.craterFalloff = ((self.diameterTransient^4) / (112*minEjectaHeight)) ^ (1/3)

  if meteor.start then
    self.bowlPower = 2
    self.craterDepth = self.craterDepth * 0.5
  end

  self.metalSpots = {}
  if meteor.metal > 0 then
    if meteor.metal == 1 and not meteor.geothermal and not self.peakRadius then
      tInsert(self.metalSpots, { x = meteor.sx, z = meteor.sz, metal = world.metalSpotAmount })
    else
      local minRadius = 0
      if meteor.geothermal then minRadius = world.geothermalMinRadius/2 end
      if self.peakRadius then minRadius = self.peakRadius + (world.metalSpotMinRadius/2) end
      local circumfrence = meteor.metal * world.metalSpotSeparation
      local dist = mMax(minRadius, circumfrence / twicePi)
      self.metalRingRadius = dist
      local angleOffset = mRandom() * twicePi
      for i = 1, meteor.metal do
        local angle = AngleAdd(((i-1) / meteor.metal) * twicePi, angleOffset)
        local x, z = CirclePos(meteor.sx, meteor.sz, dist, angle)
        if x > world.metalSpotRadius and x < world.mapSizeX - world.metalSpotRadius and z > world.metalSpotRadius and z < world.mapSizeZ - world.metalSpotRadius then
          local spot = { x = x, z = z, metal = world.metalSpotAmount }
          tInsert(self.metalSpots, spot)
        end
      end
    end
  end

  self.noiseGenerated = false
end

-- as long as the seeds are consistent, this is only needed right before a crater
function M.Impact:GenerateNoise()
  if self.noiseGenerated then return end
  local world = self.world
  local meteor = self.meteor
  mRandomSeed(self.noiseSeed)
  if self.complex then
    if world.rimTerracing then
      local terraceNum = 2 -- i can't figure out how to make more than two work
      self.terraceSeeds = {}
      for i = 1, terraceNum do self.terraceSeeds[i] = NewSeed() end
    end
    self.distNoise = M.WrapNoise(mMax(mCeil(self.craterRadius / 20), 8), MinMaxRandom(0.075, 0.15), NewSeed(), 0.5, 3)
  else
    self.distNoise = M.WrapNoise(mMax(mCeil(self.craterRadius / 35), 8), MinMaxRandom(0.05, 0.15), NewSeed(), 0.35, 5)
    if meteor.age < world.rayAge then
      self.rayNoise = M.WrapNoise(24, MinMaxRandom(0.3, 0.4), NewSeed(), 0.5, 3)
    end
  end
  if self.complex and world.erosion then
    self.curveNoise = M.WrapNoise(mMax(mCeil(self.craterRadius / 25), 8), self.ageRatio * 0.5, NewSeed(), 0.3, 5)
  end
  self.heightNoise = M.WrapNoise(mMax(mCeil(self.craterRadius / 45), 8), MinMaxRandom(0.15, 0.35), NewSeed())
  if world.generateBlastNoise and meteor.age < world.blastRayAge then
    self.blastNoise = M.WrapNoise(mMin(mMax(mCeil(self.craterRadius), 32), 512), 0.5, NewSeed(), 1, 1)
  end
  self.noiseGenerated = true
end

----------------------------------------------------------

M.WrapNoise = class(function(a, length, intensity, seed, persistence, N, amplitude)
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

function M.WrapNoise:Smooth(n)
  local n1 = mFloor(n)
  local n2 = mCeil(n)
  if n1 == n2 then return self:Output(n1) end
  local val1, val2 = self:Output(n1), self:Output(n2)
  local d = val2 - val1
  return val1 + (mSmoothstep(n1, n2, n) * d)
end

function M.WrapNoise:Rational(ratio)
  return self:Smooth((ratio * (self.length - 1)) + 1)
end

function M.WrapNoise:Radial(angle)
  local n = ((angle + pi) / self.angleDivisor) + 1
  return self:Smooth(n)
end

function M.WrapNoise:Output(n)
  return self.outValues[self:Clamp(n)]
end

function M.WrapNoise:Dist(n1, n2)
  return mAbs((n1 + self.halfLength - n2) % self.length - self.halfLength)
end

function M.WrapNoise:Clamp(n)
  if n < 1 then
    n = n + self.length
  elseif n > self.length then
    n = n - self.length
  end
  return n
end

----------------------------------------------------------

M.LinearNoise = class(function(a, length, intensity, seed, persistence, N, amplitude)
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

function M.LinearNoise:Smooth(n)
  local n1 = mFloor(n)
  local n2 = mCeil(n)
  if n1 == n2 then return self:Output(n1) end
  local val1, val2 = self:Output(n1), self:Output(n2)
  local d = val2 - val1
  return val1 + (mSmoothstep(n1, n2, n) * d)
end

function M.LinearNoise:Rational(ratio)
  return self:Smooth((ratio * (self.length - 1)) + 1)
end

function M.LinearNoise:Output(n)
  return self.outValues[mCeil(n)] or 0
end

----------------------------------------------------------

M.TwoDimensionalNoise = class(function(a, seed, sideLength, intensity, persistence, N, amplitude, blackValue, whiteValue)
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

function M.TwoDimensionalNoise:Get(x, y)
  x, y = mFloor(x), mFloor(y)
  if not self.xy[x] then return 0 end
  if not self.xy[x][y] then return 0 end
  return self.xy[x][y]
end

----------------------------------------------------------

M.NoisePatch = class(function(a, x, y, radius, seed, intensity, persistence, N, amplitude, blackValue, whiteValue)
  a.x = x
  a.y = y
  a.radius = radius * ((wrapIntensity or 0) + 1)
  a.radiusSq = a.radius*a.radius
  a.xmin = x - a.radius
  a.xmax = x + a.radius
  a.ymin = y - a.radius
  a.ymax = y + a.radius
  -- debugEcho(radius, wrapIntensity or 0, a.radius, a.radiusSq)
  a.twoD = M.TwoDimensionalNoise(seed, a.radius * 2, intensity, persistence, N, amplitude, blackValue, whiteValue)
  a.intensity = intensity
end)

function M.NoisePatch:Get(x, y)
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

-- module export functions

function M.SetOutputDirectory(outDirNew)
  outDir = outDirNew
end

function M.SetCommandWord(word, comFunc)
  CommandWords[word] = comFunc
end

function M.GetAttributeRGB(attribute)
  local rgb = AttributeDict[attribute].rgb
  return rgb[1], rgb[2], rgb[3]
end

function M.GetAttributeRatioRGB(attribute)
  local rgb = AttributeDict[attribute].ratioRGB
  return rgb[1], rgb[2], rgb[3]
end

function M.EnableSpeedupStorage()
  doNotStore = false
end

function M.DisableSpeedupStorage()
  ClearSpeedupStorage()
  doNotStore = true
end

-- module callins

function M.UpdateMeteor(meteor) end

function M.UpdateWorld(myWorld) end

function M.FrameRenderer(renderer) end

function M.CompleteRenderer(renderer) end

function M.EndUiCommand(uiCommand) end

-- populate WorldSaveBlacklist

function M.AddToWorldSaveBlacklist(key)
  tInsert(WorldSaveBlackList, key)
  WSBL[key] = 1
  -- debugEcho(key, "added to WorldSaveBlacklist")
end

local wNoCalc = M.World(nil, nil, nil, nil, nil, nil, nil, nil, true, true)
wNoCalc.rimTerracing = true
local wCalc = M.World()
for k, v in pairs(wCalc) do
  if not wNoCalc[k] then
    M.AddToWorldSaveBlacklist(k)
  end
end
local mNoCalc = M.Meteor(wCalc, 1, 1)
mNoCalc.geothermal = true
local mNoCalc2 = {}
for k, v in pairs(mNoCalc) do
  mNoCalc2[k] = 1
end
local mCalc = M.Meteor(wCalc, 1, 1)
mCalc:Collide()
for k, v in pairs(mCalc) do
  if not mNoCalc2[k] then
    M.AddToWorldSaveBlacklist(k)
  end
end

-- export module

return M