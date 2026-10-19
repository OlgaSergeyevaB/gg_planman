-- Planning-only cost per query: EXPLAIN in a loop, no execution and no dispatch
CREATE OR REPLACE FUNCTION plan_loop(n int, q text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; r record;
BEGIN
  t0 := clock_timestamp();
  FOR i IN 1..n LOOP
    FOR r IN EXECUTE 'EXPLAIN ' || replace(q, '$i', i::text) LOOP END LOOP;
  END LOOP;
  RETURN round((extract(epoch FROM clock_timestamp() - t0) * 1e6 / n)::numeric, 1);
END $$;
\pset footer off
SET gg_planman.log_usage = none;
SET optimizer = off;
SELECT 'warmup' AS config, plan_loop(2000, 'SELECT pad FROM t1 WHERE id = $i') AS us_per_plan;
