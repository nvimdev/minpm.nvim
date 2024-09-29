local TaskQueue = {}
TaskQueue.__index = TaskQueue

function TaskQueue:new(max_concurrent)
  return setmetatable({
    active_tasks = 0,
    max_concurrent_tasks = max_concurrent or 2,
    task_queue = {},
  }, TaskQueue)
end

function TaskQueue:process_queue()
  while self.active_tasks < self.max_concurrent_tasks and #self.task_queue > 0 do
    local task = table.remove(self.task_queue, 1)
    self.active_tasks = self.active_tasks + 1

    task(function()
      self.active_tasks = self.active_tasks - 1
      self:process_queue() -- Continue processing the queue
    end)
  end
end

--- @class ActionFn function
---
--- @param fn ActionFn
function TaskQueue:queue_task(fn)
  table.insert(self.task_queue, fn)
  self:process_queue()
end

return TaskQueue
