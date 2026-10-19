-- 21: the service check reports a row invalid, with the reason, when an object its
--     query depends on was dropped or replaced, or when the key of the stored text
--     changed; it writes nothing.  check(regenerate => true) registers such rows
--     again, keeping their ids.  No event triggers.
\set QUIET on
SET client_min_messages = warning;
DROP TABLE IF EXISTS t1, t2, kt, kt_new, t1_new, pt, one_t, two_t CASCADE;
DROP FUNCTION IF EXISTS kf(int);
CREATE TABLE t1 (id int, v int, pad text) DISTRIBUTED BY (id);
CREATE TABLE t2 (id int, t1_id int, w int) DISTRIBUTED BY (id);
INSERT INTO t1 SELECT i, i % 10000, repeat('x', 20) FROM generate_series(1, 200000) i;
INSERT INTO t2 SELECT i, (i % 200000) + 1, i % 100 FROM generate_series(1, 400000) i;
CREATE INDEX t1_v_idx ON t1 (v);
CREATE INDEX t2_t1_id_idx ON t2 (t1_id);
CREATE TABLE kt (a int, b int, c int) DISTRIBUTED BY (a);
INSERT INTO kt SELECT i, i, i % 100 FROM generate_series(1, 10000) i;
CREATE INDEX kt_c_idx ON kt (c);
ANALYZE t1;
ANALYZE t2;
ANALYZE kt;
CREATE FUNCTION kf(int) RETURNS int AS 'select $1' LANGUAGE sql IMMUTABLE;
TRUNCATE gg_planman.plans;
RESET client_min_messages;
\set QUIET off
SET gg_planman.log_usage = notice;
SET optimizer = off;

\echo '=== 0. four registered queries, the objects they depend on, and a clean check ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2) Leading((t1 t2))');
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 WHERE v < $1', 'SeqScan(t1)', '{int4}');
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM kt WHERE c < 1', 'SeqScan(kt)');
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM kt WHERE kf(a) < 1', 'SeqScan(kt)');
SELECT id, left(query, 42) AS query, relnames, reloids::text, funcoids::text, paramtypes FROM gg_planman.plans ORDER BY created_at;
SELECT identity, state, reason FROM gg_planman.check();

\echo '=== 1. t1 is recreated by an ETL-style swap: the rows by OID stop applying, the check reports them ==='
CREATE TABLE t1_new AS SELECT * FROM t1 DISTRIBUTED BY (id);
DROP TABLE t1;
ALTER TABLE t1_new RENAME TO t1;
CREATE INDEX t1_v_idx ON t1 (v);
ANALYZE t1;
\echo '--- the row is not applied and the log names the replaced table'
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\echo '--- the check reports the rows with the reason and writes nothing: in a read-only transaction it answers the same'
SELECT identity, state, reason FROM gg_planman.check();
BEGIN READ ONLY;
SELECT identity, state, reason FROM gg_planman.check();
COMMIT;
\echo '--- the log line goes on until the row is regenerated'
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\echo '--- regeneration from the stored text and parameter types; the ids stay'
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
SELECT id, left(query, 42) AS query, reloids::text FROM gg_planman.plans ORDER BY created_at;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
PREPARE p(int) AS SELECT count(*) FROM t1 WHERE v < $1;
EXPLAIN (COSTS off) EXECUTE p(100);
DEALLOCATE p;

\echo '=== 2. a rolled back DROP changes nothing ==='
BEGIN;
DROP TABLE t1;
ROLLBACK;
SELECT identity, state, reason FROM gg_planman.check();
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;

\echo '=== 3. kt loses a column and is recreated: the check reports the recreation, the regeneration stores the new column numbers ==='
ALTER TABLE kt DROP COLUMN b;
CREATE TABLE kt_new AS SELECT * FROM kt DISTRIBUTED BY (a);
DROP TABLE kt;
ALTER TABLE kt_new RENAME TO kt;
CREATE INDEX kt_c_idx ON kt (c);
ANALYZE kt;
SELECT identity, state, reason FROM gg_planman.check();
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
SELECT count(*) AS rows_total, count(*) FILTER (WHERE state <> 'valid') AS rows_invalid FROM gg_planman.check();
EXPLAIN (COSTS off) SELECT count(*) FROM kt WHERE c < 5;

