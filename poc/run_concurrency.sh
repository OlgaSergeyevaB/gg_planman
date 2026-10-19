#!/bin/bash
# F16: concurrent registration of one query shape while other sessions plan the query
source /usr/local/gpdb7/greengage_path.sh
export PGPORT=7300 PGDATABASE=srpoc
OUT=results/16_concurrency.out
: > $OUT
psql -X -q -c "TRUNCATE gg_planman.plans"
PGOPTIONS="-c optimizer=off" pgbench -n -M simple -c 4 -j 4 -T 20 -f bench_join.sql > results/16_pgbench_during.txt 2>&1 &
for s in 1 2 3 4; do
  ( for j in $(seq 1 150); do echo "SELECT gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = $j', 'SeqScan(t2) BitmapScan(t1 t1_v_idx) HashJoin(t1 t2)');"; done | psql -X -q -o /dev/null 2> results/16_writer_$s.err ) &
done
wait
{
echo "=== writer errors ==="; cat results/16_writer_*.err | sort | uniq -c
echo "=== rows for the shape (expected 1) ==="
psql -X -At -c "SELECT count(*) FROM gg_planman.plans"
echo "=== pgbench planning the same query during 600 registrations ==="
grep -E "tps|latency average|number of failed|aborted" results/16_pgbench_during.txt
} >> $OUT 2>&1
