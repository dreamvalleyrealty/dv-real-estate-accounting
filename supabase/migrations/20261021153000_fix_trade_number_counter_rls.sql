-- The BEFORE INSERT trigger allocates trade numbers by upserting the daily
-- counter. Run that controlled counter operation as the function owner so
-- agent-facing inserts do not fail because the counter table has no client
-- INSERT/UPDATE policy. Keep the function search path pinned.
ALTER FUNCTION public.dv_assign_agent_trade_number() SECURITY DEFINER;
ALTER FUNCTION public.dv_assign_agent_trade_number() SET search_path = public;
