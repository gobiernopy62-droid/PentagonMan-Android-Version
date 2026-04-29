-- =============================================================================
--  player.lua  PentagonMan (Love2D port)
--  Física, animaciones, salud, coyote time, agua, invencibilidad
-- =============================================================================

local Controls = require("controls")

local Player = {}
Player.__index = Player

-- Dimensiones en píxeles lógicos
local SPRITE_W = 125
local SPRITE_H = 125
local HITBOX_W = 45
local HITBOX_H = 100

-- =============================================================================
--  Constructor
-- =============================================================================

function Player.new(spawnX, spawnY, passets)
    local self = setmetatable({}, Player)

    self.assets = passets

    -- Hitbox (topleft)
    -- FIX: fórmula idéntica a Python:
    --   hitbox.centerx = pos[0] + 30  →  x = spawnX + 30 - HITBOX_W//2
    --   hitbox.bottom  = pos[1] + 125 →  y = spawnY + 125 - HITBOX_H
    self.x  = spawnX + 30 - math.floor(HITBOX_W / 2)
    self.y  = spawnY + 125 - HITBOX_H
    self.hw = HITBOX_W
    self.hh = HITBOX_H

    -- Velocidades
    self.velX = 0
    self.velY = 0

    -- Parámetros de física base
    self.speed         = 3.5
    self.gravity       = 0.5
    self.jumpStrength  = -12
    self.maxFallSpeed  = 12
    self.onGround      = false

    -- Coyote time (permite saltar brevemente tras caer de un borde)
    self.coyoteTime  = 0.1
    self.coyoteTimer = 0

    -- Cooldown de salto (evita doble salto por mantener la tecla pulsada)
    self.jumpCooldown = 0.5
    self.jumpTimer    = 0

    -- Gracia de animación al estar en suelo (evita animación "Jump" al caer por bordes)
    self.groundedAnimGrace = 0.2
    self.groundedAnimTimer = 0

    -- Toggle walk ↔ idle mientras se camina en suelo
    self.walkIdleTimer    = 0
    self.walkIdleInterval = 0.5
    self.isWalkingPhase   = true

    -- Física de agua
    self.inWater            = false
    self.inWaterfall        = false
    self.waterGravity       = 0.15
    self.waterJumpStrength  = -6
    self.waterMaxFallSpeed  = 4
    self.waterSpeedMult     = 0.7

    -- Salud
    self.maxHealth    = 100
    self.health       = 100
    self.damagePerHit = 20

    -- Invencibilidad temporal tras recibir daño
    self.invincible         = false
    self.invincibleTimer    = 0
    self.invincibleDuration = 1.0

    -- Estado de animación
    self.action    = "Idle"
    self.direction = "Right"

    -- Animación de muerte (spritesheet)
    self.isDying        = false
    self.deathFrameIdx  = 1
    self.deathAnimTimer = 0
    self.deathAnimSpeed = 0.15
    self.deathFinished  = false
    self.deathQuads     = self:_buildDeathQuads()

    -- Victoria
    self.isVictorious = false

    return self
end

-- =============================================================================
--  Construcción de quads para la animación de muerte
-- =============================================================================

