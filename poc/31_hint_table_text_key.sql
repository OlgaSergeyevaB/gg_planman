-- 31: the hint table of pg_hint_plan keys hints by the normalized text of the query.
--     A row is found for the same text with another constant, and missed when the
--     text differs in whitespace, a comment, case, schema qualification or an
--     EXPLAIN prefix.  Facts behind option 3 of the ADR.  gg_planman stays out
--     of the way: it is switched off for the session.
\set QUIET on
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_hint_plan;
DELETE FROM hint_plan.hints;
RESET client_min_messages;
\set QUIET off
\pset footer off

SET gg_planman.enabled = off;
SET optimizer = off;
SET pg_hint_plan.enable_hint_table = on;
SET pg_hint_plan.debug_print = detailed;
SET pg_hint_plan.message_level = notice;

\echo '=== 0. one row: the text as the client sends it, constants replaced by ?, any application ==='
INSERT INTO hint_plan.hints (norm_query_string, application_name, hints)
VALUES ('EXPLAIN (COSTS off) SELECT count(*) FROM t1 WHERE v < ?;', '', 'SeqScan(t1)');
SELECT * FROM hint_plan.hints;

\echo '=== 1. the same text with another constant: found, the plan is a sequential scan ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1 WHERE v < 5000;

\echo '=== 2. two spaces after SELECT: not found ==='
EXPLAIN (COSTS off) SELECT  count(*) FROM t1 WHERE v < 100;

\echo '=== 3. a comment inside the text: not found ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1 /* report 7 */ WHERE v < 100;

\echo '=== 4. a line break instead of a space: not found ==='
EXPLAIN (COSTS off) SELECT count(*) FROM t1
WHERE v < 100;

\echo '=== 5. lower case: not found ==='
EXPLAIN (COSTS off) select count(*) from t1 where v < 100;

\echo '=== 6. the table qualified with its schema: not found ==='
EXPLAIN (COSTS off) SELECT count(*) FROM public.t1 WHERE v < 100;

\echo '=== 7. the plain SELECT does not match the row stored with the EXPLAIN prefix ==='
SELECT count(*) FROM t1 WHERE v < 100;

\echo '=== 8. the same query shape in gg_planman: one row serves every spelling ==='
SET pg_hint_plan.enable_hint_table = off;
SET pg_hint_plan.debug_print = off;
SET gg_planman.enabled = on;
SET gg_planman.log_usage = notice;
SELECT id FROM gg_planman.register_hints('SELECT count(*) FROM t1 WHERE v < 1', 'SeqScan(t1)') \gset
EXPLAIN (COSTS off) SELECT  count(*) FROM t1 /* report 7 */ WHERE v < 100;
EXPLAIN (COSTS off) select count(*) from public.t1
where v < 5000;
DELETE FROM gg_planman.plans WHERE id = :id;

\set QUIET on
SET client_min_messages = warning;
DELETE FROM hint_plan.hints;
RESET pg_hint_plan.enable_hint_table;
RESET pg_hint_plan.debug_print;
RESET pg_hint_plan.message_level;
DROP EXTENSION pg_hint_plan;
