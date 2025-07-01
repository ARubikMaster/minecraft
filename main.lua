cam = {}
heldKeys = {}
world = {}

local perlin = require "perlin" -- https://gist.github.com/kymckay/25758d37f8e3872e1636d90ad41fe2ed
render_dist = 7

function lovr.load()
  -- Camera setup
  cam.v = 1 -- View
  cam.x = 0
  cam.y = 70
  cam.z = 0
  cam.a = 0 -- angle
  cam.p = 0 -- pitch
  cam.ax = 0
  cam.ay = 1
  cam.az = 0

  chunkWidth = 16
  chunkHeight = 256

  -- Shaders
  defaultVertex = [[
    vec4 lovrmain()
    {
        return Projection * View * Transform * VertexPosition;
    }
  ]]

  defaultFragment = [[
    Constants {
      vec4 ambience;
      vec4 lightColor;
      vec3 lightPos;
      float specularStrength;
      int metallic;
    };

    vec4 lovrmain()
    {
        //diffuse
        vec3 norm = normalize(Normal);
        vec3 lightDir = normalize(lightPos - PositionWorld);
        float diff = max(dot(norm, lightDir), 0.0);
        vec4 diffuse = diff * lightColor;

        //specular
        vec3 viewDir = normalize(CameraPositionWorld - PositionWorld);
        vec3 reflectDir = reflect(-lightDir, norm);
        float spec = pow(max(dot(viewDir, reflectDir), 0.0), metallic);
        vec4 specular = specularStrength * spec * lightColor;

        vec4 baseColor = Color * getPixel(ColorTexture, UV);
        return baseColor * (ambience + diffuse + specular);
    }
  ]]

  shader = lovr.graphics.newShader(defaultVertex, defaultFragment, {}) 

  -- World Generation
  for x = -render_dist, render_dist do
    for y = -render_dist, render_dist do
      GenerateChunk(x*chunkWidth, 0, y*chunkWidth)
    end
  end

  sky = lovr.graphics.newTexture('sky.png')

end

chunkQueue = {}

function lovr.update(dt)
  HandleMovement(dt)

  -- Determine which chunks should be present
  local px, pz = cam.x, cam.z
  local pcx, pcz = math.floor(px/chunkWidth), math.floor(pz/chunkWidth)

  local shouldExist = {}
  for x = -render_dist, render_dist do
    for z = -render_dist, render_dist do
      local cx = (x+pcx)*chunkWidth
      local cz = (z+pcz)*chunkWidth
      shouldExist[cx .. ',' .. cz] = true
      if not IsChunkLoaded(cx, cz) and not IsChunkQueued(cx, cz) then
        table.insert(chunkQueue, {x = cx, z = cz})
      end
    end
  end

  -- Remove far-away chunks
  for i = #world, 1, -1 do
    local chunk = world[i]
    if not shouldExist[chunk.ox .. ',' .. chunk.oz] then
      table.remove(world, i)
    end
  end

  -- Generate 1 queued chunk per frame
  if #chunkQueue > 0 then
    local nextChunk = table.remove(chunkQueue, 1)
    GenerateChunk(nextChunk.x, 0, nextChunk.z)
  end
end

function IsChunkLoaded(x, z)
  for _, chunk in ipairs(world) do
    if chunk.ox == x and chunk.oz == z then return true end
  end
  return false
end

function IsChunkQueued(x, z)
  for _, chunk in ipairs(chunkQueue) do
    if chunk.x == x and chunk.z == z then return true end
  end
  return false
end


function lovr.draw(pass)
  pass:reset()

  -- Camera stuff
  local yawQuat = lovr.math.newQuat()
  yawQuat:setEuler(0, cam.a, 0)
  local pitchQuat = lovr.math.newQuat()
  pitchQuat:setEuler(cam.p, 0, 0)
  local quat = yawQuat:mul(pitchQuat)
  pass:setViewPose(cam.v, cam.x, cam.y, cam.z, quat)

  pass:skybox(sky)

  pass:setShader(shader)
  pass:send('lightColor', {1.0, 1.0, 1.0, 1.0})
  pass:send('lightPos', {100, 200, 100})
  pass:send('ambience', {0.1, 0.1, 0.1, 1.0})
  pass:send('specularStrength', 0.1)
  pass:send('metallic', 32.0)

  for _, chunk in ipairs(world) do
    pass:draw(chunk.mesh, 0, 0, 0)
  end

