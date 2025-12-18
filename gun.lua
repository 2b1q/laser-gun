-- IO index, not Dx/GPIO!
-- D1..D2, D5..D7, D0
local PIN_TRIGGER   = 1   -- D1 (GPIO5)
local PIN_RELOAD    = 2   -- D2 (GPIO4)
local PIN_LASER     = 5   -- D5 (GPIO14)
local PIN_LED_GREEN = 6   -- D6 (GPIO12)
local PIN_LED_RED   = 7   -- D7 (GPIO13)
local PIN_BUZZER    = 0   -- D0 (GPIO16)

-- CD4026 control pins
-- CLK increments on rising edge, RESET is active HIGH
local PIN_4026_CLK   = 3  -- D3 (GPIO0)
local PIN_4026_RESET = 4  -- D4 (GPIO2)

local MAX_BULLETS = 7
local bullets = MAX_BULLETS
local reloading = false

local lastTrigger = 1
local lastReload  = 1

print("\n\n=== Laser gun (gun.lua) started ===")

gpio.mode(PIN_TRIGGER, gpio.INPUT, gpio.PULLUP)
gpio.mode(PIN_RELOAD,  gpio.INPUT, gpio.PULLUP)

gpio.mode(PIN_LASER,     gpio.OUTPUT)
gpio.mode(PIN_LED_GREEN, gpio.OUTPUT)
gpio.mode(PIN_LED_RED,   gpio.OUTPUT)
gpio.mode(PIN_BUZZER,    gpio.OUTPUT)

gpio.mode(PIN_4026_CLK,   gpio.OUTPUT)
gpio.mode(PIN_4026_RESET, gpio.OUTPUT)

gpio.write(PIN_LASER, gpio.LOW)
gpio.write(PIN_LED_GREEN, gpio.HIGH)
gpio.write(PIN_LED_RED,   gpio.LOW)
gpio.write(PIN_BUZZER,    gpio.LOW)

gpio.write(PIN_4026_CLK, gpio.LOW)
gpio.write(PIN_4026_RESET, gpio.LOW)

-- =========================
-- 7-seg via CD4026 helpers
-- =========================

local displayTimer = tmr.create()
local displayBusy = false
local displayPending = nil

local function display_apply(value)
  if value < 0 then value = 0 end
  if value > 9 then value = 9 end

  if displayBusy then
    displayPending = value
    return
  end

  displayBusy = true
  displayPending = nil

  local pulsesLeft = value
  local phase = 0

  gpio.write(PIN_4026_CLK, gpio.LOW)
  gpio.write(PIN_4026_RESET, gpio.HIGH) -- reset pulse

  displayTimer:alarm(1, tmr.ALARM_AUTO, function(t)
    if phase == 0 then
      gpio.write(PIN_4026_RESET, gpio.LOW)
      phase = 1
      return
    end

    if pulsesLeft <= 0 then
      t:stop()
      displayBusy = false
      if displayPending ~= nil then
        local v = displayPending
        displayPending = nil
        display_apply(v)
      end
      return
    end

    if phase == 1 then
      gpio.write(PIN_4026_CLK, gpio.HIGH) -- rising edge counts
      phase = 2
      return
    end

    gpio.write(PIN_4026_CLK, gpio.LOW)
    pulsesLeft = pulsesLeft - 1
    phase = 1
  end)
end

-- =========================
-- Buzzer / FX helpers
-- =========================

local beepTimer = tmr.create()

local function play_tone(interval_ms, duration_ms, cb)
  beepTimer:stop()

  if interval_ms < 1 then interval_ms = 1 end
  if duration_ms < 1 then duration_ms = 1 end

  local elapsed = 0
  local state = 0

  beepTimer:alarm(interval_ms, tmr.ALARM_AUTO, function(t)
    state = 1 - state
    gpio.write(PIN_BUZZER, state)

    elapsed = elapsed + interval_ms
    if elapsed >= duration_ms then
      t:stop()
      gpio.write(PIN_BUZZER, gpio.LOW)
      if cb then cb() end
    end
  end)
end

-- Pattern items:
-- { tone = interval_ms, ms = duration_ms } or { pause = ms }
local function play_pattern(pattern)
  local i = 1

  local function step()
    if i > #pattern then
      gpio.write(PIN_BUZZER, gpio.LOW)
      return
    end

    local p = pattern[i]
    i = i + 1

    if p.pause then
      tmr.create():alarm(p.pause, tmr.ALARM_SINGLE, step)
      return
    end

    play_tone(p.tone, p.ms, step)
  end

  step()
end

