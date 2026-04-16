return {
  "akinsho/bufferline.nvim",
  opts = {
    options = {
      separator_style = "{ '', '' }",
      number = "buffer_id",
      always_show_bufferline = true,

      hover = {
        enabled = true,
        delay = 100,
        reveal = { "close" },
      },
    },
  },
}
