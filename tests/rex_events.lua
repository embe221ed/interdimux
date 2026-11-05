-- Native live refresh coalescing; no clock sleeps, server, or UI mutation.
local root = arg[1] or "."
local events = dofile(root .. "/integrations/rex_events.lua")
local timers, calls, errors = {}, {}, {}
local args = { picker_block_id = "picker" }
local watcher, fail = nil, false
local rx = {
  after = function(delay, callback)
    assert(delay == .25, "live refresh is capped at four event batches per second")
    local timer = { callback = callback, cancelled = false }
    function timer:cancel() self.cancelled = true end
    timers[#timers + 1] = timer
    return timer
  end,
  log = function(_, message) errors[#errors + 1] = message end,
}
local snapshot = { views = { s = { revision = 10 } } }
watcher = events.new(rx, args, function(changes)
  calls[#calls + 1] = changes
  if fail then error("temporary collector failure") end
  watcher.update(snapshot)
end)
local function emit(name, payload) watcher.changed(name, {}, payload) end
emit("session_view_changed", { session_id = "s", revision = 11 })
assert(#timers == 0, "opening uses its initial snapshot, never an event-triggered race before readiness")
watcher.update(snapshot)
for _, revision in ipairs({ 9, 10 }) do emit("session_view_changed", { session_id = "s", revision = revision }) end
emit("terminal.process_changed", { block_id = "picker" })
emit("terminal.title_changed", { block_id = "picker" })
emit("terminal.clipboard_written", { block_id = "b1" })
emit("block_event", { block_id = "b1" })
assert(#timers == 0 and #calls == 0, "stale revisions, picker changes, and raw output do not refresh")
for _ = 1, 100 do emit("terminal.program_status_changed", { session_id = "s", block_id = "b1" }) end
emit("terminal.progress_report", { session_id = "s", block_id = "b2" })
emit("session_view_changed", { session_id = "s", revision = 11 })
assert(#timers == 1 and #calls == 0, "one hundred native changes schedule only one delayed collection")
snapshot.views.s.revision = 11
timers[1].callback()
assert(#calls == 1 and calls[1].blocks.b1 and calls[1].blocks.b2 and calls[1].sessions.s)
assert(#timers == 1, "an idle picker creates no recurring refresh timer")
emit("session_view_changed", { session_id = "s", revision = 10 })
assert(#timers == 1, "out-of-order layout events cannot regress the published snapshot")
print("passed: native event filtering, revision ordering, burst coalescing, and zero idle refreshes")

emit("terminal.pwd_changed", { session_id = "s", block_id = "b3" })
local superseded = timers[#timers]
watcher.update(snapshot)
assert(superseded.cancelled, "an explicit action/refresh snapshot cancels its redundant pending update")
assert(#calls == 1)
emit("session_created", { session = { session_id = "new" } })
timers[#timers].callback()
assert(calls[#calls].sessions.new, "new sessions invalidate their view without a block event")
emit("session_destroyed", { session_id = "gone" })
emit("block_closed", { session_id = "s", block_id = "b4" })
timers[#timers].callback()
assert(calls[#calls].sessions.gone and calls[#calls].sessions.s)
print("passed: manual refresh supersedes pending work and topology changes invalidate affected sessions")

fail = true
emit("terminal.title_changed", { block_id = "retry" })
local before = #timers
timers[#timers].callback()
assert(#errors == 1 and #timers == before, "collector failure keeps the old frame without an idle retry loop")
fail = false
emit("terminal.program_status_removed", { block_id = "next" })
timers[#timers].callback()
assert(calls[#calls].blocks.retry and calls[#calls].blocks.next, "the next event retries every uncollected change")
emit("terminal.process_changed", { block_id = "b5" })
local pending, collected = timers[#timers], #calls
watcher.cancel()
assert(pending.cancelled)
pending.callback()
emit("session_created", { session = { session_id = "too-late" } })
assert(#calls == collected, "close cancels queued and future refreshes")
print("passed: recoverable collector errors and cancellation of queued native updates")
