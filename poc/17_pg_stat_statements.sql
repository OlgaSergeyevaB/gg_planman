-- F21: side effects on pg_stat_statements, which sits below pg_hint_plan in the hook chain
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
TRUNCATE gg_planman.plans;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2) Leading((t1 t2))');
SET optimizer = off;
SELECT pg_stat_statements_reset();
\echo '=== three executions with stored hints, three without ==='
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100;
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 200;
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 300;
SELECT count(*) FROM t2 WHERE w < 3;
SELECT count(*) FROM t2 WHERE w < 4;
SELECT count(*) FROM t2 WHERE w < 5;
\echo '=== pg_stat_statements entries ==='
SELECT queryid, calls, rows, query FROM pg_stat_statements WHERE query ILIKE '%count(*)%' ORDER BY query;
