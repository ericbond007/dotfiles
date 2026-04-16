vim.g.neon_style = "dark"
return {
  {
    "rafamadriz/neon",
  },
  { "ellisonleao/gruvbox.nvim" },
  { "Koalhack/darcubox-nvim" },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox",
      -- colorscheme = "darcubox",
    },
  },
}
