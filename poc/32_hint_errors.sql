-- 32: a hint pg_hint_plan cannot apply or cannot parse is stored as given;
--     the registration does not plan the query, pg_hint_plan reports at planning
-- needs t1 with the index t1_v_idx from scenario 00; the store is left unchanged (ROLLBACK)
-- psql -v opt=on runs it under GPORCA; the default is the Postgres planner
\if :{?opt}
\else
\set opt off
\endif
SET optimizer = :opt;
SET client_min_messages = notice;
SET gg_planman.log_usage = notice;

-- 1. a hint naming a missing index: no warning at registration
BEGIN;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 WHERE v < 1', 'IndexScan(t1 t1_no_such_idx)');
-- without debug_print pg_hint_plan says nothing and the scan is sequential
EXPLAIN (COSTS off) SELECT count(*) FROM t1 WHERE v < 5;
-- with debug_print the hint is listed as used and the list of available indexes is empty
SET LOCAL pg_hint_plan.debug_print = on;
SET LOCAL pg_hint_plan.message_level = notice;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 WHERE v < 5;
ROLLBACK;

-- 2. a hint string with a syntax error: no warning at registration,
--    INFO from pg_hint_plan at every planning, the valid hint applies
BEGIN;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 WHERE v < 1', 'IndexScan(t1 t1_v_idx) BogusHint(t1)');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 WHERE v < 5;
ROLLBACK;

-- the store is unchanged
SELECT count(*) AS bogus_rows FROM gg_planman.plans WHERE hints LIKE '%no_such%' OR hints LIKE '%Bogus%';
