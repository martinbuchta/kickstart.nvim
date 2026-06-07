local function gh(repo) return 'https://github.com/' .. repo end

local has_gh = vim.fn.executable 'gh' == 1

local plugins = {
  gh 'sindrets/diffview.nvim',
  gh 'NeogitOrg/neogit',
}

if has_gh then table.insert(plugins, gh 'pwntester/octo.nvim') end

vim.pack.add(plugins)

local function simplify_diffview_diffopt()
  local diffopt = vim.tbl_filter(function(item)
    return not item:match '^inline:' and not item:match '^linematch:'
  end, vim.opt_local.diffopt:get())

  vim.opt_local.diffopt = diffopt
end

local function simplify_diffview_window()
  simplify_diffview_diffopt()
  vim.wo.cursorline = false
end

local function hover_clients(bufnr)
  return vim.tbl_filter(function(client)
    return client:supports_method('textDocument/hover', bufnr)
  end, vim.lsp.get_clients { bufnr = bufnr })
end

local function notify_no_diffview_hover()
  vim.notify('No LSP hover available for this Diffview buffer', vim.log.levels.WARN)
end

local function worktree_path_from_diffview_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= '' and vim.fn.filereadable(name) == 1 then return name end

  local root, relpath = name:match '^diffview://(.+)/%.git/[^/]+/(.+)$'
  if not root then return nil end

  local path = vim.fs.joinpath(root, relpath)
  if vim.fn.filereadable(path) == 1 then return path end
end

local function load_worktree_buffer(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)

  vim.api.nvim_buf_call(bufnr, function()
    if vim.bo[bufnr].filetype == '' then vim.cmd 'filetype detect' end
  end)

  return bufnr
end

