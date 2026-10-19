-- S12/S15: partitioned tables and views
SET gg_planman.log_usage = notice;
TRUNCATE gg_planman.plans;
DROP TABLE IF EXISTS pt CASCADE;
CREATE TABLE pt (id int, d date, v int) DISTRIBUTED BY (id)
  PARTITION BY RANGE (d) (START ('2026-01-01') END ('2026-04-01') EVERY (INTERVAL '1 month'));
INSERT INTO pt SELECT i, date '2026-01-01' + (i % 90), i % 1000 FROM generate_series(1, 90000) i;
CREATE INDEX pt_v_idx ON pt (v);
ANALYZE pt;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM pt WHERE v = 1 AND d >= ''2026-02-01''', 'SeqScan(pt)');
\echo '=== partitioned table, Postgres planner ==='
SET optimizer = off;
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT count(*) FROM pt WHERE v = 7 AND d >= '2026-02-01';
SET gg_planman.enabled = on;
EXPLAIN (COSTS off) SELECT count(*) FROM pt WHERE v = 7 AND d >= '2026-02-01';
\echo '=== partitioned table, ORCA ==='
SET optimizer = on;
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT count(*) FROM pt WHERE v = 7 AND d >= '2026-02-01';
SET gg_planman.enabled = on;
EXPLAIN (COSTS off) SELECT count(*) FROM pt WHERE v = 7 AND d >= '2026-02-01';
\echo '=== view over the join ==='
SET optimizer = off;
CREATE OR REPLACE VIEW v_join AS SELECT t1.v, t2.w FROM t1 JOIN t2 ON t1.id = t2.t1_id;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM v_join WHERE v < 1', 'NestLoop(t1 t2) Leading((t1 t2))');
EXPLAIN (COSTS off) SELECT count(*) FROM v_join WHERE v < 500;
\echo '=== the same join written without the view has another key ==='
SELECT (SELECT key_oid FROM gg_planman.query_key('SELECT count(*) FROM v_join WHERE v < 1')) = (SELECT key_oid FROM gg_planman.query_key('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1')) AS same_key;
\echo '=== CREATE TABLE AS with stored hints ==='
SELECT * FROM gg_planman.register_hints('SELECT t1.id FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2) Leading((t1 t2))');
EXPLAIN (COSTS off) CREATE TABLE ctas_t AS SELECT t1.id FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500 DISTRIBUTED BY (id);