-- Simple LED feedback (non-blocking)
local function blink_leds(times, interval_ms, useGreen, useRed)
  local left = times * 2
  local state = false
  local timer = tmr.create()

  timer:alarm(interval_ms, tmr.ALARM_AUTO, function(t)
    state = not state
    local v = state and gpio.HIGH or gpio.LOW

    if useGreen then gpio.write(PIN_LED_GREEN, v) end
    if useRed then gpio.write(PIN_LED_RED, v) end

    left = left - 1
    if left <= 0 then
      t:stop()
    end
  end)
end

-- =========================
-- Sound effects (realistic click + laser, but SAFE)
-- =========================

local function sound_shot()
  -- 1) Mechanical click: two low short ticks
  -- 2) Ignition crack: very short high chirps
  -- 3) Laser pew: descending "pew"
  play_pattern({
    -- click-click (low)
    { tone = 10, ms = 22 }, { pause = 12 },
    { tone = 12, ms = 18 }, { pause = 14 },

    -- ignition crackle (high short)
    { tone = 2, ms = 10 }, { pause = 6 },
    { tone = 1, ms = 12 }, { pause = 6 },
    { tone = 2, ms = 10 }, { pause = 10 },

    -- pew (descending)
    { tone = 1, ms = 28 }, { pause = 8 },
    { tone = 2, ms = 36 }, { pause = 8 },
    { tone = 3, ms = 55 },
  })
end

local function sound_empty()
  -- dry trigger + "no ammo" thunk
  play_pattern({
    { tone = 12, ms = 22 }, { pause = 60 },
    { tone = 9,  ms = 90 },
  })
end

local function sound_reload_start()
  -- mag out/in: low + mid click
  play_pattern({
    { tone = 11, ms = 35 }, { pause = 40 },
    { tone = 8,  ms = 45 }, { pause = 30 },
    { tone = 6,  ms = 60 },
  })
end

local function sound_reload_done()
  -- confirm: short + long
  play_pattern({
    { tone = 4, ms = 45 }, { pause = 30 },
    { tone = 2, ms = 140 },
  })
end

local function sound_reload_blocked()
  -- magazine full: triple warning
  play_pattern({
    { tone = 7, ms = 60 }, { pause = 60 },
    { tone = 7, ms = 60 }, { pause = 60 },
    { tone = 7, ms = 120 },
  })
end

-- =========================
-- Main logic
-- =========================

local function update_leds()
  if bullets > 0 then
    gpio.write(PIN_LED_GREEN, gpio.HIGH)
    gpio.write(PIN_LED_RED,   gpio.LOW)
  else
    gpio.write(PIN_LED_GREEN, gpio.LOW)
    gpio.write(PIN_LED_RED,   gpio.HIGH)
  end
end

local function apply_state()
  update_leds()
  display_apply(bullets)
end

local function shoot()
  if reloading then
    return
  end

  if bullets <= 0 then
    sound_empty()
    blink_leds(2, 90, false, true) -- red blink
    return
  end

  bullets = bullets - 1
  apply_state()
  sound_shot()

  gpio.write(PIN_LASER, gpio.HIGH)
  tmr.create():alarm(200, tmr.ALARM_SINGLE, function()
    gpio.write(PIN_LASER, gpio.LOW)
  end)
end

local function start_reload()
  if reloading then
    return
  end

  -- Block reload when magazine is full
  if bullets >= MAX_BULLETS then
    sound_reload_blocked()
    blink_leds(3, 80, true, true) -- blink both LEDs
    return
  end

  reloading = true
  sound_reload_start()

  local blinkState = false
  local blinkTimer = tmr.create()
  blinkTimer:alarm(180, tmr.ALARM_AUTO, function()
    blinkState = not blinkState
    local v = blinkState and gpio.HIGH or gpio.LOW
    gpio.write(PIN_LED_GREEN, v)
    gpio.write(PIN_LED_RED,   v)
  end)

  tmr.create():alarm(3000, tmr.ALARM_SINGLE, function()
    blinkTimer:stop()
    bullets = MAX_BULLETS
    reloading = false
    apply_state()
    sound_reload_done()
  end)
end

local function poll_buttons()
  local trig = gpio.read(PIN_TRIGGER)
  local rel  = gpio.read(PIN_RELOAD)

  if lastTrigger == 1 and trig == 0 then
    shoot()
  end

  if lastReload == 1 and rel == 0 then
    start_reload()
  end

  lastTrigger = trig
  lastReload  = rel
end

apply_state()

local mainTimer = tmr.create()
mainTimer:alarm(20, tmr.ALARM_AUTO, poll_buttons)

print("Laser gun ready. Bullets:", bullets)