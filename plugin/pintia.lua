--- Command surface for pintia.nvim. Everything is also reachable via require('pintia').
if vim.g.loaded_pintia == 1 then
  return
end
vim.g.loaded_pintia = 1

require('pintia').register_commands()
