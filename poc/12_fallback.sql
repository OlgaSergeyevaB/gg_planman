SET gg_planman.log_usage = notice;
SET optimizer = on;
SET optimizer_trace_fallback = on;
TRUNCATE gg_planman.plans;
\echo '=== query that ORCA cannot plan: TABLESAMPLE ==='
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 TABLESAMPLE SYSTEM (50) JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SET gg_planman.enabled = on;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 TABLESAMPLE SYSTEM (50) JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2) Leading((t1 t2))');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 TABLESAMPLE SYSTEM (50) JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
