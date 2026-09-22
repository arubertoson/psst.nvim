# Development guidelines

- Optimize for brief contextual inquiries made without leaving the editing flow.
- Treat harness adapters as infrastructure, not the product model.
- Add adapter capabilities only when a real harness integration requires them.
- Validate Neovim state, process output, configuration, and asynchronous callbacks at
  their boundaries; trust established internal contracts.
- Keep volatile windows, buffers, timers, processes, and extmarks owned by their
  active session.
- Fail visibly on invariant violations and guard genuine asynchronous races.
- Test observable editor workflows and lifecycle guarantees.
- Format Lua with StyLua and run `just check` before committing.
