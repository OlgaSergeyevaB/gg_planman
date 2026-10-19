-- S14: disabling hints by the row id, cached plans without invalidation by the extension, direct dispatch in the Postgres planner
SET optimizer = off;
SET gg_planman.log_usage = notice;
TRUNCATE gg_planman.plans;
\echo '=== Postgres planner direct dispatch with and without stored hints ==='
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 42;
SET gg_planman.enabled = on;
SELECT * FROM gg_planman.register_hints('SELECT * FROM t1 WHERE id = 1', 'IndexScan(t1)');
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 42;
\echo '=== disabling the row takes effect for the next planning ==='
UPDATE gg_planman.plans SET enabled = false WHERE id = (SELECT id FROM gg_planman.plans WHERE query = 'SELECT * FROM t1 WHERE id = 1');
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 42;
UPDATE gg_planman.plans SET enabled = true WHERE id = (SELECT id FROM gg_planman.plans WHERE query = 'SELECT * FROM t1 WHERE id = 1');
\echo '=== cached generic plan: DDL on a referenced table forces replanning ==='
SET plan_cache_mode = force_generic_plan;
PREPARE q(int) AS SELECT * FROM t1 WHERE id = $1;
EXPLAIN (COSTS off) EXECUTE q(42);
SELECT * FROM gg_planman.register_hints('SELECT * FROM t1 WHERE id = $1', 'IndexScan(t1)', '{int4}');
EXPLAIN (COSTS off) EXECUTE q(42);
ALTER TABLE t1 ALTER COLUMN pad SET STATISTICS 50;
EXPLAIN (COSTS off) EXECUTE q(42);
DEALLOCATE q;
RESET plan_cache_mode;
