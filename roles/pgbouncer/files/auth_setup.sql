-- Run on the primary by Ansible; replicas get it through replication.
-- psql variable: auth_password

SELECT format('CREATE ROLE pgbouncer_auth LOGIN PASSWORD %L', :'auth_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_auth')
\gexec

-- Keep the password in step with the vault.
SELECT format('ALTER ROLE pgbouncer_auth PASSWORD %L', :'auth_password')
\gexec

CREATE SCHEMA IF NOT EXISTS pgbouncer;

-- pgbouncer_auth may read one user's hash at a time through this function,
-- never pg_shadow itself.
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text)
RETURNS TABLE (usename name, passwd text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT usename, passwd FROM pg_shadow WHERE usename = p_usename
$$;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO pgbouncer_auth;