end

function HandleMovement(dt)
  -- Controls
  local speed = 10
  if heldKeys["lctrl"] then
    speed = 20
  end
  if heldKeys["w"] then
    cam.x = cam.x + (-math.sin(cam.a))*speed*dt
    cam.z = cam.z + (-math.cos(cam.a))*speed*dt
  end
  if heldKeys["s"] then
    cam.x = cam.x + (math.sin(cam.a))*speed*dt
    cam.z = cam.z + (math.cos(cam.a))*speed*dt
  end
  if heldKeys["a"] then
    cam.x = cam.x + (-math.sin(cam.a+math.pi/2))*speed*dt
    cam.z = cam.z + (-math.cos(cam.a+math.pi/2))*speed*dt
  end
  if heldKeys["d"] then
    cam.x = cam.x + (-math.sin(cam.a-math.pi/2))*speed*dt
    cam.z = cam.z + (-math.cos(cam.a-math.pi/2))*speed*dt
  end
  if heldKeys["space"] then
    cam.y = cam.y + speed*dt
  end
  if heldKeys["lshift"] then
    cam.y = cam.y - speed*dt
  end
  if heldKeys["j"] then
    cam.a = cam.a + 2*dt
  end
  if heldKeys["l"] then
    cam.a = cam.a - 2*dt
  end
  if heldKeys["i"] then
    cam.p = cam.p + 2*dt
  end
  if heldKeys["k"] then
    cam.p = cam.p - 2*dt
  end

  local maxPitch = math.pi/2 - 0.01
  if cam.p > maxPitch then cam.p = maxPitch end
  if cam.p < -maxPitch then cam.p = -maxPitch end
end

function GenerateChunk(world_x, world_y, world_z)
  local chunk = {
    blocks = {},
    ox = world_x,
    oy = world_y,
    oz = world_z
  }

  local treesToPlace = {}

  for x = 1, chunkWidth do
    chunk.blocks[x] = {}
    for z = 1, chunkWidth do
      chunk.blocks[x][z] = {}
      local noise = perlin:noise((x+world_x)*0.05, 0, (z+world_z)*0.05)
      local shaped = math.pow((noise + 1) / 2, 4) -- normalize to [0, 1] then raise to ^4
      local height = math.floor(shaped * 40 + 30) -- shape + scale + base height

      for y = 1, chunkHeight do
        if y == height then
          chunk.blocks[x][z][y] = "grass"
          if math.random() < 0.01 then
            table.insert(treesToPlace, {x = x, y = y+1, z = z})
          end
        elseif y <= height/2+10 then
          chunk.blocks[x][z][y] = "deepslate"  
        elseif y+8 <= height then
          chunk.blocks[x][z][y] = "stone"  
        elseif y < height then
          chunk.blocks[x][z][y] = "dirt"
        else
          chunk.blocks[x][z][y] = nil
        end
      end
    end
  end

  for _, v in ipairs(treesToPlace) do
    chunk.blocks[v.x][v.z][v.y] = "log"
    chunk.blocks[v.x][v.z][v.y+1] = "log"
    chunk.blocks[v.x][v.z][v.y+2] = "log"
    chunk.blocks[v.x][v.z][v.y+3] = "log"
    chunk.blocks[v.x][v.z][v.y+4] = "log"
  end

  chunk.mesh = GenerateMesh(chunk)

  table.insert(world, chunk)
end

