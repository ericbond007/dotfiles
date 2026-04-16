-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local Util = require("lazyvim.util")

local function map(mode, lhs, rhs, opts)
  local keys = require("lazy.core.handler").handlers.keys
  ---@cast keys LazyKeysHandler
  -- do not create the keymap if a lazy keys handler exists
  if not keys.active[keys.parse({ lhs, mode = mode }).id] then
    opts = opts or {}
    opts.silent = opts.silent ~= false
    if opts.remap and not vim.g.vscode then
      opts.remap = nil
    end
    vim.keymap.set(mode, lhs, rhs, opts)
  end
end

vim.keymap.set("n", "<leader>ca", function()
  require("tiny-code-action").code_action()
end, { noremap = true, silent = true })

map({ "n", "x" }, "gw", "*N", { desc = "Search word under cursor" })
-- fuck me, quit already!
vim.api.nvim_create_user_command("Q", "q", { desc = "Fucking Quit!" })

-- Clear search with <esc>
map({ "i", "n" }, "<esc>", "<cmd>noh<cr><esc>", { desc = "Escape and clear hlsearch" })

if Util.has("bufferline.nvim") then
  map("n", "<S-Tab>", "<cmd>BufferLineCyclePrev<cr>", { desc = "Prev buffer" })
  map("n", "<Tab>", "<cmd>BufferLineCycleNext<cr>", { desc = "Next buffer" })
  map("n", "[b", "<cmd>BufferLineCyclePrev<cr>", { desc = "Prev buffer" })
  map("n", "]b", "<cmd>BufferLineCycleNext<cr>", { desc = "Next buffer" })
else
  map("n", "<S-Tab>", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
  map("n", "<Tab>", "<cmd>bnext<cr>", { desc = "Next buffer" })
  map("n", "[b", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
  map("n", "]b", "<cmd>bnext<cr>", { desc = "Next buffer" })
end

-- lazy
map("n", "<leader>ll", "<cmd>Lazy<cr>", { desc = "Lazy" })

-- diagontics - next, Prev <- not working
-- map("n", "]c", "<cmd>lua vim.diagnostic.goto_next()<cr>", { desc = "Next diagnostic" })
-- map("n", "[c", "<cmd>lua vim.diagnostic.goto_prev()<cr>", { desc = "Prev diagnostic" })

-- git log of current file
map("n", "<leader>gL", "<cmd>:Git log -p -- %<cr>", { desc = "Git full log - current file" })

-- toggle inlay hints
map(
  "n",
  "<leader>th",
  "<cmd> lua vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled()) <cr>",
  { desc = "Toggle inlay hints" }
)

-- toggle precog
map("n", "<leader>tp", "<cmd> Precognition toggle <cr>", { desc = "Toggle precog" })

-- Move Lines
map("n", "<A-Up>", "<cmd>execute 'move .+' . v:count1<cr>==", { desc = "Move Down" })
map("n", "<A-Down>", "<cmd>execute 'move .-' . (v:count1 + 1)<cr>==", { desc = "Move Up" })
map("i", "<A-Up>", "<esc><cmd>m .+1<cr>==gi", { desc = "Move Down" })
map("i", "<A-Down>", "<esc><cmd>m .-2<cr>==gi", { desc = "Move Up" })
map("v", "<A-Up>", ":<C-u>execute \"'<,'>move '>+\" . v:count1<cr>gv=gv", { desc = "Move Down" })
map("v", "<A-Down>", ":<C-u>execute \"'<,'>move '<-\" . (v:count1 + 1)<cr>gv=gv", { desc = "Move Up" })

-- Move to window using the <ctrl> hjkl keys
map("n", "<C-Left>", "<C-w>h", { desc = "Go to Left Window", remap = true })
map("n", "<C-Down>", "<C-w>j", { desc = "Go to Lower Window", remap = true })
map("n", "<C-Up>", "<C-w>k", { desc = "Go to Upper Window", remap = true })
map("n", "<C-Right>", "<C-w>l", { desc = "Go to Right Window", remap = true })

-- search in visual only
map("x", "/", "<Esc>/\\%V", { desc = "Search in visual only" })

-- better join
map("n", "J", "mzJ`z:delmarks z<cr>", { desc = "Join lines and delete marks" })
