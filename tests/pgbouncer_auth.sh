#!/usr/bin/env bash
# Integration test for the PgBouncer setup. Starts a throwaway PostgreSQL and
# PgBouncer, applies roles/pgbouncer/files/auth_setup.sql (twice, to prove it
# is idempotent) and the rendered pgbouncer.ini, then checks that:
#   - an application user logs in through PgBouncer without being listed in
#     userlist.txt (auth_query does the lookup)
#   - a wrong password is rejected
#   - pgbouncer_auth cannot read pg_shadow directly
# Needs PostgreSQL server binaries, pgbouncer and python3-jinja2. Run as a
# non-root user.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z ${PG_BIN:-} ]]; then
  # Newest installed PostgreSQL server.
  for dir in /usr/lib/postgresql/*/bin; do
    [[ -x $dir/initdb ]] && PG_BIN=$dir
  done
fi
: "${PG_BIN:?no PostgreSQL server binaries found; set PG_BIN}"
PG_PORT=55432
BOUNCER_PORT=56432
work=$(mktemp -d)

cleanup() {
  if [[ -f $work/pgbouncer.pid ]]; then kill "$(cat "$work/pgbouncer.pid")" 2> /dev/null || true; fi
  "$PG_BIN/pg_ctl" -D "$work/data" -m fast stop > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

"$PG_BIN/initdb" -D "$work/data" -U postgres --auth-local=trust --auth-host=scram-sha-256 > /dev/null
"$PG_BIN/pg_ctl" -D "$work/data" -l "$work/postgres.log" -w \
  -o "-p $PG_PORT -k $work -c listen_addresses=127.0.0.1" start > /dev/null

admin() { psql -X -q -v ON_ERROR_STOP=1 -h "$work" -p "$PG_PORT" -U postgres -d postgres "$@"; }
admin --set=auth_password=bouncer-secret -f roles/pgbouncer/files/auth_setup.sql
admin --set=auth_password=bouncer-secret -f roles/pgbouncer/files/auth_setup.sql
admin -c "CREATE ROLE app LOGIN PASSWORD 'app-secret'" -c "CREATE DATABASE appdb OWNER app"

python3 - "$work" "$PG_PORT" "$BOUNCER_PORT" << 'PY'
import sys

import jinja2

work, pg_port, bouncer_port = sys.argv[1:4]
ini = jinja2.Template(open("roles/pgbouncer/templates/pgbouncer.ini.j2").read()).render(
    pgbouncer_port=bouncer_port,
    pgbouncer_pool_mode="transaction",
    pgbouncer_max_client_conn=100,
    pgbouncer_default_pool_size=5,
)
for old, new in [
    ("port=5432", f"port={pg_port}"),
    ("/var/run/postgresql", work),
    ("/var/log/postgresql", work),
    ("/etc/pgbouncer", work),
]:
    ini = ini.replace(old, new)
open(f"{work}/pgbouncer.ini", "w").write(ini)
open(f"{work}/userlist.txt", "w").write('"pgbouncer_auth" "bouncer-secret"\n')
PY
pgbouncer -d "$work/pgbouncer.ini"
sleep 1

login() { PGPASSWORD=$1 psql -X -At -h 127.0.0.1 -p "$2" -U "$3" -d "$4" -c "$5"; }

result=$(login app-secret "$BOUNCER_PORT" app appdb "select current_user || '@' || current_database()")
[[ $result == "app@appdb" ]] || { echo "FAIL: unexpected result: $result"; exit 1; }
echo "ok - app logs in through PgBouncer via auth_query"

if login wrong "$BOUNCER_PORT" app appdb "select 1" > /dev/null 2>&1; then
  echo "FAIL: wrong password accepted"; exit 1
fi
echo "ok - a wrong password is rejected"

if login bouncer-secret "$PG_PORT" pgbouncer_auth postgres "select count(*) from pg_shadow" > /dev/null 2>&1; then
  echo "FAIL: pgbouncer_auth can read pg_shadow"; exit 1
fi
echo "ok - pgbouncer_auth cannot read pg_shadow directly"
