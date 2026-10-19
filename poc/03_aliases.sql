-- S5: aliases are part of the key, because pg_hint_plan addresses relations by alias
SET optimizer = off;
SET gg_planman.log_usage = notice;
SET pg_hint_plan.debug_print = on;
SET client_min_messages = log;
\echo '=== stored hints mention t1 t2; query uses aliases a b: another key, nothing applied ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1 a JOIN t2 b ON a.id = b.t1_id WHERE a.v < 500;
\echo '=== hints registered for the aliased form ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 a JOIN t2 b ON a.id = b.t1_id WHERE a.v < 1', 'NestLoop(a b) Leading((a b))');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 a JOIN t2 b ON a.id = b.t1_id WHERE a.v < 500;
RESET client_min_messages;
