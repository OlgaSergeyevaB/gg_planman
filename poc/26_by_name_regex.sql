-- 26: tables matched by name or by a regular expression instead of OID: by_name and by_regex of gg_planman.register_hints()
-- psql -v opt=on runs it under GPORCA; the default is the Postgres planner
\if :{?opt}
\else
\set opt off
\endif
\set QUIET on
SET client_min_messages = warning;
DROP TABLE IF EXISTS bn_dim, bn_stage, bn_stage_new, data_2025, data_2026 CASCADE;
CREATE TABLE bn_dim (id int, v int) DISTRIBUTED BY (id);
CREATE TABLE bn_stage (id int, v int) DISTRIBUTED BY (id);
CREATE TABLE data_2025 (id int, v int) DISTRIBUTED BY (id);
CREATE TABLE data_2026 (id int, v int) DISTRIBUTED BY (id);
INSERT INTO bn_dim SELECT i, i % 1000 FROM generate_series(1, 50000) i;
INSERT INTO bn_stage SELECT i, i % 1000 FROM generate_series(1, 50000) i;
INSERT INTO data_2025 SELECT i, i % 1000 FROM generate_series(1, 50000) i;
INSERT INTO data_2026 SELECT i, i % 1000 FROM generate_series(1, 50000) i;
CREATE INDEX bn_stage_v_idx ON bn_stage (v);
CREATE INDEX data_2025_v_idx ON data_2025 (v);
CREATE INDEX data_2026_v_idx ON data_2026 (v);
ANALYZE bn_dim;
ANALYZE bn_stage;
ANALYZE data_2025;
ANALYZE data_2026;
TRUNCATE gg_planman.plans;
RESET client_min_messages;
\set QUIET off
\pset footer off
SET gg_planman.log_usage = notice;
SET optimizer = :opt;

\echo '=== 1. a temporary table that nothing covers is refused ==='
CREATE TEMP TABLE bn_tmp AS SELECT * FROM bn_dim WHERE v < 100 DISTRIBUTED BY (id);
CREATE INDEX bn_tmp_v_idx ON bn_tmp (v);
ANALYZE bn_tmp;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM bn_tmp t JOIN bn_dim d ON d.id = t.id WHERE t.v < 5', 'SeqScan(t)');

\echo '=== 2. pg_temp.bn_tmp in by_name: that slot is matched by schema and name, bn_dim by OID, and the row has no key_oid ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM bn_tmp t JOIN bn_dim d ON d.id = t.id WHERE t.v < 5', 'SeqScan(t)', by_name => '{pg_temp.bn_tmp}');
SELECT key_oid, relschemas, relnames, reloids::text, rules, n_oid, n_name, n_regex, identity FROM gg_planman.plans;

\echo '=== 3. another session with its own temporary table gets the hints ==='
\c
SET gg_planman.log_usage = notice;
SET optimizer = :opt;
CREATE TEMP TABLE bn_tmp AS SELECT * FROM bn_dim WHERE v < 200 DISTRIBUTED BY (id);
CREATE INDEX bn_tmp_v_idx ON bn_tmp (v);
ANALYZE bn_tmp;
EXPLAIN (COSTS off) SELECT count(*) FROM bn_tmp t JOIN bn_dim d ON d.id = t.id WHERE t.v < 9;

\echo '=== 4. a table listed in by_name has to be read by the query; a pattern that matches nothing is only reported ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM bn_dim WHERE v < 5', 'SeqScan(bn_dim)', by_name => '{bn_stage}');
SELECT * FROM gg_planman.query_key('SELECT count(*) FROM bn_dim WHERE v < 5', by_regex => '{^public\\.nothing}');

\echo '=== 5. a permanent table in by_name: the row outlives the recreation of the table, with no regeneration ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM bn_stage s JOIN bn_dim d ON d.id = s.id WHERE s.v < 5', 'SeqScan(s)', by_name => '{bn_stage}');
CREATE TABLE bn_stage_new AS SELECT * FROM bn_stage DISTRIBUTED BY (id);
DROP TABLE bn_stage;
ALTER TABLE bn_stage_new RENAME TO bn_stage;
CREATE INDEX bn_stage_v_idx ON bn_stage (v);
ANALYZE bn_stage;
SELECT hints, rules FROM gg_planman.plans WHERE 'bn_stage' = ANY(relnames);
EXPLAIN (COSTS off) SELECT count(*) FROM bn_stage s JOIN bn_dim d ON d.id = s.id WHERE s.v < 9;

\echo '=== 6. a row matched by OID beside it: found first while the table is the same, not found after the next recreation, when the row by name takes over and the check marks it ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM bn_stage s JOIN bn_dim d ON d.id = s.id WHERE s.v < 5', 'IndexScan(s bn_stage_v_idx)');
SELECT key_oid IS NOT NULL AS by_oid, hints, rules FROM gg_planman.plans WHERE 'bn_stage' = ANY(relnames) ORDER BY created_at;
EXPLAIN (COSTS off) SELECT count(*) FROM bn_stage s JOIN bn_dim d ON d.id = s.id WHERE s.v < 9;
CREATE TABLE bn_stage_new AS SELECT * FROM bn_stage DISTRIBUTED BY (id);
DROP TABLE bn_stage;
ALTER TABLE bn_stage_new RENAME TO bn_stage;
CREATE INDEX bn_stage_v_idx ON bn_stage (v);
ANALYZE bn_stage;
SELECT key_oid IS NOT NULL AS by_oid, hints FROM gg_planman.plans WHERE 'bn_stage' = ANY(relnames) ORDER BY created_at;
EXPLAIN (COSTS off) SELECT count(*) FROM bn_stage s JOIN bn_dim d ON d.id = s.id WHERE s.v < 9;
SELECT identity, state, reason FROM gg_planman.check();

