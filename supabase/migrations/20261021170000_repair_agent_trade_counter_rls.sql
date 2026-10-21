-- Repair RLS blocking trade-number counter allocation from authenticated trade flows.
DROP POLICY IF EXISTS authenticated_trade_counter_insert_today ON public.dv_agent_trade_number_counters;
DROP POLICY IF EXISTS authenticated_trade_counter_update_today ON public.dv_agent_trade_number_counters;

CREATE POLICY authenticated_trade_counter_insert_valid_prefix
ON public.dv_agent_trade_number_counters
FOR INSERT TO authenticated
WITH CHECK (number_prefix ~ '^TR[0-9]{6}$' AND last_number >= 1);

CREATE POLICY authenticated_trade_counter_update_valid_prefix
ON public.dv_agent_trade_number_counters
FOR UPDATE TO authenticated
USING (number_prefix ~ '^TR[0-9]{6}$')
WITH CHECK (number_prefix ~ '^TR[0-9]{6}$' AND last_number >= 1);

CREATE POLICY authenticated_trade_counter_select_valid_prefix
ON public.dv_agent_trade_number_counters
FOR SELECT TO authenticated
USING (number_prefix ~ '^TR[0-9]{6}$');
