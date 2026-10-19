-- S10: queries inside PL/pgSQL functions
SET optimizer = off;
SET gg_planman.log_usage = notice;
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_nested_statements = on;
SET auto_explain.log_analyze = off;
SET client_min_messages = log;
TRUNCATE gg_planman.plans;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1', 'NestLoop(t1 t2) Leading((t1 t2))', '{int4}');
CREATE OR REPLACE FUNCTION f_cnt(x int) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE r bigint;
BEGIN
  SELECT count(*) INTO r FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < x;
  RETURN r;
END $$;
\echo '=== function call: look for the nested plan in the LOG lines ==='
SELECT f_cnt(500);