function GenerateMesh(chunk)
  local worldX = chunk.ox
  local worldY = chunk.oy
  local worldZ = chunk.oz
  local blocks = chunk.blocks

  local vertices = {}

  for x = 1, #blocks do
    for z = 1, #blocks[x] do
      for y = 1, #blocks[x][z] do

          local color = {}

          if blocks[x][z][y] == "grass" then
            color.r = 0.3
            color.g = 1.0
            color.b = 0.4
          elseif blocks[x][z][y] == "dirt" then
            color.r = 0.36
            color.g = 0.25
            color.b = 0.20
          elseif blocks[x][z][y] == "stone" then
            color.r = 0.5
            color.g = 0.5
            color.b = 0.5  
          elseif blocks[x][z][y] == "deepslate" then
            color.r = 0.2
            color.g = 0.2
            color.b = 0.2
          elseif blocks[x][z][y] == "log" then
            color.r = 0.2
            color.g = 0.15
            color.b = 0.1
          elseif blocks[x][z][y] == nil then
            goto continue
          end

          locations = {}

          if blocks[x][z][y+1] == nil then -- top
            local toPlace =  {{x - 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, 0, 1, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, 0, 1, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 0, 1, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 0, 1, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, 0, 1, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 0, 1, 0, color.r, color.g, color.b, 1}}
            
            for _, v in ipairs(toPlace) do
              table.insert(locations, v)
            end
          end

          if blocks[x][z][y-1] == nil then -- bottom
            local toPlace =  {{x - 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 0, -1, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 0, -1, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, 0, -1, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, 0, -1, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 0, -1, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, 0, -1, 0, color.r, color.g, color.b, 1}}
            
            for _, v in ipairs(toPlace) do
              table.insert(locations, v)
            end
          end

          local blockXP1 = blocks[x][z+1] and blocks[x][z+1] and blocks[x][z+1][y]
          if blockXP1 == nil then -- front
            local toPlace =  {{x - 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 0, 0, 1, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, 0, 0, 1, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 0, 0, 1, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 0, 0, 1, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, 0, 0, 1, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, 0, 0, 1, color.r, color.g, color.b, 1}}
            
            for _, v in ipairs(toPlace) do
              table.insert(locations, v)
            end
          end

          local blockXP1 = blocks[x][z-1] and blocks[x][z-1] and blocks[x][z-1][y]
          if blockXP1 == nil then -- back
            local toPlace =  {{x - 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, 0, 0, -1, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 0, 0, -1, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, 0, 0, -1, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, 0, 0, -1, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 0, 0, -1, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 0, 0, -1, color.r, color.g, color.b, 1}}
            
            for _, v in ipairs(toPlace) do
              table.insert(locations, v)
            end
          end

          local blockXP1 = blocks[x-1] and blocks[x-1][z] and blocks[x-1][z][y]
          if blockXP1 == nil then -- left
            local toPlace =  {{x - 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, -1, 0, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, -1, 0, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, -1, 0, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, -1, 0, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, -1, 0, 0, color.r, color.g, color.b, 1},
                              {x - 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, -1, 0, 0, color.r, color.g, color.b, 1}}
            
            for _, v in ipairs(toPlace) do
              table.insert(locations, v)
            end
          end

          local blockXP1 = blocks[x+1] and blocks[x+1][z] and blocks[x+1][z][y]
          if blockXP1 == nil then -- right
            local toPlace =  {{x + 0.5 + worldX, y + 0.5 + worldY, z - 0.5 + worldZ, 1, 0, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 1, 0, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 1, 0, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y + 0.5 + worldY, z + 0.5 + worldZ, 1, 0, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z - 0.5 + worldZ, 1, 0, 0, color.r, color.g, color.b, 1},
                              {x + 0.5 + worldX, y - 0.5 + worldY, z + 0.5 + worldZ, 1, 0, 0, color.r, color.g, color.b, 1}}
            
            for _, v in ipairs(toPlace) do
              table.insert(locations, v)
            end
          end

          for _, v in ipairs(locations) do
            table.insert(vertices, v)
          end

          ::continue::
      end
    end
  end

  chunkMesh = lovr.graphics.newMesh({
    { 'VertexPosition', 'vec3' },
    { 'VertexNormal', 'vec3'},
    { 'VertexColor', 'vec4' }
  }, vertices)

  return chunkMesh
end

function lovr.keypressed(key, scancode, isrepeat)
  heldKeys[key] = true
end

function lovr.keyreleased(key, scancode)
  heldKeys[key] = false
end