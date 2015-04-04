local mRandom = math.random
if love then mRandom = love.math.random end
local mRandomSeed = math.randomseed
if love then mRandomSeed = love.math.setRandomSeed end

local rand = { mySeed = 1, lastN = -1 }

local function rand:get(seed, n)
  if n <= 0 then n = -2 * n
  else n = 2 * n - 1
  end

  if seed ~= self.mySeed or self.lastN < 0 or n <= self.lastN then
    self.mySeed = seed
    mRandomSeed(seed)
    self.lastN = -1
  end
  while self.lastN < n do
    num = mRandom()
    self.lastN = self.lastN + 1
  end
  return num - 0.5
end

local function rand:num()
  rand.lastN = -1
  return mRandom() - 0.5
end

-- takes table of L values and returns N*(L-3) interpolated values
local function interpolate1D(values, N)
  local newData = {}
  for i = 1, #values - 3 do
    local P = (values[i+3] - values[i+2]) - (values[i] - values[i+1])
    local Q = (values[i] - values[i+1]) - P
    local R = (values[i+2] - values[i])
    local S = values[i+1]
    for j = 0, N-1 do
      local x = j/N
      table.insert(newData, P*x^3 + Q*x^2 + R*x + S)
    end
  end
  return newData
end

local function perlinComponent1D(seed, length, N, amplitude)
  local rawData = {}
  local finalData = {}
  for i = 1, math.ceil(length/N) + 3 do
    local rawData[i] = amplitude * rand:get(seed, i)
  end
  local interpData = interpolate1D(rawData, N)
  assert(#interpData >= length)
  for i = 1, length do
    finalData[i] = interpData[i]
  end
  return finalData
end

local function OneD(seed, length, persistence, N, amplitude)
  local min, max = 0, 0
  local data = {}
  for i = 1, length do
    data[i] = 0
  end
  for i = N, 1, -1 do
    local compInterp = 2^(i-1)
    local compAmplitude = amplitude * persistence^(N-i)
    local comp = perlinComponent1D(seed+i, length, i, compAmplitude)
    for i = 1, length do
      data[i] = data[i] + comp[i]
      if data[i] > max then max = data[i] end
      if data[i] < min then min = data[i]  end
    end
  end
  return data, min, max
end

local function interpolate2D(values, N)
  local newData1 = {}
  for r = 1, #values do
    newData1[r] = {}
    for c = 1, #values[r] - 3 do
      local P = (values[r][c+3] - values[r][c+2]) - (values[r][c] - values[r][c+1])
      local Q = (values[r][c] - values[r][c+1]) - P
      local R = (values[r][c+2] - values[r][c])
      local S = values[r][c+1]
      for j = 0, N-1 do
        local x = j/N
        table.insert(newData1[r], P*x^3 + Q*x^2 + R*x + S)
      end
    end
  end
  
  local newData2 = {}
  for r = 1, (#newData1-3) * N do
    newData2[r] = {}
  end
  for c = 1, #newData1[1] do
    for r = 1, #newData1 - 3 do
      local P = (newData1[r+3][c] - newData1[r+2][c]) - (newData1[r][c] - newData1[r+1][c])
      local Q = (newData1[r][c] - newData1[r+1][c]) - P
      local R = (newData1[r+2][c] - newData1[r][c])
      local S = newData1[r+1][c]
      for j = 0, N-1 do
        local x = j/N
        newData2[(r-1)*N+j+1][c] = P*x^3 + Q*x^2 + R*x + S
      end
    end
  end
  
  return newData2
end

local function perlinComponent2D(seed, width, height, N, amplitude)
  local rawData = {}
  local finalData = {}
  for r = 1, math.ceil(height/N) + 3 do
    rawData[r] = {}
    for c = 1, math.ceil(width/N) + 3 do
      rawData[r][c] = amplitude * rand:get(seed+r, c)
    end
  end
  local interpData = interpolate2D(rawData, N)
  assert(#interpData >= height and #interpData[1] >= width)
  for r = 1, height do
    finalData[r] = {}
    for c = 1, width do
      finalData[r][c] = interpData[r][c]
    end
  end
  return finalData
end

local function TwoD(seed, width, height, persistence, N, amplitude)
  local data = {}
  for r = 1, height do
    data[r] = {}
    for c = 1, width do
      data[r][c] = 0
    end
  end
  local min, max = 0, 0
  for i = 1, N do
    local compInterp = 2^(N-i)
    local compAmplitude = amplitude * (persistence^(i-1))
    local comp = perlinComponent2D(seed+i*1000, width, height, compInterp, compAmplitude)
    for r = 1, height do
      for c = 1, width do
        data[r][c] = data[r][c] + comp[r][c]
        if data[r][c] < min then min = data[r][c] end
        if data[r][c] > max then max = data[r][c] end
      end
    end
  end
  return data, min, max
end

local Perlin = {
  OneD = OneD,
  TwoD = TwoD,
}

return Perlin