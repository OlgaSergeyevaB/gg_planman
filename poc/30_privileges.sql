-- 30: who can change the plan store (R8 of the StRS): only superusers
\set QUIET on
SET client_min_messages = warning;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN CREATE ROLE app_user LOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA public TO app_user;
DROP TABLE IF EXISTS priv_t;
CREATE TABLE priv_t (id int, v int) DISTRIBUTED BY (id);
GRANT SELECT ON priv_t TO app_user;
TRUNCATE gg_planman.plans;
RESET client_min_messages;
\set QUIET off
\pset footer off

SELECT rolname, rolsuper FROM pg_roles WHERE rolname IN (current_user, 'app_user') ORDER BY rolsuper;
SET ROLE app_user;

\echo '=== 1. a role that is not a superuser: register_hints refuses, UPDATE of the store is denied ==='
SELECT gg_planman.register_hints('SELECT count(*) FROM priv_t WHERE v < 1', 'SeqScan(priv_t)');
UPDATE gg_planman.plans SET enabled = false;

\echo '=== 2. write mode, switching the extension off, the table itself, the check without SELECT on the store and the regeneration refuse as well ==='
SET gg_planman.write_mode = on;
SET gg_planman.enabled = off;
SELECT count(*) FROM gg_planman.plans;
DELETE FROM gg_planman.plans;
SELECT * FROM gg_planman.check();
SELECT * FROM gg_planman.check(regenerate => true);

\echo '=== 2a. query_key is open to any role: the keys and the slots of a text, nothing is stored ==='
SELECT key_base IS NOT NULL AS has_key_base, key_oid IS NOT NULL AS has_key_oid, slots FROM gg_planman.query_key('SELECT count(*) FROM priv_t WHERE v < 1');
RESET ROLE;
SELECT count(*) AS rows_in_the_store FROM gg_planman.plans;

\echo '=== 3. a superuser stores hints, and they apply to the queries of every role ==='
SELECT gg_planman.register_hints('SELECT count(*) FROM priv_t WHERE v < 1', 'SeqScan(priv_t)') IS NOT NULL AS registered;
SET ROLE app_user;
SET gg_planman.log_usage = notice;
SET optimizer = off;
EXPLAIN (COSTS off) SELECT count(*) FROM priv_t WHERE v < 5;
RESET ROLE;

\echo '=== 4. the support engineer: SELECT on the store gives the report, the regeneration stays with the superuser ==='
\set QUIET on
SET client_min_messages = warning;
CREATE SCHEMA priv_s;
CREATE TABLE priv_s.pt (id int, v int) DISTRIBUTED BY (id);
GRANT SELECT ON gg_planman.plans TO app_user;
RESET client_min_messages;
\set QUIET off
SELECT gg_planman.register_hints('SELECT count(*) FROM priv_s.pt WHERE v < 1', 'SeqScan(pt)') IS NOT NULL AS registered;
CREATE TABLE priv_t_new (LIKE priv_t) DISTRIBUTED BY (id);
DROP TABLE priv_t;
ALTER TABLE priv_t_new RENAME TO priv_t;
SET ROLE app_user;
\echo '--- the row over priv_t is invalid; the text over priv_s.pt does not resolve without USAGE on priv_s, so its key is not checked'
SELECT identity, state, reason FROM gg_planman.check();
SELECT * FROM gg_planman.check(regenerate => true);
RESET ROLE;
\echo '--- the superuser sees the same rows, resolves every text, and regenerates'
SELECT identity, state, reason FROM gg_planman.check();
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);

\set QUIET on
SET client_min_messages = warning;
REVOKE SELECT ON gg_planman.plans FROM app_user;
DROP SCHEMA priv_s CASCADE;
DROP TABLE priv_t;
TRUNCATE gg_planman.plans;
