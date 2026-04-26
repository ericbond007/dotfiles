return {
  {
    "ThePrimeagen/refactoring.nvim",
    dependencies = { "lewis6991/async.nvim" },
    -- refactoring.nvim removed telescope support in 7bcb7f7, but LazyVim's
    -- stock config still calls `telescope.load_extension("refactoring")`
    -- and errors on startup. Override config to skip that.
    config = function(_, opts)
      require("refactoring").setup(opts)
    end,
  },
}
