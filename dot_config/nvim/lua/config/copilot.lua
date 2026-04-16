return {
  "zbirenbaum/copilot.lua",
  cmd = "Copilot",
  build = ":Copilot auth",
  opts = {
    telemetry = { enabled = false, telemetryLevel = "none" },
    suggestion = { enabled = true, auto_trigger = true },
    panel = { enabled = true, auto_refresh = true },
    filetypes = {
      markdown = true,
      help = true,
    },
  },
  config = function()
    require("copilot").setup({})
  end,
}
