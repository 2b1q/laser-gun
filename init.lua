print("\n\n=== init.lua: starting gun.lua ===")

if file and file.exists and file.exists("gun.lua") then
  dofile("gun.lua")
else
  print("gun.lua not found")
end