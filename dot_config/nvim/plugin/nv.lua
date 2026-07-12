-- When this nvim is a project's headless session, wire up the session
-- behaviours: pane handover, detach-instead-of-quit, and the RPC entry points
-- `nv` uses. A normal nvim is unaffected. See lua/nv/init.lua.
require("nv").setup()
