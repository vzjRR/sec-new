--[[
  security-lab-exp-peer / server / main.lua

  One export, returning a table that contains BOTH a function and a plain value.

  Both matter to the measurement: if the function is gone but the marker survives, the
  boundary serialises and drops functions; if neither survives, the call failed for a
  different reason entirely. Returning only a function would leave those two cases
  indistinguishable.
]]

exports('probeTable', function()
  return {
    marker = 'plain-value-survived',
    fn = function() return 'function-survived' end,
  }
end)

AddEventHandler('onResourceStart', function(resource)
  if resource ~= GetCurrentResourceName() then return end
  print('[security-lab-exp-peer] ready (EXP-010 peer)')
end)
