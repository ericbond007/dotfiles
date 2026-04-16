return {
  "dmmulroy/tsc.nvim",
  config = function()
    require("tsc").setup({
      auto_open_qflist = true,
      auto_focus_qflist = true,
      use_diagnostics = true,
      flags = "--build --noEmit --project tsconfig.app.json",
    })
  end,
}