local function attach_matching_lsp_clients(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype

  for _, client in ipairs(vim.lsp.get_clients()) do
    local client_filetypes = client.config and client.config.filetypes
    local root_dir = client.config and client.config.root_dir
    local filetype_matches = not client_filetypes or vim.tbl_contains(client_filetypes, filetype)
    local root_matches = type(root_dir) ~= 'string' or vim.startswith(path, root_dir)

    if filetype_matches and root_matches then pcall(vim.lsp.buf_attach_client, bufnr, client.id) end
  end
end

local function source_position_in_target_buffer(target_bufnr)
  local source_pos = vim.api.nvim_win_get_cursor(0)
  local source_lnum = source_pos[1]
  local source_col = source_pos[2]
  local source_line = vim.api.nvim_get_current_line()
  local target_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
  local target_lnum = source_lnum

  if target_lines[target_lnum] ~= source_line then
    local first = math.max(1, source_lnum - 100)
    local last = math.min(#target_lines, source_lnum + 100)

    for lnum = first, last do
      if target_lines[lnum] == source_line then
        target_lnum = lnum
        break
      end
    end
  end

  local target_line = target_lines[target_lnum] or ''
  local target_col = math.min(source_col, math.max(#target_line - 1, 0))

  return {
    line = math.max(target_lnum - 1, 0),
    character = target_col,
  }
end

local function hover_preview_lines(result)
  if not (result and result.contents) then return false end

  local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
  lines = vim.lsp.util.trim_empty_lines(lines)
  if vim.tbl_isempty(lines) then return false end

  return lines
end

local function open_hover_preview(lines)
  vim.lsp.util.open_floating_preview(lines, 'markdown', {
    border = 'rounded',
    focusable = true,
  })
end

local function request_hover_from_buffer(bufnr, position, attempt)
  local clients = hover_clients(bufnr)
  if #clients == 0 then
    if attempt == 1 then
      vim.defer_fn(function() request_hover_from_buffer(bufnr, position, 2) end, 150)
    else
      notify_no_diffview_hover()
    end
    return
  end

  local remaining = #clients
  local shown = false

  for _, client in ipairs(clients) do
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = position,
    }

    client:request('textDocument/hover', params, function(err, result)
      if shown then return end

      remaining = remaining - 1
      if not err and result then
        local lines = hover_preview_lines(result)
        if lines then
          shown = true
          vim.schedule(function() open_hover_preview(lines) end)
        end
      end

      if remaining == 0 and not shown then vim.schedule(notify_no_diffview_hover) end
    end, bufnr)
  end
end

local function diffview_hover()
  local bufnr = vim.api.nvim_get_current_buf()
  if #hover_clients(bufnr) > 0 then
    vim.lsp.buf.hover()
    return
  end

  local path = worktree_path_from_diffview_buffer(bufnr)
  if not path then
    notify_no_diffview_hover()
    return
  end

  local target_bufnr = load_worktree_buffer(path)
  attach_matching_lsp_clients(target_bufnr)
  request_hover_from_buffer(target_bufnr, source_position_in_target_buffer(target_bufnr), 1)
end

require('diffview').setup {
  default_args = {
    DiffviewOpen = { '--imply-local' },
  },
  hooks = {
    diff_buf_read = function()
      simplify_diffview_window()
      vim.keymap.set('n', 'K', diffview_hover, { buffer = true, desc = 'Show hover documentation' })
    end,
    diff_buf_win_enter = function()
      simplify_diffview_window()
    end,
  },
}

require('neogit').setup {
  integrations = {
    diffview = true,
    telescope = true,
  },
}

local map = vim.keymap.set

local function diff_input(default)
  vim.ui.input({ prompt = 'Diff rev/range: ', default = default or 'HEAD^!' }, function(input)
    if input and input ~= '' then vim.cmd('DiffviewOpen ' .. input) end
  end)
end

local function file_history_current_file()
  vim.cmd 'DiffviewFileHistory %'
end

map('n', '<leader>gg', '<cmd>Neogit<cr>', { desc = '[G]it status' })
map('n', '<leader>gG', '<cmd>Neogit cwd=%:p:h<cr>', { desc = '[G]it status current file repo' })
map('n', '<leader>gd', '<cmd>DiffviewOpen<cr>', { desc = '[G]it [D]iff working tree' })
map('n', '<leader>gD', function() diff_input 'HEAD^!' end, { desc = '[G]it [D]iff rev/range' })
map('n', '<leader>gf', '<cmd>DiffviewFileHistory<cr>', { desc = '[G]it history all files' })
map('n', '<leader>gF', file_history_current_file, { desc = '[G]it history current [F]ile' })
map('n', '<leader>gq', '<cmd>DiffviewClose<cr>', { desc = '[G]it close diffview' })

local ok_telescope, telescope_builtin = pcall(require, 'telescope.builtin')
if ok_telescope then
  map('n', '<leader>gc', telescope_builtin.git_commits, { desc = '[G]it [C]ommits' })
  map('n', '<leader>gC', telescope_builtin.git_bcommits, { desc = '[G]it buffer [C]ommits' })
  map('n', '<leader>gb', telescope_builtin.git_branches, { desc = '[G]it [B]ranches' })
  map('n', '<leader>gs', telescope_builtin.git_status, { desc = '[G]it [S]tatus files' })
  map('n', '<leader>gS', telescope_builtin.git_stash, { desc = '[G]it [S]tashes' })
end

if has_gh then
  require('octo').setup {
    picker = 'telescope',
    enable_builtin = true,
    suppress_missing_scope = {
      projects_v2 = true,
    },
  }

  map('n', '<leader>op', '<cmd>Octo pr list<cr>', { desc = 'GitHub [P]Rs' })
  map('n', '<leader>oi', '<cmd>Octo issue list<cr>', { desc = 'GitHub [I]ssues' })
  map('n', '<leader>on', '<cmd>Octo notification list<cr>', { desc = 'GitHub [N]otifications' })
  map('n', '<leader>os', function()
    require('octo.utils').create_base_search_command { include_current_repo = true }
  end, { desc = 'GitHub [S]earch current repo' })
end
