\set ON_ERROR_STOP on
DROP TABLE IF EXISTS t1, t2 CASCADE;
CREATE TABLE t1 (id int, v int, pad text) DISTRIBUTED BY (id);
CREATE TABLE t2 (id int, t1_id int, w int) DISTRIBUTED BY (id);
INSERT INTO t1 SELECT i, i % 10000, repeat('x', 20) FROM generate_series(1, 200000) i;
INSERT INTO t2 SELECT i, (i % 200000) + 1, i % 100 FROM generate_series(1, 400000) i;
CREATE INDEX t1_v_idx ON t1 (v);
CREATE INDEX t2_t1_id_idx ON t2 (t1_id);
ANALYZE t1;
ANALYZE t2;
TRUNCATE gg_planman.plans;
