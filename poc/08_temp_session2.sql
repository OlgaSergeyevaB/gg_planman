-- S11, session 2: another session with its own temporary table of the same name
SET optimizer = off;
SET gg_planman.log_usage = notice;
CREATE TEMP TABLE tt AS SELECT * FROM t1 WHERE v < 2000 DISTRIBUTED BY (id);
CREATE INDEX tt_v_idx ON tt (v);
ANALYZE tt;
EXPLAIN (COSTS off) SELECT count(*) FROM tt WHERE v = 20;
