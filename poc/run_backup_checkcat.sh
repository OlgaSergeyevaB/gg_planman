#!/bin/bash
# F17: backup and restore with pg_dump, and gpcheckcat on the coordinator-only table
source /usr/local/gpdb7/greengage_path.sh
export PGPORT=7300
SP=/tmp/claude-1000/-projects-sr-plan/ad133d28-5b31-4bf8-9acb-723aa225b64d/scratchpad
OUT=results/15_backup_checkcat.out
: > $OUT
{
echo "=== register hints in srpoc ==="
psql -X -d srpoc -c "TRUNCATE gg_planman.plans" -c "SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2) Leading((t1 t2))')" -c "SELECT count(*) AS hint_rows FROM gg_planman.plans"
echo "=== pg_dump / pg_restore into srpoc_restored ==="
pg_dump -d srpoc -Fc -f $SP/srpoc.dump && echo "dump ok: $(stat -c %s $SP/srpoc.dump) bytes"
psql -X -d postgres -c "DROP DATABASE IF EXISTS srpoc_restored" -c "CREATE DATABASE srpoc_restored"
pg_restore -d srpoc_restored $SP/srpoc.dump 2>&1 | tail -20
echo "=== restored database ==="
psql -X -d srpoc_restored -c "SELECT count(*) AS hint_rows FROM gg_planman.plans" -c "SELECT localoid::regclass, policytype, numsegments FROM gp_distribution_policy WHERE localoid = 'gg_planman.plans'::regclass"
psql -X -d srpoc_restored -c "SET optimizer = off" -c "SET gg_planman.log_usage = notice" -c "EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500"
echo "=== pg_dump --data-only for gg_planman.plans ==="
pg_dump -d srpoc --data-only -t gg_planman.plans | grep -c "NestLoop" | sed 's/^/rows with hints in data-only dump: /'
} >> $OUT 2>&1
