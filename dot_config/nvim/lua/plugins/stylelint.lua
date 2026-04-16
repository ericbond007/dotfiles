return {
  -- "bmatcuk/stylelint-lsp",
  require("lspconfig").stylelint_lsp.setup({
    settings = {
      stylelintplus = {
        filetypes = { "css", "scss", "vue", "html", "postcss", "stylus", "less" },
        -- root_dir = require("lspconfig").util.root_pattern("package.json", ".git"),
        autoFixOnFormat = true,
        autoFixOnSave = true,
        validateOnSave = true,
        enable = true,
      },
    },
    -- on_attach = function(_, buffer)
    --   -- Call lsp format on save
    --   vim.api.nvim_create_autocmd("BufWritePre", {
    --     buffer = buffer,
    --     callback = function()
    --       vim.lsp.buf.format()
    --     end,
    --   })
    -- end,
    -- on_attach = function(client)
    --   client.server_capabilities.document_formatting = false
    -- end,
  }),
}
