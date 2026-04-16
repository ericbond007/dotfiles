local desc = require("utils").plugin_keymap_desc("lspsaga")
return {
  "nvimdev/lspsaga.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    { "nvim-tree/nvim-web-devicons", lazy = true },
  },
  event = { "LspAttach" },
  opts = {
    ui = { border = "rounded" },
    symbol_in_winbar = { enable = false },
    lightbulb = {
      enable = false,
      sign = false,
    },
    outline = {
      layout = "float",
      max_height = 0.7,
      left_width = 0.4,
    },
  },
  keys = {
    { "<leader>lb", "<Cmd>Lspsaga show_buf_diagnostics<CR>", desc = desc("Diagnostics: Show buffer's") },
    { "<leader>lf", "<Cmd>Lspsaga finder<CR>", desc = desc("Find references") },
    { "<leader>lk", "<Cmd>Lspsaga peek_definition<CR>", desc = desc("Hover definition") },
    { "<leader>lt", "<Cmd>Lspsaga peek_type_definition<CR>", desc = desc("Peek type definition") },
    { "<leader>lo", "<Cmd>Lspsaga outline<CR>", desc = desc("Show file outline - 'e' to jump, 'o' to toggle") },
    { "<leader>la", "<cmd>Lspsaga code_action<CR>", mode = { "n", "v" }, desc = desc("Show code action") },
  },
}
