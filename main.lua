cam = {}
heldKeys = {}
world = {}

local perlin = require "perlin" -- https://gist.github.com/kymckay/25758d37f8e3872e1636d90ad41fe2ed
render_dist = 9

function lovr.load()
  -- Camera setup
  cam.v = 1 -- View
  cam.x = 0 -- X position
  cam.y = 70 -- Y position
  cam.z = 0 -- Z position
  cam.a = 0 -- angle
  cam.p = 0 -- pitch
  cam.ax = 0
  cam.ay = 1 -- Rotation around  y axis
  cam.az = 0

  -- Chunk size (16x16x256)
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

  -- Draws each chunks mesh
  for _, chunk in ipairs(world) do
    pass:draw(chunk.mesh, 0, 0, 0)
  end

  pass:setShader()
  for _, chunk in ipairs(world) do
    if chunk.watermesh ~= nil then
      pass:draw(chunk.watermesh, 0, 0, 0)
    end
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

function hash(x, y, z) -- For tree placement generation
  return (math.sin(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453) % 1
end

function GenerateChunk(world_x, world_y, world_z)
  local chunk = {
    blocks = {},
    ox = world_x,
    oy = world_y,
    oz = world_z,
  }

  local treesToPlace = {}

  for x = 1, chunkWidth do
    chunk.blocks[x] = {}
    for z = 1, chunkWidth do
      chunk.blocks[x][z] = {}

      -- Intersting terrain by having higher points be elevated and lower points being placed further down
      local noise = perlin:noise((x+world_x)*0.05, 0, (z+world_z)*0.05)
      local shaped = math.pow((noise + 1) / 2, 5)
      local height = math.floor(shaped * 40 + 30)

      for y = 1, chunkHeight do
        if y == height and y < 32 then
          chunk.blocks[x][z][y] = "sand" 
        elseif y == height then
          chunk.blocks[x][z][y] = "grass" -- Places grass if the height matches the terrain height
          if hash(x + world_x, y, z + world_z) < 0.005 then -- Decides wether to place a tree at the location
            if x >= 2 and x <= chunkWidth - 2 and z >= 2 and z <= chunkWidth - 2 then
              table.insert(treesToPlace, {x = x, y = y+1, z = z}) -- Adds location to treesToPlace
            end
          end
        elseif y <= height/2+10 then -- Smooth out the shape to not match perfectly the shape of the terrain at top
          chunk.blocks[x][z][y] = "deepslate"  -- Useless for now (not enough terrain height)
        elseif y+8 <= height then
          chunk.blocks[x][z][y] = "stone" -- Stone is placed 8 blocks deep  
        elseif y < height then
          chunk.blocks[x][z][y] = "dirt" -- Places dirt if it is under grass but not stone or deepslate
        elseif y == 31 then
          chunk.blocks[x][z][y] = "water"  
        else
          chunk.blocks[x][z][y] = nil -- Nil for air blocks
        end
      end
    end
  end

  ---[[
  for _, v in ipairs(treesToPlace) do
    for i = 0, 5 do
      chunk.blocks[v.x][v.z][v.y+i] = "log" -- Places logs
    end

    -- Creates a 3x3x4 block of leaves
    for x = -1, 1 do
      for z = -1, 1 do 
        for y = 3, 6 do
          if chunk.blocks[v.x+x] then
            if chunk.blocks[v.x+x][v.z+z] then
              if not chunk.blocks[v.x+x][v.z+z][v.y+y] then -- Only places leaf if the current block at location is air
                chunk.blocks[v.x+x][v.z+z][v.y+y] = "leaf"
              end
            end
          end
        end
      end
    end

  end
  --]]

  chunk.mesh, chunk.watermesh = GenerateMesh(chunk)

  table.insert(world, chunk)
end

-- Generates a mesh for each chunk with only visible faces to improve performance
function GenerateMesh(chunk)
  local worldX = chunk.ox
  local worldY = chunk.oy
  local worldZ = chunk.oz
  local blocks = chunk.blocks

  -- The vertices that will be added into the mesh
  vertices = {}
  waterVertices = {}

  for x = 1, #blocks do
    for z = 1, #blocks[x] do
      if blocks[x][z] then
        for y in pairs(blocks[x][z]) do -- ty kelly!

            if blocks[x][z][y] == nil then
              goto continue
            end

            local blockType = blocks[x][z][y]
            local isWater = blockType == "water"

            local color = {}

            -- Set color depending on block type
            if blockType == "grass" then
              color = { r = 0.3, g = 1.0, b = 0.4 }
            elseif blockType == "dirt" then
              color = { r = 0.36, g = 0.25, b = 0.20 }
            elseif blockType == "stone" then
              color = { r = 0.5, g = 0.5, b = 0.5 }
            elseif blockType == "deepslate" then
              color = { r = 0.2, g = 0.2, b = 0.2 }
            elseif blockType == "log" then
              color = { r = 0.2, g = 0.15, b = 0.1 }
            elseif blockType == "leaf" then
              color = { r = 0.1, g = 1.0, b = 0.2 }
            elseif blockType == "sand" then
              color = { r = 0.96, g = 0.84, b = 0.70 }
            elseif blockType == "water" then
              goto water
            else
              goto continue
            end

            locations = {}

            function isTransparent(blockType)
              return blockType == nil or blockType == "water"
            end

            -- Adds each face depending on if it is visible
            if isTransparent(blocks[x][z][y+1]) then -- top
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

            if isTransparent(blocks[x][z][y-1]) then -- bottom
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

            blockXP1 = blocks[x] and blocks[x][z+1] and blocks[x][z+1][y]
            if isTransparent(blockXP1) then -- front
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

            blockXP1 = blocks[x] and blocks[x][z-1] and blocks[x][z-1][y]
            if isTransparent(blockXP1) then -- back
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

            blockXP1 = blocks[x-1] and blocks[x-1][z] and blocks[x-1][z][y]
            if isTransparent(blockXP1) then -- left
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

            blockXP1 = blocks[x+1] and blocks[x+1][z] and blocks[x+1][z][y]
            if isTransparent(blockXP1) then -- right
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

            goto continue

            ::water::

            locations = {}

            local toPlace = {
              {x - 0.5 + worldX, y + 0.3 + worldY, z - 0.5 + worldZ, 0, 1, 0, 0.0, 0.4, 0.8, 0.4},
              {x - 0.5 + worldX, y + 0.3 + worldY, z + 0.5 + worldZ, 0, 1, 0, 0.0, 0.4, 0.8, 0.4},
              {x + 0.5 + worldX, y + 0.3 + worldY, z + 0.5 + worldZ, 0, 1, 0, 0.0, 0.4, 0.8, 0.4},

              {x + 0.5 + worldX, y + 0.3 + worldY, z + 0.5 + worldZ, 0, 1, 0, 0.0, 0.4, 0.8, 0.4},
              {x + 0.5 + worldX, y + 0.3 + worldY, z - 0.5 + worldZ, 0, 1, 0, 0.0, 0.4, 0.8, 0.4},
              {x - 0.5 + worldX, y + 0.3 + worldY, z - 0.5 + worldZ, 0, 1, 0, 0.0, 0.4, 0.8, 0.4}
            }

              
            for _, v in ipairs(toPlace) do
              table.insert(locations, v)
            end

            for _, v in ipairs(locations) do
              table.insert(waterVertices, v)
            end

            ::continue::
          end
      end
    end
  end

  chunkMesh = lovr.graphics.newMesh({
    { 'VertexPosition', 'vec3' },
    { 'VertexNormal', 'vec3'},
    { 'VertexColor', 'vec4' }
  }, vertices)

  if #waterVertices ~= 0 then
    waterMesh = lovr.graphics.newMesh({
      { 'VertexPosition', 'vec3' },
      { 'VertexNormal', 'vec3'},
      { 'VertexColor', 'vec4' }
    }, waterVertices)
  else
    waterMesh = nil
  end

  return chunkMesh, waterMesh
end

function lovr.keypressed(key, scancode, isrepeat)
  heldKeys[key] = true
end

function lovr.keyreleased(key, scancode)
  heldKeys[key] = false
end