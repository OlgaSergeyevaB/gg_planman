# gg_planman

Plan management for Greengage 7: stored hints.
Proof of concept.

A DBA stores a set of `pg_hint_plan` hints for a query without the application changing the SQL it sends.
Stored hints are matched to a query by keys that ignore the values of constants.
The tables of the query are matched by OID, or, where the DBA says so, by name or by a regular expression, so that the hints outlive the recreation of a table and serve temporary tables of every session.
The service function `gg_planman.check()` reports a row invalid, with the reason, when a table it matches by OID or a function its query calls was dropped or replaced, or when the key of its text changed; it writes nothing to the store, so the rows it reports stay as they are until `check(regenerate => true)` registers them again, keeping their ids. Both forms take `row_id` to work on one row only.

## Build and install

```bash
make USE_PGXS=1 PG_CONFIG=/usr/local/gpdb7/bin/pg_config
sudo make USE_PGXS=1 PG_CONFIG=/usr/local/gpdb7/bin/pg_config install
```

On the coordinator, `pg_hint_plan` has to be loaded before `gg_planman`:

```
shared_preload_libraries = 'pg_hint_plan,gg_planman'
```

```sql
CREATE EXTENSION gg_planman;
```

## Use

```sql
-- hints for a query, applied to the query with any constants
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'SeqScan(t1)');

-- the same by running the query once with a hint comment
SET gg_planman.write_mode = on;
/*+ SeqScan(t1) */ SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1;
SET gg_planman.write_mode = off;
-- an EXPLAIN in write mode stores nothing: the hints are tried, and the warning says to run the statement
-- or to call register_hints; a statement the registration would refuse, such as CREATE TABLE AS, is not stored either

-- at registration a temporary table is matched by name only when the DBA lists it; the capture matches it by name on its own
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM tt WHERE v = 1', 'SeqScan(tt)', by_name => '{pg_temp.tt}');

-- a permanent table matched by name in any schema, and every table matching a regular expression
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 WHERE v < 1', 'SeqScan(t1)', by_name => '{t1}');
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM sales_2026 s WHERE s.v < 1', 'SeqScan(s)', by_regex => '{^public\\.sales_}');

-- switch a row off and on, or remove it: plain SQL on the store, by the id that register_hints returned;
-- the extension does not invalidate cached plans, a session with a prepared statement or a PL/pgSQL plan
-- picks the change up after DDL on the table, DISCARD PLANS or a reconnection
UPDATE gg_planman.plans SET enabled = false WHERE id = 1;
DELETE FROM gg_planman.plans WHERE id = 1;

-- the service check: the state of every row and why, nothing is written, any role with SELECT on the store runs it;
-- with regenerate, which needs a superuser, the invalid rows are registered again
SELECT * FROM gg_planman.check();
SELECT * FROM gg_planman.check(regenerate => true);

-- one row only, by the id that register_hints returned
SELECT * FROM gg_planman.check(row_id => 1);
SELECT * FROM gg_planman.check(regenerate => true, row_id => 1);

-- the keys and the slots of a query text, without storing anything
SELECT * FROM gg_planman.query_key('SELECT count(*) FROM t1 WHERE v < 1', by_name => '{t1}');

SELECT id, key_base, key_oid, enabled, hints, rules FROM gg_planman.plans;
```

A row has two keys: `key_base`, the jumble of the query tree without the identity of its tables, and `key_oid`, `key_base` folded with the OIDs of the tables, present only when every table is matched by OID.
A lookup takes the row with the `key_oid` of the query, or else the most specific matching row among those with its `key_base`: the most tables matched by OID, then by name, then by regular expression, then the newest row.

Settings: `gg_planman.enabled`, `gg_planman.write_mode`, `gg_planman.log_usage`.

The walkthrough is `poc/demo.sh`; the scenarios and their outputs are in `poc/`.

## What the PoC shows against the SRS

The SRS is `adbdev10707_srs_plan_management.md` in `adb-requirements/greengage/gg_planman`.
The evidence of the PoC runs lives here, not in the SRS; the scenarios and their outputs are in `poc/` and `poc/results/`.

| SRS requirements | PoC evidence | Result |
|---|---|---|
| `IR1`, `FR1`–`FR6` | scenarios 02, 19, 21 | pass |
| `FR7`, `E6`, `E15` | scenario 32 | pass under both optimizers: a hint with a missing index or a syntax error is stored without a warning; `pg_hint_plan` shows the missing index only with `debug_print` and reports the syntax error as `INFO` at every planning |
| `IR3`, `FR3`, `FR4`, `FR14` | scenario 02 | pass |
| `FR8`–`FR13`, `FR16`, `FR38` | scenario 26, blocks 1–9 | pass under both optimizers |
| `FR17` | scenario 26, block 8 | pass; `schema.name` is not ranked above `name` on ties |
| `FR15`, `FR20` | scenarios 01, 05, 09, 12 | pass: the plan with stored hints matches the plan with the same hints in a comment, direct dispatch (05) and `Set(optimizer off)` (09, 12) included |
| `FR21` | scenario 29 | pass under both optimizers |
| `FR22` | scenario 07 | pass |
| `FR23`–`FR25`, `FR26`, `FR27`, `FR29` | scenarios 01, 08, 22, 26 block 11 | pass |
| `FR28` | — | several statements in one string: checked by hand with `psql -c`, no scenario yet |
| `FR30`, `FR31` | scenario 26 block 12, demo section 11, customer examples 1.8 | pass |
| `FR32` | scenarios 06, 10 | pass: a cached generic plan keeps or misses the hints until DDL on the table, `DISCARD PLANS` or a reconnection; `ANALYZE` of an unchanged table does not renew it |
| `FR18`, `FR19` | scenario 26, block 6 | pass |
| `IR2`, `FR33`–`FR37`, `FR39` | scenarios 21 (`FR39`: section 8), 04, 22, 26 block 10 | pass |
| `IR1`–`IR5`: the privileges of the functions, the settings and the store | scenario 30 | pass |
| `IR6` | outputs of every scenario | the log lines are present |
| planning overhead, no requirement in the SRS since 2026-10-17 | `run_micro.sh`, `run_micro_by_name.sh` | measured 2026-10-12: 3 µs without a row, 7 µs with a row, under 1 % under GPORCA, 0.5 µs per candidate |
| restore from a backup, UC-05 AF4 of the SRS | `run_backup_checkcat.sh` | the restored store is empty: an open PoC finding, no longer a question in the SRS |
| `E4`, `E13`: a failure inside the extension never fails the query | — | not built |
| coexistence with `pg_stat_statements`, no requirement in the SRS since 2026-10-17 | scenario 17 | pass with `pg_stat_statements` loaded |
| `DR1` | `demo.sh`, `demo.sh status` | installation on the demo cluster: the library in `shared_preload_libraries` of the coordinator only, the store without a distribution policy |
| ADR, option 2: the hint table of `pg_hint_plan` keys hints by text | scenario 31 | a row is found for another constant and missed for two spaces, a comment, a line break, lower case, a schema-qualified name or a missing `EXPLAIN` prefix; the `gg_planman` row serves every spelling |
