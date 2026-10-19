-- S13: which stored hints ORCA honours, and Set(optimizer off)
SET optimizer = on;
SET gg_planman.log_usage = notice;
TRUNCATE gg_planman.plans;
\echo '=== ORCA, no hints ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\echo '=== join method NestLoop ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2)');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\echo '=== scan method SeqScan(t1) ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'SeqScan(t1)');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\echo '=== join order Leading((t2 t1)) ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'Leading((t2 t1))');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\echo '=== Set(optimizer off) with NestLoop: planned by the Postgres planner ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'Set(optimizer off) NestLoop(t1 t2) Leading((t1 t2))');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SHOW optimizer;