function Player:_buildDeathQuads()
    local quads = {}
    local sheet = self.assets.images.playerDeathSheet
    local data  = self.assets.data.playerDeathFrames
    if not sheet or not data then return quads end

    local sw, sh = sheet:getDimensions()
    -- Formato: data.frames es un array de { frame = {x,y,w,h} }
    for _, frameData in ipairs(data.frames or {}) do
        local f = frameData.frame
        quads[#quads + 1] = love.graphics.newQuad(f.x, f.y, f.w, f.h, sw, sh)
    end
    return quads
end

-- =============================================================================
--  Muerte y victoria
-- =============================================================================

function Player:startDeath()
    self.isDying        = true
    self.deathFrameIdx  = 1
    self.deathAnimTimer = 0
    self.deathFinished  = false
    self.velX           = 0
    self.velY           = 0
end

function Player:updateDeathAnimation(dt)
    if #self.deathQuads == 0 then
        self.deathFinished = true
        return
    end
    self.deathAnimTimer = self.deathAnimTimer + dt
    if self.deathAnimTimer >= self.deathAnimSpeed then
        self.deathAnimTimer = 0
        self.deathFrameIdx  = self.deathFrameIdx + 1
        if self.deathFrameIdx > #self.deathQuads then
            self.deathFrameIdx = #self.deathQuads
            self.deathFinished = true
        end
    end
end

function Player:startVictory()
    self.isVictorious = true
    self.velX         = 0
    self.velY         = 0
end

-- =============================================================================
--  Detección de agua
-- =============================================================================

function Player:checkWater(waterBlocks)
    self.inWater     = false
    self.inWaterfall = false
    for _, w in ipairs(waterBlocks) do
        if self:overlaps(w.x, w.y, w.w, w.h) then
            self.inWater = true
            if w.imageIndex == 5 then   -- Waterfall
                self.inWaterfall = true
            end
            break
        end
    end
end

-- =============================================================================
--  Update principal
-- =============================================================================

function Player:update(dt, platforms, enemies, waterBlocks)
    -- En estados especiales no se aplica física normal
    if self.isDying then
        self:updateDeathAnimation(dt)
        return
    end
    if self.isVictorious then return end

    -- Detectar agua
    self:checkWater(waterBlocks)

    -- Perfil de física según contexto
    local curGravity, curMaxFall, curSpeed
    if self.inWater and not self.inWaterfall then
        curGravity  = self.waterGravity
        curMaxFall  = self.waterMaxFallSpeed
        curSpeed    = self.speed * self.waterSpeedMult
    else
        curGravity  = self.gravity
        curMaxFall  = self.maxFallSpeed
        curSpeed    = self.speed
    end

    -- Input horizontal (usa Controls para que los overrides móviles tengan efecto)
    local moveX = 0
    if Controls.isActionPressed("move_left")  then
        moveX = moveX - 1
        self.direction = "Left"
    end
    if Controls.isActionPressed("move_right") then
        moveX = moveX + 1
        self.direction = "Right"
    end

    -- Movimiento horizontal
    self.velX = moveX * curSpeed * dt * 60
    self.x    = self.x + self.velX
    self:_resolveCollisions(platforms, "horizontal")

    -- Gravedad
    local prevOnGround = self.onGround
    self.onGround = false

    self.velY = self.velY + curGravity * dt * 60
    if self.velY > curMaxFall then self.velY = curMaxFall end

    self.y = self.y + self.velY * dt * 60
    self:_resolveCollisions(platforms, "vertical")

    -- Coyote time
    if self.onGround then
        self.coyoteTimer       = self.coyoteTime
        self.groundedAnimTimer = self.groundedAnimGrace
    else
        self.coyoteTimer       = math.max(0, self.coyoteTimer - dt)
        self.groundedAnimTimer = math.max(0, self.groundedAnimTimer - dt)
    end

    -- Salto
    self.jumpTimer = math.max(0, self.jumpTimer - dt)
    local wantJump = Controls.isActionPressed("jump")
    local canJump  = (self.coyoteTimer > 0 or self.inWater) and self.jumpTimer <= 0
    if wantJump and canJump then
        self.velY              = self.inWater and self.waterJumpStrength or self.jumpStrength
        self.onGround          = false
        self.coyoteTimer       = 0
        self.groundedAnimTimer = 0
        self.jumpTimer         = self.jumpCooldown
    end

    -- Toggle walk / idle al caminar en suelo
    local isGrounded = self.onGround or self.groundedAnimTimer > 0
    if self.velX ~= 0 and isGrounded then
        self.walkIdleTimer = self.walkIdleTimer + dt
        if self.walkIdleTimer >= self.walkIdleInterval then
            self.walkIdleTimer  = 0
            self.isWalkingPhase = not self.isWalkingPhase
        end
    else
        self.walkIdleTimer  = 0
        self.isWalkingPhase = true
    end

    -- Acción de animación
    if not isGrounded then
        self.action = "Jump"
    elseif self.velX ~= 0 then
        self.action = self.isWalkingPhase and "Walk" or "Idle"
    else
        self.action = "Idle"
    end

    -- Timer de invencibilidad
    if self.invincible then
        self.invincibleTimer = self.invincibleTimer - dt
        if self.invincibleTimer <= 0 then
            self.invincible = false
        end
    end

    -- Colisión con enemigos normales
    for _, enemy in ipairs(enemies) do
        if enemy.alive and self:overlaps(enemy.x, enemy.y, enemy.hw, enemy.hh) then
            -- Pisada (jugador cayendo con pies por encima del centro del enemigo)
            if self.velY > 0 and (self.y + self.hh) <= (enemy.y + enemy.hh / 2) then
                enemy:takeHit()
                self.velY = -8
            elseif not self.invincible then
                self:takeDamage(self.damagePerHit)
            end
        end
    end
end

-- =============================================================================
--  Colisiones AABB
-- =============================================================================

function Player:overlaps(rx, ry, rw, rh)
    return self.x < rx + rw and self.x + self.hw > rx
       and self.y < ry + rh and self.y + self.hh > ry
end

function Player:_resolveCollisions(platforms, axis)
    for _, p in ipairs(platforms) do
        if self:overlaps(p.x, p.y, p.w, p.h) then
            if axis == "horizontal" then
                if self.velX > 0 then
                    self.x = p.x - self.hw
                elseif self.velX < 0 then
                    self.x = p.x + p.w
                end
                self.velX = 0
            else  -- vertical
                if self.velY > 0 then
                    self.y        = p.y - self.hh
                    self.velY     = 0
                    self.onGround = true
                elseif self.velY < 0 then
                    self.y    = p.y + p.h
                    self.velY = 0
                end
            end
        end
    end
end

-- =============================================================================
--  Daño y reset
-- =============================================================================

function Player:takeDamage(amount)
    self.health = math.max(0, self.health - amount)
    if self.health > 0 then
        self.invincible      = true
        self.invincibleTimer = self.invincibleDuration
    end
end

function Player:reset(spawnX, spawnY)
    -- FIX: misma fórmula que el constructor
    self.x                 = spawnX + 30 - math.floor(self.hw / 2)
    self.y                 = spawnY + 125 - self.hh
    self.velX              = 0
    self.velY              = 0
    self.health            = self.maxHealth
    self.invincible        = false
    self.invincibleTimer   = 0
    self.onGround          = false
    self.groundedAnimTimer = 0
    self.coyoteTimer       = 0
    self.jumpTimer         = 0
    self.isDying           = false
    self.isVictorious      = false
    self.deathFrameIdx     = 1
    self.deathFinished     = false
    self.action            = "Idle"
    self.direction         = "Right"
    self.inWater           = false
    self.inWaterfall       = false
    self.walkIdleTimer     = 0
    self.isWalkingPhase    = true
end

-- =============================================================================
--  Draw
-- =============================================================================

function Player:draw(camX, camY)
    -- El sprite se centra sobre el hitbox
    local offX  = (SPRITE_W - self.hw) / 2
    local offY  = (SPRITE_H - self.hh) / 2
    local drawX = (self.x - camX) - offX
    local drawY = (self.y - camY) - offY

    -- Parpadeo de invencibilidad
    if self.invincible and math.floor(self.invincibleTimer * 10) % 2 == 0 then
        love.graphics.setColor(1, 1, 1, 0.35)
    else
        love.graphics.setColor(1, 1, 1, 1)
    end

    -- Seleccionar imagen según estado
    if self.isDying and #self.deathQuads > 0 then
        local sheet = self.assets.images.playerDeathSheet
        local q     = self.deathQuads[self.deathFrameIdx]
        local _, _, qw, qh = q:getViewport()
        love.graphics.draw(sheet, q, drawX, drawY, 0,
            SPRITE_W / qw, SPRITE_H / qh)

    elseif self.isVictorious then
        local img = self.assets.images.player.Victory
        love.graphics.draw(img, drawX, drawY, 0,
            SPRITE_W / img:getWidth(), SPRITE_H / img:getHeight())

    else
        local key = self.action .. "_" .. self.direction
        local img = self.assets.images.player[key]
                 or self.assets.images.player["Idle_Right"]
        love.graphics.draw(img, drawX, drawY, 0,
            SPRITE_W / img:getWidth(), SPRITE_H / img:getHeight())
    end

    love.graphics.setColor(1, 1, 1, 1)
end

-- =============================================================================
--  UI  barra de salud e ícono de cabeza
-- =============================================================================

function Player:drawUI(canvasW, canvasH)
    local pad    = 10
    local barW   = 200
    local barH   = 24
    local iconSz = 64

    local barX = pad + iconSz + pad
    local barY = canvasH - barH - pad

    -- Fondo de la barra
    love.graphics.setColor(0.20, 0.20, 0.20, 1)
    love.graphics.rectangle("fill", barX, barY, barW, barH, 4, 4)

    -- Relleno de salud
    local ratio = math.max(0, math.min(1, self.health / self.maxHealth))
    love.graphics.setColor(0.19, 0.80, 0.19, 1)
    love.graphics.rectangle("fill", barX, barY, barW * ratio, barH, 4, 4)

    -- Ícono de cabeza según estado de salud
    local headImg
    if self.health > self.maxHealth / 2 then
        headImg = self.assets.images.player.head_normal
    elseif self.health > 0 then
        headImg = self.assets.images.player.head_injured
    else
        headImg = self.assets.images.player.head_dead
    end

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(headImg, pad, canvasH - iconSz - pad, 0,
        iconSz / headImg:getWidth(), iconSz / headImg:getHeight())
end

return Player
