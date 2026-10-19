-- 22: an EXPLAIN in write mode stores nothing: the hints are tried, not stored (F29 closed 2026-10-16
--     by refusing the EXPLAIN); a statement the registration would refuse is not captured either
\set QUIET on
SET client_min_messages = warning;
TRUNCATE gg_planman.plans;
DROP TABLE IF EXISTS cap_t, cap_t_new, cap_t2;
CREATE TABLE cap_t (id int, v int) DISTRIBUTED BY (id);
INSERT INTO cap_t SELECT i, i % 100 FROM generate_series(1, 10000) i;
CREATE INDEX cap_t_v_idx ON cap_t (v);
ANALYZE cap_t;
RESET client_min_messages;
\set QUIET off
SET optimizer = off;
SET gg_planman.log_usage = notice;
SET gg_planman.write_mode = on;

\echo '=== 1. EXPLAIN with a hint comment in write mode: the plan shows the hints, nothing is stored, the warning says how to store ==='
/*+ SeqScan(cap_t) */ EXPLAIN (COSTS off) SELECT count(*) FROM cap_t WHERE v < 1;
SELECT count(*) AS stored_rows FROM gg_planman.plans;

\echo '=== 2. the same for EXPLAIN ANALYZE VERBOSE and for the comment after the option list ==='
\o /dev/null
/*+ IndexScan(cap_t cap_t_v_idx) */ EXPLAIN ANALYZE VERBOSE SELECT count(*) FROM cap_t WHERE v < 2;
\o
EXPLAIN (COSTS off, FORMAT text) /*+ BitmapScan(cap_t cap_t_v_idx) */ SELECT count(*) FROM cap_t WHERE v < 3;
SELECT count(*) AS stored_rows FROM gg_planman.plans;

\echo '=== 3. running the statement once stores it; the row applies, the check finds it valid, and after a recreation it regenerates ==='
/*+ SeqScan(cap_t) */ SELECT count(*) FROM cap_t WHERE v < 1;
SELECT hints, query FROM gg_planman.plans;
SET gg_planman.write_mode = off;
EXPLAIN (COSTS off) SELECT count(*) FROM cap_t WHERE v < 1;
SELECT identity, state, reason FROM gg_planman.check();
\set QUIET on
SET client_min_messages = warning;
CREATE TABLE cap_t_new AS SELECT * FROM cap_t DISTRIBUTED BY (id);
DROP TABLE cap_t;
ALTER TABLE cap_t_new RENAME TO cap_t;
CREATE INDEX cap_t_v_idx ON cap_t (v);
ANALYZE cap_t;
RESET client_min_messages;
\set QUIET off
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
EXPLAIN (COSTS off) SELECT count(*) FROM cap_t WHERE v < 1;

\echo '=== 4. the registration refuses an EXPLAIN text with a hint; the statement inside it is registered ==='
SELECT * FROM gg_planman.register_hints('EXPLAIN SELECT count(*) FROM cap_t WHERE v < 1', 'IndexScan(cap_t cap_t_v_idx)');
SELECT id, slots FROM gg_planman.register_hints('SELECT count(*) FROM cap_t WHERE v < 1', 'IndexScan(cap_t cap_t_v_idx)');
SELECT hints, query FROM gg_planman.plans;

\echo '=== 5. a statement the registration would refuse is not captured: EXPLAIN EXECUTE, CREATE TABLE AS ==='
SET gg_planman.write_mode = on;
PREPARE p(int) AS SELECT count(*) FROM cap_t WHERE v < $1;
/*+ SeqScan(cap_t) */ EXPLAIN (COSTS off) EXECUTE p(1);
/*+ SeqScan(cap_t) */ CREATE TABLE cap_t2 AS SELECT count(*) AS n FROM cap_t WHERE v < 1 DISTRIBUTED BY (n);
SET gg_planman.write_mode = off;
SELECT hints, query FROM gg_planman.plans;

\set QUIET on
SET client_min_messages = warning;
DEALLOCATE p;
DROP TABLE IF EXISTS cap_t, cap_t2;
TRUNCATE gg_planman.plans;
