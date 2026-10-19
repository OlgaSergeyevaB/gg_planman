-- F22/F23: what the key is made of besides relations
SET client_min_messages = warning;
DROP TABLE IF EXISTS kt, kt_new, k2 CASCADE;
DROP FUNCTION IF EXISTS kf(int);
RESET client_min_messages;

\echo '=== 1. columns enter the key by attribute number ==='
CREATE TABLE kt (a int, b int, c int) DISTRIBUTED BY (a);
SELECT 'kt(a,b,c): WHERE c < 1' AS step, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM kt WHERE c < 1');
ALTER TABLE kt DROP COLUMN b;
SELECT 'after DROP COLUMN b, c keeps number 3' AS step, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM kt WHERE c < 1');
CREATE TABLE kt_new AS SELECT * FROM kt DISTRIBUTED BY (a);
DROP TABLE kt;
ALTER TABLE kt_new RENAME TO kt;
SELECT 'after recreation, c gets number 2' AS step, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM kt WHERE c < 1');

\echo '=== 2. another column at the same position gives the same key ==='
CREATE TABLE k2 (a int, b int) DISTRIBUTED BY (a);
SELECT 'k2(a,b): WHERE b < 1' AS query, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM k2 WHERE b < 1');
DROP TABLE k2;
CREATE TABLE k2 (b int, a int) DISTRIBUTED BY (b);
SELECT 'k2(b,a): WHERE a < 1' AS query, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM k2 WHERE a < 1');

\echo '=== 3. a user-defined function enters the key by OID ==='
CREATE FUNCTION kf(int) RETURNS int AS 'select $1' LANGUAGE sql IMMUTABLE;
SELECT 'before' AS step, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM kt WHERE kf(a) < 1');
CREATE OR REPLACE FUNCTION kf(int) RETURNS int AS 'select $1 + 0' LANGUAGE sql IMMUTABLE;
SELECT 'after CREATE OR REPLACE' AS step, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM kt WHERE kf(a) < 1');
DROP FUNCTION kf(int);
CREATE FUNCTION kf(int) RETURNS int AS 'select $1' LANGUAGE sql IMMUTABLE;
SELECT 'after DROP and CREATE' AS step, key_base, key_oid FROM gg_planman.query_key('SELECT count(*) FROM kt WHERE kf(a) < 1');

\echo '=== 4. output column aliases and FOR UPDATE are not in the key ==='
SELECT q, key_base, key_oid FROM (
          SELECT 1 AS n, 'SELECT v AS x FROM t1 WHERE id = 1' AS q, key_base, key_oid FROM gg_planman.query_key('SELECT v AS x FROM t1 WHERE id = 1')
UNION ALL SELECT 2, 'SELECT v AS y FROM t1 WHERE id = 1', key_base, key_oid FROM gg_planman.query_key('SELECT v AS y FROM t1 WHERE id = 1')
UNION ALL SELECT 3, 'SELECT v AS x FROM t1 WHERE id = 1 FOR UPDATE', key_base, key_oid FROM gg_planman.query_key('SELECT v AS x FROM t1 WHERE id = 1 FOR UPDATE')
UNION ALL SELECT 4, 'SELECT pad AS x FROM t1 WHERE id = 1', key_base, key_oid FROM gg_planman.query_key('SELECT pad AS x FROM t1 WHERE id = 1')
) s ORDER BY n;

DROP TABLE kt, k2;
DROP FUNCTION kf(int);