\echo '=== 7. by_regex: a row registered over data_2026 serves data_2025 as well ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM data_2026 d WHERE d.v < 5', 'SeqScan(d)', by_regex => '{^public\\.data_}');
SELECT key_oid, relnames, rules, patterns FROM gg_planman.plans WHERE 'data_2026' = ANY(relnames);
EXPLAIN (COSTS off) SELECT count(*) FROM data_2025 d WHERE d.v < 9;
EXPLAIN (COSTS off) SELECT count(*) FROM data_2026 d WHERE d.v < 9;

\echo '=== 8. the most specific row wins: the exact name of data_2026 beats the pattern, and a row by OID beats both ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM data_2026 d WHERE d.v < 5', 'IndexScan(d data_2026_v_idx)', by_name => '{data_2026}');
EXPLAIN (COSTS off) SELECT count(*) FROM data_2026 d WHERE d.v < 9;
EXPLAIN (COSTS off) SELECT count(*) FROM data_2025 d WHERE d.v < 9;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM data_2026 d WHERE d.v < 5', 'BitmapScan(d data_2026_v_idx)');
EXPLAIN (COSTS off) SELECT count(*) FROM data_2026 d WHERE d.v < 9;
SELECT key_oid IS NOT NULL AS by_oid, hints, rules, n_oid, n_name, n_regex FROM gg_planman.plans WHERE 'data_2026' = ANY(relnames) ORDER BY created_at;

\echo '=== 9. a selector in by_name and a pattern in by_regex on one query: what the row keeps ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM data_2026 d JOIN bn_dim m ON m.id = d.id JOIN bn_tmp t ON t.id = d.id WHERE d.v < 5', 'Leading((t (d m))) HashJoin(d m) SeqScan(t)', by_name => '{~^pg_temp\\.}', by_regex => '{^public\\.data_}');
SELECT key_oid, relschemas, relnames, reloids::text, rules, patterns, n_oid, n_name, n_regex, identity, by_name, by_regex FROM gg_planman.plans WHERE 'bn_tmp' = ANY(relnames) AND 'data_2026' = ANY(relnames);
EXPLAIN (COSTS off) SELECT count(*) FROM data_2025 d JOIN bn_dim m ON m.id = d.id JOIN bn_tmp t ON t.id = d.id WHERE d.v < 9;

\echo '=== 10. the slot by OID of that row: bn_dim is recreated, the check marks the row, and the regeneration keeps by_name and by_regex ==='
CREATE TABLE bn_dim_new AS SELECT * FROM bn_dim DISTRIBUTED BY (id);
DROP TABLE bn_dim;
ALTER TABLE bn_dim_new RENAME TO bn_dim;
ANALYZE bn_dim;
SELECT identity, state, reason FROM gg_planman.check();
EXPLAIN (COSTS off) SELECT count(*) FROM data_2025 d JOIN bn_dim m ON m.id = d.id JOIN bn_tmp t ON t.id = d.id WHERE d.v < 9;
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
SELECT hints, rules, by_name, by_regex FROM gg_planman.plans WHERE 'bn_tmp' = ANY(relnames) AND 'data_2026' = ANY(relnames);
EXPLAIN (COSTS off) SELECT count(*) FROM data_2025 d JOIN bn_dim m ON m.id = d.id JOIN bn_tmp t ON t.id = d.id WHERE d.v < 9;

\echo '=== 11. capture from a hint comment stores a query over a temporary table by schema and name ==='
CREATE TEMP TABLE bn_tmp2 AS SELECT * FROM bn_dim WHERE v < 100 DISTRIBUTED BY (id);
SET gg_planman.write_mode = on;
/*+ SeqScan(bn_tmp2) */ SELECT count(*) FROM bn_tmp2 WHERE v < 5;
SET gg_planman.write_mode = off;
SELECT hints, rules, by_name, key_oid FROM gg_planman.plans WHERE 'bn_tmp2' = ANY(relnames);

\echo '=== 12. the DBA switches a row off by its id, found through identity ==='
SELECT id, identity, enabled FROM gg_planman.plans WHERE 'data_2026' = ANY(relnames) ORDER BY created_at;
UPDATE gg_planman.plans SET enabled = false WHERE id = (SELECT id FROM gg_planman.plans WHERE identity = 'regex:^public\.data_');
SELECT id, enabled, hints, rules FROM gg_planman.plans WHERE 'data_2026' = ANY(relnames) ORDER BY created_at;
EXPLAIN (COSTS off) SELECT count(*) FROM data_2025 d WHERE d.v < 9;

\echo '=== 13. a table matched by name is recreated with another column order: key_base changes and nothing reports it ==='
CREATE TABLE bn_stage_new AS SELECT v, id FROM bn_stage DISTRIBUTED BY (id);
DROP TABLE bn_stage;
ALTER TABLE bn_stage_new RENAME TO bn_stage;
CREATE INDEX bn_stage_v_idx ON bn_stage (v);
ANALYZE bn_stage;
SELECT hints, rules FROM gg_planman.plans WHERE 'bn_stage' = ANY(relnames) ORDER BY created_at;
EXPLAIN (COSTS off) SELECT count(*) FROM bn_stage s JOIN bn_dim d ON d.id = s.id WHERE s.v < 9;

\set QUIET on
DROP TABLE bn_dim, bn_stage, data_2025, data_2026;
TRUNCATE gg_planman.plans;
