-- S7: stored hints do not cost direct dispatch
SET gg_planman.log_usage = notice;
SELECT * FROM gg_planman.register_hints('SELECT * FROM t1 WHERE id = 5 AND v < 10', 'IndexScan(t1 t1_v_idx)');
\echo '=== Postgres planner ==='
SET optimizer = off;
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 123 AND v < 50;
SET gg_planman.enabled = on;
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 123 AND v < 50;
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 77777 AND v < 50;
\echo '=== ORCA ==='
SET optimizer = on;
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 123 AND v < 50;
SET gg_planman.enabled = on;
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 123 AND v < 50;
