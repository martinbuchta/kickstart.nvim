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

local function get_highlight(group)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return ok and highlight or {}
end

local function highlight_diffview_delete_fillers()
  local diff_delete = get_highlight 'DiffDelete'
  local diff_removed = get_highlight 'diffRemoved'
  local diagnostic_error = get_highlight 'DiagnosticError'
  local deleted_bg = diff_delete.bg or diff_removed.bg
  local fallback_fg = vim.o.background == 'light' and '#cf222e' or '#ff7b72'
  local deleted_fg = diff_removed.fg or diagnostic_error.fg or fallback_fg

  vim.api.nvim_set_hl(0, 'DiffviewDiffAddAsDelete', { bg = deleted_bg })
  vim.api.nvim_set_hl(0, 'DiffviewDiffDelete', { fg = deleted_fg, bg = deleted_bg })
  vim.api.nvim_set_hl(0, 'DiffviewDiffDeleteDim', { fg = deleted_fg, bg = deleted_bg })
end

local function lsp_clients(bufnr, method)
  return vim.tbl_filter(function(client)
    return client:supports_method(method, bufnr)
  end, vim.lsp.get_clients { bufnr = bufnr })
end

local function notify_no_diffview_lsp(action)
  vim.notify(('No LSP %s available for this Diffview buffer'):format(action), vim.log.levels.WARN)
end

local function worktree_path_from_diffview_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= '' and vim.fn.filereadable(name) == 1 then return name end

  local root, relpath = name:match '^diffview://(.+)/%.git/[^/]+/(.+)$'
  if not root then return nil end

  local path = vim.fs.joinpath(root, relpath)
  if vim.fn.filereadable(path) == 1 then return path end
end

local function focus_previous_non_diffview_tab()
  local ok, diffview_lib = pcall(require, 'diffview.lib')
  local tabpage = ok and diffview_lib.get_prev_non_view_tabpage()

  if tabpage then
    vim.api.nvim_set_current_tabpage(tabpage)
    return
  end

  vim.cmd 'tabnew'
  return vim.api.nvim_get_current_buf()
end

local function reset_plain_file_window()
  vim.wo.diff = false
  vim.wo.scrollbind = false
  vim.wo.cursorbind = false
  vim.wo.foldenable = false
  vim.wo.foldmethod = 'manual'
  vim.wo.winhl = ''
end

