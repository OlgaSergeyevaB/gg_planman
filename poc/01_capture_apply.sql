-- S1/S2: capture hints from a comment, apply them to the same query with other constants
SET client_min_messages = notice;
SET gg_planman.log_usage = notice;
TRUNCATE gg_planman.plans;

\echo '=== Postgres planner, no hints ==='
SET optimizer = off;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100;

\echo '=== capture: DBA runs the query once with a hint comment ==='
SET gg_planman.write_mode = on;
/*+ NestLoop(t1 t2) IndexScan(t1 t1_v_idx) Leading((t1 t2)) */
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100;
SET gg_planman.write_mode = off;
SELECT key_base, key_oid, enabled, hints, relnames, reloids::text FROM gg_planman.plans;

\echo '=== Postgres planner, same query, other constant, no comment ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;

\echo '=== results are the same with and without gg_planman ==='
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SET gg_planman.enabled = off;
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SET gg_planman.enabled = on;

\echo '=== ORCA, no gg_planman ==='
SET optimizer = on;
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SET gg_planman.enabled = on;

\echo '=== ORCA with stored hints ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
