#!/bin/bash
# PoC gg_planman: plan management for Greengage 7, stored pg_hint_plan hints.
#
#   ./demo.sh            run the whole demonstration
#   ./demo.sh step       the same with a pause after every section
#   ./demo.sh psql       open psql to the demo database
#   ./demo.sh start      start the PoC cluster
#   ./demo.sh stop       stop the PoC cluster
#   ./demo.sh restart    restart it, after reinstalling the extension
#   ./demo.sh status     state of the cluster
#
# Cluster: /projects/srplan-poc-gg7, port 7300, database srpoc, three segments.
# The extension is installed into /usr/local/gpdb7 from /projects/gg_planman (make install, 2026-10-19).

GPHOME=/usr/local/gpdb7
COORD=/projects/srplan-poc-gg7/datadirs/qddir/demoDataDir-1
PORT=7300
DB=srpoc
HERE=$(cd "$(dirname "$0")" && pwd)

as_gpadmin() {
  sudo -n -u gpadmin env -i HOME=/home/gpadmin USER=gpadmin LOGNAME=gpadmin \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=/usr/local/bin:/usr/bin:/bin \
    bash -c "source $GPHOME/greengage_path.sh && export COORDINATOR_DATA_DIRECTORY=$COORD PGPORT=$PORT && $*"
}

source $GPHOME/greengage_path.sh
export PGPORT=$PORT PGDATABASE=$DB

case "${1:-run}" in
  start)   as_gpadmin "gpstart -a" | grep -E "successfully started|ERROR|FATAL" ;;
  stop)    as_gpadmin "gpstop -a"  | grep -E "Database successfully shutdown|ERROR|FATAL" ;;
  restart) as_gpadmin "gpstop -ar" | grep -E "successfully|ERROR|FATAL" ;;
  status)  as_gpadmin "gpstate -s" | grep -E "Coordinator instance|Segment status|Total.*(up|down)|Database status|ERROR" ;;
  psql)    exec psql -X ;;
  run|step)
    psql -X -Atc "select 1" >/dev/null 2>&1 || { echo "The cluster does not answer on port $PORT: run ./demo.sh start first"; exit 1; }
    [ "$1" = step ] && STEP="-v step=1" || STEP=""
    exec psql -X -v ON_ERROR_STOP=1 $STEP -f "$HERE/demo.sql"
    ;;
  *) sed -n '2,13p' "$0" ;;
esac
