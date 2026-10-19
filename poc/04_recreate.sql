-- S4: table recreation: the check reports the row invalid and the regeneration brings it back; a hint that names a missing index
SET optimizer = off;
SET gg_planman.log_usage = notice;

\echo '=== before recreation ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;

\echo '=== recreate t1 as ETL does: new table, same name, same index name ==='
CREATE TABLE t1_new (id int, v int, pad text) DISTRIBUTED BY (id);
INSERT INTO t1_new SELECT * FROM t1;
DROP TABLE t1;
ALTER TABLE t1_new RENAME TO t1;
CREATE INDEX t1_v_idx ON t1 (v);
ANALYZE t1;

\echo '=== after recreation: the row still carries the old reloids and is not applied ==='
SELECT hints, reloids::text, (SELECT array_agg(oid ORDER BY relname)::text FROM pg_class WHERE relname IN ('t1','t2')) AS current_oids FROM gg_planman.plans;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;

\echo '=== the service check reports the row invalid with the reason and writes nothing ==='
SELECT identity, state, reason FROM gg_planman.check();

\echo '=== regeneration from the stored text ==='
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;

\echo '=== index recreated under another name: hint names an index that no longer exists ==='
DROP INDEX t1_v_idx;
CREATE INDEX t1_v_idx_2026 ON t1 (v);
SET pg_hint_plan.debug_print = on;
SET client_min_messages = log;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
RESET client_min_messages;
RESET pg_hint_plan.debug_print;
DROP INDEX t1_v_idx_2026;
CREATE INDEX t1_v_idx ON t1 (v);
