return {
  "neovim/nvim-lspconfig",
  -- dependencies = {
  --   "stylelint-lsp",
  --   {
  --     "bmatcuk/stylelint-lsp",
  --   },
  -- },
  opts = {
    setup = {
      -- stylelint_lsp = function(_, opts)
      --   opts.filetypes = { "css", "scss", "less", "postcss", "stylus", "vue" }
      --   opts.autoFixOnSave = true
      --   opts.enable = true
      --   opts.validateOnSave = true
      --   opts.autoFixOnFormat = true
      --   opts.stylelintplus = {
      --     autoFixOnFormat = true,
      --     validateOnSave = true,
      --     enable = true,
      --     -- root_dir = require("lspconfig.util").root_pattern("package.json", ".git"),
      --   }
      -- end,
    },
    servers = {
      lua_ls = {},
      vtsls = {
        -- enabled = false,
      },

      css_variables = {},
      eslint = {
        settings = {
          experimental = {
            useFlatConfig = false,
          },
        },
      },
      angularls = {},
      html = {},
      jsonls = {},
      stylelint_lsp = {
        settings = {
          stylelintplus = {
            autoFixOnFormat = true,
            autoFixOnSave = true,
            validateOnSave = true,
          },
        },
      },
    },
    inlay_hints = { enabled = true },
  },
}
