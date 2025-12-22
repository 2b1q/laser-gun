-- Simple Laser Target (raw ADC)
-- LDR + resistor divider -> A0
-- RESET button -> D2 (GPIO4) to GND, PULLUP
-- Green LED -> D6 (GPIO12)
-- Red LED   -> D7 (GPIO13)

print("=== Simple Target (raw ADC) ===")

-- NodeMCU pin indices (IO index, not Dx)
local PIN_BUTTON_RESET  = 2 -- D2
local PIN_LED_GREEN     = 6 -- D6
local PIN_LED_RED       = 7 -- D7

-- timing / filters
local SAMPLE_MS         = 50     -- 20 samples per second
local BASELINE_ALPHA    = 0.01   -- baseline drift speed

-- bright hit detection
-- Only strong bright deviations start a "pulse"
local HIT_DELTA         = 8.0    -- |adc - baseline| threshold for bright pulse

-- pulse duration window (in ticks) for a valid "shot"
-- gun laser is ON for ~200 ms, so we expect about 4 ticks at 50 ms
local BRIGHT_MIN_TICKS  = 2      -- >= 2 ticks  (>= 100 ms)
local BRIGHT_MAX_TICKS  = 6      -- <= 6 ticks  (<= 300 ms)

-- calm region and arming
local REARM_DELTA       = 3.0    -- calm if |adc - baseline| below this
local CALM_TICKS_ARM    = 10     -- calm ticks before arming

-- dark events (finger / shadow)
local HIT_CONFIRM_TICKS = 2      -- consecutive ticks to confirm dark event
local DARK_DISARM_DELTA = 12.0   -- strong dark event threshold
local DARK_DISARM_TICKS = 8      -- long dark duration to disarm (~400 ms)

local DEBUG_EVERY_N     = 5      -- print every N-th tick

-- state
local alive             = true
local armed             = false
local baseline          = nil
local kills             = 0
local lastBtn           = 1
local calmTicks         = 0

-- bright / dark counters
local brightTicks       = 0      -- current bright pulse length (ticks)
local darkTicks         = 0
local darkHoldTicks     = 0

-- last bright sample (for nicer logging)
local lastBrightRaw     = 0
local lastBrightDiff    = 0

local tickCounter       = 0

gpio.mode(PIN_BUTTON_RESET, gpio.INPUT, gpio.PULLUP)
gpio.mode(PIN_LED_GREEN, gpio.OUTPUT)
gpio.mode(PIN_LED_RED, gpio.OUTPUT)

local function leds_alive()
  gpio.write(PIN_LED_GREEN, gpio.HIGH)
  gpio.write(PIN_LED_RED,   gpio.LOW)
end

local function leds_dead()
  gpio.write(PIN_LED_GREEN, gpio.LOW)
  gpio.write(PIN_LED_RED,   gpio.HIGH)
end

local function reset_hit_counters()
  brightTicks   = 0
  darkTicks     = 0
  darkHoldTicks = 0
end

local function set_alive()
  alive      = true
  armed      = false
  baseline   = nil
  calmTicks  = 0
  reset_hit_counters()
  leds_alive()
  print("STATE: ALIVE (shoot me)")
end

local function set_dead(kind, raw, diff)
  if not alive then
    return
  end

  alive     = false
  armed     = false
  calmTicks = 0
  reset_hit_counters()
  kills     = kills + 1

  leds_dead()

  print("HIT (" .. kind .. ") raw=", raw, " diff=", diff, " kills=", kills)
  print("STATE: DEAD")
end

local function update_baseline(v)
  if baseline == nil then
    baseline = v
  else
    baseline = baseline + (v - baseline) * BASELINE_ALPHA
  end
end

local function loop()
  tickCounter = tickCounter + 1

  -- reset button (active low)
  local btn = gpio.read(PIN_BUTTON_RESET)
  if lastBtn == 1 and btn == 0 then
    print("RESET button pressed")
    set_alive()
  end
  lastBtn = btn

  -- ADC read
  local raw = adc.read(0) or 0

  if alive then
    update_baseline(raw)
  end

  local diff, adiff = 0, 0
  if baseline ~= nil then
    diff  = raw - baseline
    adiff = math.abs(diff)
  end

  if alive and baseline ~= nil then
    -- calm detection for arming
    if adiff < REARM_DELTA then
      calmTicks = calmTicks + 1
    else
      calmTicks = 0
    end

    if (not armed) and calmTicks >= CALM_TICKS_ARM then
      armed = true
      reset_hit_counters()
      print("ARMED at baseline:", baseline)
    end

    if armed then
      local brightNow = (diff > 0) and (adiff >= HIT_DELTA)
      local darkNow   = (diff < 0) and (adiff >= HIT_DELTA)

      if brightNow then
        -- we are inside a bright pulse (laser / flashlight)
        brightTicks    = brightTicks + 1
        lastBrightRaw  = raw
        lastBrightDiff = diff
        darkTicks      = 0
        darkHoldTicks  = 0
      else
        -- we are not in bright region now: finalize pulse if there was one
        if brightTicks > 0 then
          if brightTicks >= BRIGHT_MIN_TICKS and brightTicks <= BRIGHT_MAX_TICKS then
            -- treat only short pulses (≈ gun shot) as valid hits
            set_dead("BRIGHT", lastBrightRaw ~= 0 and lastBrightRaw or raw,
                               lastBrightDiff)
            -- after hit we stop processing this tick
            if tickCounter % DEBUG_EVERY_N == 0 then
              print(
                "tick",
                "btn:",   btn,
                "alive:", alive,
                "armed:", armed,
                "adc:",   raw,
                "base:",  baseline,
                "diff:",  diff,
                "adiff:", adiff,
                "bT:",    brightTicks,
                "dT:",    darkTicks,
                "dHT:",   darkHoldTicks,
                "kills:", kills
              )
            end
            return
          end
          -- pulse too short or too long -> ignore
          brightTicks = 0
        end

        -- dark / finger handling
        if darkNow then
          darkTicks     = darkTicks + 1
          darkHoldTicks = darkHoldTicks + 1
        else
          darkTicks = 0
          if adiff < REARM_DELTA or diff >= 0 then
            darkHoldTicks = 0
          end
        end
      end

      -- process dark events
      if darkTicks >= HIT_CONFIRM_TICKS then
        if darkHoldTicks >= DARK_DISARM_TICKS and diff < -DARK_DISARM_DELTA then
          -- long, strong dark event -> disarm
          print(
            "IGNORED DARK EVENT (DISARM) raw=",
            raw,
            " diff=",
            diff,
            " holdTicks=",
            darkHoldTicks
          )
          armed     = false
          calmTicks = 0
          reset_hit_counters()
        else
          -- short dark spike -> noise
          print("DARK NOISE raw=", raw, " diff=", diff, " ticks=", darkTicks)
          darkTicks = 0
        end
      end
    end
  end

  -- debug output
  if tickCounter % DEBUG_EVERY_N == 0 then
    print(
      "tick",
      "btn:",   btn,
      "alive:", alive,
      "armed:", armed,
      "adc:",   raw,
      "base:",  baseline,
      "diff:",  diff,
      "adiff:", adiff,
      "bT:",    brightTicks,
      "dT:",    darkTicks,
      "dHT:",   darkHoldTicks,
      "kills:", kills
    )
  end
end

set_alive()
tmr.create():alarm(SAMPLE_MS, tmr.ALARM_AUTO, loop)
print("Target ready (laser / finger detector)")