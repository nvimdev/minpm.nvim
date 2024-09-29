local api = vim.api

local window = {}
function window:new()
  local o = {}
  setmetatable(o, self)
  self.__index = self
  self.content = {}
  self.last_row = -1
  return o
end
function window:create_buffer()
  self.bufnr = api.nvim_create_buf(false, false)
  vim.bo[self.bufnr].buftype = 'nofile'
  vim.bo[self.bufnr].bufhidden = 'wipe'
end

function window:set_mappings()
  vim.keymap.set('n', 'q', function()
    if self.winid and api.nvim_win_is_valid(self.winid) then
      api.nvim_win_close(self.winid, true)
      self.bufnr, self.winid = nil, nil
    end
  end, { buffer = self.bufnr, desc = 'quit window' })
end

function window:create_window()
  self:create_buffer()
  self.winid = api.nvim_open_win(self.bufnr, true, {
    relative = 'editor',
    height = math.floor(vim.o.lines * 0.5),
    width = math.floor(vim.o.columns * 0.8),
    row = 3,
    col = 10,
    border = 'rounded',
    noautocmd = true,
    style = 'minimal',
  })
  vim.wo[self.winid].wrap = false
  self:set_mappings()
end

function window:get_row(repo_name)
  if not vim.list_contains(self.content, repo_name) then
    self.content[#self.content + 1] = repo_name
    return #self.content
  end
  for k, v in ipairs(self.content) do
    if v == repo_name then
      return k
    end
  end
end

function window:write_output(name, data)
  local row = self:get_row(name) - 1
  vim.schedule(function()
    if not self.bufnr then
      self:create_window()
    end
    vim.bo[self.bufnr].modifiable = true
    api.nvim_buf_set_lines(self.bufnr, row, row + 1, false, { ('%s: %s'):format(name, data) })
    vim.bo[self.bufnr].modifiable = false
  end)
end

return window
