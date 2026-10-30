-- Keep March 2026 Market Watch extraction out of agent-facing queries
-- until the source PDF and all extracted rows have been revalidated.
DROP POLICY IF EXISTS "Agents read approved market stat rows" ON public.dv_property_market_stat_rows;
CREATE POLICY "Agents read approved market stat rows"
ON public.dv_property_market_stat_rows
FOR SELECT
USING (
  review_status = 'APPROVED'
  AND EXISTS (
    SELECT 1 FROM public.dv_property_market_reports r
    WHERE r.id = dv_property_market_stat_rows.market_report_id
      AND r.status = 'APPROVED'
      AND r.report_period <> DATE '2026-03-01'
  )
);