\echo '=== 4. a function: CREATE OR REPLACE keeps the OID and the row, DROP and CREATE replaces the OID ==='
CREATE OR REPLACE FUNCTION kf(int) RETURNS int AS 'select $1 + 0' LANGUAGE sql IMMUTABLE;
SELECT identity, state, reason FROM gg_planman.check();
DROP FUNCTION kf(int);
CREATE FUNCTION kf(int) RETURNS int AS 'select $1' LANGUAGE sql IMMUTABLE;
SELECT identity, state, reason FROM gg_planman.check();
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
EXPLAIN (COSTS off) SELECT count(*) FROM kt WHERE kf(a) < 5;

\echo '=== 5. a table dropped for good: the regeneration reports its rows as still_invalid ==='
DROP TABLE kt;
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
\echo '--- the rows stay in the store as they are, and the next check reports them again'
SELECT identity, state, reason FROM gg_planman.check();

\echo '=== 6. an ALTER that keeps the key leaves the row valid; a column type change is reported as key changed ==='
ALTER TABLE t1 ADD COLUMN note text;
SELECT identity, state, reason FROM gg_planman.check();
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
ALTER TABLE t1 ALTER COLUMN v TYPE bigint;
ANALYZE t1;
\echo '--- the key of the query differs now: the row is not found, the check says key changed'
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SELECT identity, state, reason FROM gg_planman.check();
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;

\echo '=== 7. a partitioned table: adding a partition keeps the key and the row ==='
CREATE TABLE pt (id int, d date, v int) DISTRIBUTED BY (id)
  PARTITION BY RANGE (d) (START ('2026-01-01') END ('2026-04-01') EVERY (INTERVAL '1 month'));
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM pt WHERE v = 1', 'SeqScan(pt)');
ALTER TABLE pt ADD PARTITION START ('2026-04-01') END ('2026-05-01');
SELECT identity, state, reason FROM gg_planman.check();
EXPLAIN (COSTS off) SELECT count(*) FROM pt WHERE v = 7;

\echo '=== 8. one row by its id: check(row_id => ...) examines and regenerates that row only ==='
CREATE TABLE one_t (id int, v int) DISTRIBUTED BY (id);
CREATE TABLE two_t (id int, v int) DISTRIBUTED BY (id);
SELECT id AS one_id FROM gg_planman.register_hints('SELECT count(*) FROM one_t WHERE v = 1', 'SeqScan(one_t)') \gset
SELECT id AS two_id FROM gg_planman.register_hints('SELECT count(*) FROM two_t WHERE v = 1', 'SeqScan(two_t)') \gset
DROP TABLE one_t, two_t;
CREATE TABLE one_t (id int, v int) DISTRIBUTED BY (id);
CREATE TABLE two_t (id int, v int) DISTRIBUTED BY (id);
\echo '--- both tables were recreated; the check by id reports the row over one_t only'
SELECT id, state, reason FROM gg_planman.check(row_id => :one_id);
\echo '--- regeneration of that row only; the id stays, the row over two_t is untouched'
SELECT id, state, reason FROM gg_planman.check(regenerate => true, row_id => :one_id);
SELECT id, reloids::text, (SELECT oid FROM pg_class WHERE relname = relnames[1])::text AS current_oid FROM gg_planman.plans WHERE id IN (:one_id, :two_id) ORDER BY id;
\echo '--- an id without a row is an error'
SELECT id, state, reason FROM gg_planman.check(row_id => 0);
\echo '--- the full check still finds the row over two_t'
SELECT id, state, reason FROM gg_planman.check() WHERE id IN (:one_id, :two_id) ORDER BY id;

\set QUIET on
SET client_min_messages = warning;
DROP TABLE IF EXISTS kt, pt, one_t, two_t CASCADE;
DROP FUNCTION IF EXISTS kf(int);
TRUNCATE gg_planman.plans;
