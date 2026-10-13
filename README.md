# postgres-ha

Ansible for a three-node PostgreSQL cluster that fails over on its own:
Patroni manages PostgreSQL and replication, etcd holds the leader lock,
PgBouncer pools connections on each node, and HAProxy sends writes to
whichever node is primary right now.

```
                 :5000 writes ──▶ primary ─┐
 apps ──▶ HAProxy                          │  PgBouncer :6432 ──▶ PostgreSQL :5432
                 :5001 reads  ──▶ replicas ┘        (on every node, managed by Patroni)

 Patroni on each node ◀──▶ etcd (3 members): leader lock, cluster config
```

## Layout

```
site.yml                 full deployment
status.yml               patronictl list
switchover.yml           planned move of the primary
failover-test.yml        failover drill for test clusters
inventory/               example inventory and group_vars (vault.yml.example)
roles/etcd               etcd 3.7 from the official release, 3-member cluster
roles/postgresql         PGDG packages, no default cluster
roles/patroni            Patroni config: etcd3, pg_rewind, slots, scram
roles/pgbouncer          transaction pooling, auth_query lookups
roles/haproxy            primary/replica routing on Patroni health checks
tests/                   PgBouncer login test, template render helper
```

## Deploying

```bash
cp inventory/hosts.example.yml inventory/hosts.yml
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
# set real passwords, then:
ansible-vault encrypt inventory/group_vars/all/vault.yml
ansible-playbook site.yml --ask-vault-pass
ansible-playbook status.yml
```

Set `cluster_cidr` to the network your applications connect from. Targets are
Ubuntu 24.04; `postgresql_version` defaults to 17.

## How failover works

Each Patroni keeps renewing a leader key in etcd with a 30 second TTL. If the
primary stops renewing it, because the node or Patroni died, the healthiest
replica that's no more than 1 MB behind takes the lock and promotes itself.
HAProxy checks `/primary` on every node's Patroni API every 3 seconds, so
within a few seconds writes on port 5000 go to the new primary, and sessions
still open on the old one are cut. When the old primary comes back, Patroni
rewinds it with `pg_rewind` and it rejoins as a replica.

Reads on port 5001 go round-robin to replicas that are running and less than
16 MB behind.

## Connection pooling

PgBouncer runs in transaction mode on every node. Application users aren't
listed in its config: PgBouncer logs in as `pgbouncer_auth` and looks up each
user's SCRAM hash through `pgbouncer.get_auth()`, a `SECURITY DEFINER`
function that can return one user's hash at a time. `pgbouncer_auth` itself
can't read `pg_shadow`. Ansible creates the role and function on the primary
only; replication carries them to the others.

## Operations

```bash
ansible-playbook switchover.yml -e candidate=pg2   # planned, no data loss
ansible-playbook failover-test.yml                 # drill: test clusters only
```

The drill stops Patroni on the leader, waits for a new one, checks that a
write through HAProxy lands on a primary, restarts the old leader and waits
for it to stream as a replica, then reports how long the election took.

## Tests

- `tests/pgbouncer_auth.sh` starts a throwaway PostgreSQL and PgBouncer,
  applies the auth setup twice to prove it's idempotent, and checks that an
  application user can log in through PgBouncer, that a wrong password is
  refused, and that `pgbouncer_auth` can't read `pg_shadow`.
- CI renders the HAProxy, Patroni and etcd configs for every host in the
  example inventory and checks them with `haproxy -c` and a YAML parser, and
  runs ansible-lint and the login test.

## Not covered yet

etcd and the Patroni API run over plain HTTP inside the private network, and
there's no backup tool yet. TLS for etcd and pgBackRest backups are the next
things to add.
