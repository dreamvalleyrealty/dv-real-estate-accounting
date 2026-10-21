-- Allow authenticated trade submission to maintain today's counter only.
-- The counter is date-scoped to Toronto to match trade-number generation.
DROP POLICY IF EXISTS "authenticated_trade_counter_insert_today" ON public.dv_agent_trade_number_counters;
DROP POLICY IF EXISTS "authenticated_trade_counter_update_today" ON public.dv_agent_trade_number_counters;
CREATE POLICY "authenticated_trade_counter_insert_today"
ON public.dv_agent_trade_number_counters
FOR INSERT TO authenticated
WITH CHECK (number_prefix = 'TR' || to_char(timezone('America/Toronto', now()), 'YYMMDD'));
CREATE POLICY "authenticated_trade_counter_update_today"
ON public.dv_agent_trade_number_counters
FOR UPDATE TO authenticated
USING (number_prefix = 'TR' || to_char(timezone('America/Toronto', now()), 'YYMMDD'))
WITH CHECK (number_prefix = 'TR' || to_char(timezone('America/Toronto', now()), 'YYMMDD'));
