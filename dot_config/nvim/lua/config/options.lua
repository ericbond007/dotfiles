-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local opt = vim.opt

opt.confirm = false
opt.clipboard = "unnamedplus"
opt.mouse = "a"
opt.number = true
opt.relativenumber = false
opt.smartindent = true
opt.spelllang = { "en" }
opt.splitright = true
opt.termguicolors = true
opt.undofile = true
opt.undolevels = 10000
opt.wildmode = "longest:full,full"
opt.wrap = true

-- vim.opt.foldmethod = "manual"
vim.g.nvim_tree_window_picker_exclude = {
  filetype = {
    "notify",
  },
}

opt.inccommand = "split"
opt.incsearch = true
opt.rulerformat = "%l,%v  %P"
opt.jumpoptions = "stack,view"
