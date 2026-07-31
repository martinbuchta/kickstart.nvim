-- Neo-tree is a Neovim plugin to browse the file system
-- https://github.com/nvim-neo-tree/neo-tree.nvim

local plugins = {
  { src = 'https://github.com/nvim-neo-tree/neo-tree.nvim', version = vim.version.range '*' },
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/MunifTanjim/nui.nvim',
}

if vim.g.have_nerd_font then
  table.insert(plugins, 'https://github.com/nvim-tree/nvim-web-devicons') -- not strictly required, but recommended
end

vim.pack.add(plugins)

vim.keymap.set('n', '\\', '<Cmd>Neotree reveal<CR>', { desc = 'NeoTree reveal', silent = true })

local function neo_tree_width()
  -- Keep the tree compact on a laptop, but give long names more room in a
  -- very wide terminal (the ultrawide setup is currently about 429 columns).
  return vim.o.columns >= 380 and 60 or 40
end

require('neo-tree').setup {
  window = {
    width = neo_tree_width,
  },
  filesystem = {
    filtered_items = {
      visible = true,
      hide_dotfiles = false,
      hide_gitignored = false,
      hide_ignored = false,
      hide_hidden = false,
      hide_by_name = {},
      hide_by_pattern = {},
      never_show = {},
      never_show_by_pattern = {},
    },
    window = {
      mappings = {
        ['\\'] = 'close_window',
      },
    },
  },
}

-- Reapply the appropriate width if the terminal moves between displays.
vim.api.nvim_create_autocmd('VimResized', {
  group = vim.api.nvim_create_augroup('neo-tree-responsive-width', { clear = true }),
  callback = function()
    local width = neo_tree_width()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == 'neo-tree' then
        vim.api.nvim_win_set_width(win, width)
      end
    end
  end,
})
