-- S11, session 1: hints for a temporary table, which the DBA lists in by_name
SET optimizer = off;
SET gg_planman.log_usage = notice;
CREATE TEMP TABLE tt AS SELECT * FROM t1 WHERE v < 2000 DISTRIBUTED BY (id);
CREATE INDEX tt_v_idx ON tt (v);
ANALYZE tt;
\echo '=== capture from a hint comment stores a temporary table by schema and name, with the selector kept in by_name ==='
SET gg_planman.write_mode = on;
/*+ SeqScan(tt) */ SELECT count(*) FROM tt WHERE v = 10;
SET gg_planman.write_mode = off;
SELECT hints, relschemas, relnames, rules, by_name, key_oid FROM gg_planman.plans WHERE 'tt' = ANY(relnames);
\echo '=== an explicit registration with the table in by_name replaces the captured row: same key_base, same rules ===' 
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM tt WHERE v = 10', 'SeqScan(tt)', by_name => '{pg_temp.tt}');
SELECT hints, relschemas, relnames, rules, key_oid FROM gg_planman.plans WHERE 'tt' = ANY(relnames);