local function delete_temp_buffer(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and bufnr ~= vim.api.nvim_get_current_buf() then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function diffview_snapshot_name(name)
  local root, context, relpath = name:match '^diffview://(.+)/%.git/([^/]+)/(.*)$'
  if root then return ('diffview-file://%s/.git/%s/%s'):format(root, context, relpath) end

  if not name:match '^diffview://' then return 'diffview-file://' .. name end

  return name:gsub('^diffview://', 'diffview-file://')
end

local function diffview_snapshot_buffer(source_bufnr)
  local source_name = vim.api.nvim_buf_get_name(source_bufnr)
  local target_name = diffview_snapshot_name(source_name)
  local target_bufnr = vim.fn.bufnr(target_name)

  if target_bufnr == -1 then
    target_bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(target_bufnr, target_name)
  else
    vim.fn.bufload(target_bufnr)
  end

  vim.bo[target_bufnr].buftype = 'nofile'
  vim.bo[target_bufnr].bufhidden = 'hide'
  vim.bo[target_bufnr].swapfile = false
  vim.bo[target_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(
    target_bufnr,
    0,
    -1,
    false,
    vim.api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
  )
  vim.bo[target_bufnr].modified = false
  vim.bo[target_bufnr].modifiable = false
  vim.bo[target_bufnr].readonly = true
  vim.bo[target_bufnr].filetype = vim.bo[source_bufnr].filetype

  return target_bufnr
end

local function set_cursor_safely(cursor)
  local line_count = vim.api.nvim_buf_line_count(0)
  local line = math.min(cursor[1], line_count)
  local line_text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ''
  local column = math.min(cursor[2], math.max(#line_text - 1, 0))

  pcall(vim.api.nvim_win_set_cursor, 0, { line, column })
end

local function open_file_normally(path, cursor)
  local temp_bufnr = focus_previous_non_diffview_tab()

  vim.cmd('keepalt edit ' .. vim.fn.fnameescape(path))

  delete_temp_buffer(temp_bufnr)
  reset_plain_file_window()
  if cursor then set_cursor_safely(cursor) end
end

local function diffview_current_worktree_path(diffview_lib)
  local view = diffview_lib.get_current_view()
  if not view then return end

  local ok, file = pcall(function()
    if view.infer_cur_file then return view:infer_cur_file() end
  end)

  if ok and file and file.absolute_path and vim.fn.filereadable(file.absolute_path) == 1 then
    return file.absolute_path
  end

  return worktree_path_from_diffview_buffer(vim.api.nvim_get_current_buf())
end

local function open_diffview_side_normally()
  local ok, diffview_lib = pcall(require, 'diffview.lib')
  if not (ok and diffview_lib.get_current_view()) then
    pcall(vim.cmd, 'normal! gf')
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local source_name = vim.api.nvim_buf_get_name(source_bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)

  if source_name == '' or source_name == 'diffview://null' then
    vim.notify('No file version available for this Diffview pane', vim.log.levels.WARN)
    return
  end

  if vim.fn.filereadable(source_name) == 1 then
    open_file_normally(source_name, cursor)
    return
  end

  local temp_bufnr = focus_previous_non_diffview_tab()
  vim.api.nvim_win_set_buf(0, diffview_snapshot_buffer(source_bufnr))

  delete_temp_buffer(temp_bufnr)
  reset_plain_file_window()
  set_cursor_safely(cursor)
end

local function open_diffview_worktree_normally()
  local ok, diffview_lib = pcall(require, 'diffview.lib')
  if not (ok and diffview_lib.get_current_view()) then
    pcall(vim.cmd, 'normal! gf')
    return
  end

  local path = diffview_current_worktree_path(diffview_lib)
  if not path then
    vim.notify('Latest version does not exist on disk for this Diffview entry', vim.log.levels.WARN)
    return
  end

  open_file_normally(path, vim.api.nvim_win_get_cursor(0))
end

local function load_worktree_buffer(path)
  local bufnr = vim.fn.bufadd(path)
  vim.bo[bufnr].swapfile = false
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

local function current_byte_position()
  local position = vim.api.nvim_win_get_cursor(0)
  return {
    line = math.max(position[1] - 1, 0),
    character = position[2],
  }
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

local function lsp_position_params(bufnr, byte_position, client, extra)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = {
      line = byte_position.line,
      character = vim.lsp.util.character_offset(
        bufnr,
        byte_position.line,
        byte_position.character,
        client.offset_encoding
      ),
    },
  }

  if extra then params = vim.tbl_deep_extend('force', params, extra) end

  return params
end

local function diffview_lsp_target(method, action)
  local bufnr = vim.api.nvim_get_current_buf()
  if #lsp_clients(bufnr, method) > 0 then return bufnr, current_byte_position() end

  local path = worktree_path_from_diffview_buffer(bufnr)
  if not path then
    notify_no_diffview_lsp(action)
    return
  end

  local target_bufnr = load_worktree_buffer(path)
  attach_matching_lsp_clients(target_bufnr)

  return target_bufnr, source_position_in_target_buffer(target_bufnr)
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
  local clients = lsp_clients(bufnr, 'textDocument/hover')
  if #clients == 0 then
    if attempt == 1 then
      vim.defer_fn(function() request_hover_from_buffer(bufnr, position, 2) end, 150)
    else
      notify_no_diffview_lsp('hover')
    end
    return
  end

  local remaining = #clients
  local shown = false

  for _, client in ipairs(clients) do
    local params = lsp_position_params(bufnr, position, client)

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

      if remaining == 0 and not shown then
        vim.schedule(function() notify_no_diffview_lsp 'hover' end)
      end
    end, bufnr)
  end
end

local function diffview_hover()
  local bufnr, position = diffview_lsp_target('textDocument/hover', 'hover')
  if not bufnr then return end

  request_hover_from_buffer(bufnr, position, 1)
end

local function open_lsp_location(location, offset_encoding)
  local uri = location.uri or location.targetUri
  if uri then vim.cmd('tab drop ' .. vim.fn.fnameescape(vim.uri_to_fname(uri))) end

  vim.lsp.util.show_document(location, offset_encoding, { reuse_win = true, focus = true })
end

local function handle_lsp_locations(title, items, first_location, first_encoding)
  if vim.tbl_isempty(items) then
    vim.notify(('No %s found'):format(title), vim.log.levels.INFO)
    return
  end

  if #items == 1 and first_location and first_encoding then
    open_lsp_location(first_location, first_encoding)
    return
  end

  vim.fn.setqflist({}, ' ', { title = title, items = items })
  vim.cmd 'botright copen'
end

local function request_locations_from_buffer(bufnr, position, method, action, title, extra, attempt)
  local clients = lsp_clients(bufnr, method)
  if #clients == 0 then
    if attempt == 1 then
      vim.defer_fn(function()
        request_locations_from_buffer(bufnr, position, method, action, title, extra, 2)
      end, 150)
    else
      notify_no_diffview_lsp(action)
    end
    return
  end

  local remaining = #clients
  local items = {}
  local first_location
  local first_encoding

  for _, client in ipairs(clients) do
    local params = lsp_position_params(bufnr, position, client, extra)

    client:request(method, params, function(err, result)
      remaining = remaining - 1

      if not err and result then
        local locations = vim.islist(result) and result or { result }
        if not vim.tbl_isempty(locations) then
          first_location = first_location or locations[1]
          first_encoding = first_encoding or client.offset_encoding
          vim.list_extend(
            items,
            vim.lsp.util.locations_to_items(locations, client.offset_encoding)
          )
        end
      end

      if remaining == 0 then
        vim.schedule(function()
          handle_lsp_locations(title, items, first_location, first_encoding)
        end)
      end
    end, bufnr)
  end
end

local function diffview_lsp_locations(method, action, title, extra)
  return function()
    local bufnr, position = diffview_lsp_target(method, action)
    if not bufnr then return end

    request_locations_from_buffer(bufnr, position, method, action, title, extra, 1)
  end
end

local function set_diffview_lsp_keymaps()
  vim.keymap.set('n', 'K', diffview_hover, { buffer = true, desc = 'Show hover documentation' })
  vim.keymap.set(
    'n',
    'grd',
    diffview_lsp_locations('textDocument/definition', 'definition', 'LSP definitions'),
    { buffer = true, desc = 'LSP: [G]oto [D]efinition' }
  )
  vim.keymap.set(
    'n',
    'gri',
    diffview_lsp_locations('textDocument/implementation', 'implementation', 'LSP implementations'),
    { buffer = true, desc = 'LSP: [G]oto [I]mplementation' }
  )
  vim.keymap.set(
    'n',
    'grt',
    diffview_lsp_locations('textDocument/typeDefinition', 'type definition', 'LSP type definitions'),
    { buffer = true, desc = 'LSP: [G]oto [T]ype Definition' }
  )
  vim.keymap.set(
    'n',
    'grD',
    diffview_lsp_locations('textDocument/declaration', 'declaration', 'LSP declarations'),
    { buffer = true, desc = 'LSP: [G]oto [D]eclaration' }
  )
  vim.keymap.set(
    'n',
    'grr',
    diffview_lsp_locations('textDocument/references', 'references', 'LSP references', {
      context = { includeDeclaration = true },
    }),
    { buffer = true, desc = 'LSP: [G]oto [R]eferences' }
  )
end

require('diffview').setup {
  enhanced_diff_hl = true,
  default_args = {
    DiffviewOpen = { '--imply-local' },
  },
  keymaps = {
    view = {
      { 'n', 'gf', open_diffview_side_normally, { desc = 'Open this Diffview side normally' } },
      { 'n', 'gF', open_diffview_worktree_normally, { desc = 'Open latest version normally' } },
    },
    file_panel = {
      { 'n', 'gF', open_diffview_worktree_normally, { desc = 'Open latest version normally' } },
    },
    file_history_panel = {
      { 'n', 'gF', open_diffview_worktree_normally, { desc = 'Open latest version normally' } },
    },
  },
  hooks = {
    diff_buf_read = function()
      simplify_diffview_window()
      set_diffview_lsp_keymaps()
    end,
    diff_buf_win_enter = function()
      simplify_diffview_window()
    end,
  },
}

highlight_diffview_delete_fillers()

vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('diffview-delete-fillers', { clear = true }),
  callback = function() vim.schedule(highlight_diffview_delete_fillers) end,
})

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
