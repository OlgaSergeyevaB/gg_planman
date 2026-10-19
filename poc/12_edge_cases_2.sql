SELECT hints, query FROM gg_planman.plans ORDER BY created_at;

\echo '=== the application sends its own hint comment: its hints are applied, the stored ones are not ==='
TRUNCATE gg_planman.plans;
SET optimizer = off;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2) Leading((t1 t2))');
SET pg_hint_plan.debug_print = on;
SET client_min_messages = log;
/*+ HashJoin(t1 t2) */ EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
RESET client_min_messages;
RESET pg_hint_plan.debug_print;

\echo '=== ORCA falls back to the Postgres planner: are stored hints applied? ==='
SET optimizer = on;
SET optimizer_trace_fallback = on;
TRUNCATE gg_planman.plans;
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 WHERE v < 500 AND EXISTS (SELECT 1 FROM t2 WHERE t2.t1_id = t1.id) GROUP BY ROLLUP (v) ORDER BY 1 LIMIT 5 FOR UPDATE;
SET gg_planman.enabled = on;
