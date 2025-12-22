-- init.lua

print("\n\n=== Simple Target init ===")

local SAFE_DELAY_MS = 3000 

tmr.create():alarm(SAFE_DELAY_MS, tmr.ALARM_SINGLE, function()
  if file.open("main.lua") then
    file.close()
    print("> Running main.lua...")
    dofile("main.lua")
  else
    print("main.lua not found")
  end
end)