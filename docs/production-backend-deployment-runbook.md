# Production backend deployment runbook

Approved source for the migration SQL is `feature/backend-hardening` at `23a6c0031548925d0eabf5054df99382e23954f8`. Use tracked Supabase migration application, one migration per invocation, with a read-only acceptance gate after each step. The earlier audit observed an absent history ledger and compatible existing membership functions and trigger. The first two migrations can apply over those definitions and initialize normal tracking. The order below assumes that state still holds.

## 1. Freeze and identify the target

Use Bash from the repository root. In the current checkout, preserve unrelated local work and use a clean deployment checkout of the approved commit. Run this verification in the clean checkout.

```bash
set -euo pipefail
release=23a6c0031548925d0eabf5054df99382e23954f8
test "$(git branch --show-current)" = feature/backend-hardening
test "$(git rev-parse HEAD)" = "$release"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
git diff --check
migrations=(
  20261118000100_membership_security.sql
  20261118000200_protect_last_admin.sql
  20261119000100_harden_workspace_profile_access.sql
  20261119000200_protect_invitation_attribution.sql
  20261119000300_secure_invitation_acceptance.sql
  20261119000400_harden_message_ownership.sql
)
diff -u <(printf 'supabase/migrations/%s\n' "${migrations[@]}") \
  <(git ls-tree -r --name-only "$release" -- supabase/migrations/)
diff -u <(printf 'supabase/migrations/%s\n' "${migrations[@]}") \
  <(find supabase/migrations -maxdepth 1 -name '*.sql' -print | LC_ALL=C sort)
test ! -e supabase/migrations/20261118000000_local_baseline.sql
```

- Match the Supabase organization, Production project name and project reference against the approved change record and dashboard. Confirm Production is the intended main database of that **Supabase project** and not a preview database. The source Git branch is `feature/backend-hardening`.
- Confirm the deployment role is `postgres`, the audited owner of the five application tables and `supabase_realtime`. Confirm the authenticated CLI profile has access to that project.
- Set these two operator inputs from the approved change record and a trusted CA file. For this procedure use the direct endpoint from the dashboard, `db.<project-ref>.supabase.co`, port 5432. Supply the database password through a protected libpq password file or prompt. Keep credentials out of shell arguments, logs and the change record. If the direct endpoint is unavailable, rehearse the approved alternative connection path before using it.

```bash
: "${VW_PROD_REF:?Set the approved Production project ref}"
: "${VW_PROD_CA:?Set the path to the trusted TLS CA file}"
[[ "$VW_PROD_REF" =~ ^[a-z0-9]+$ ]]
test -r "$VW_PROD_CA"
prod_ro() {
  PGSSLMODE=verify-full PGSSLROOTCERT="$VW_PROD_CA" \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off -h "db.$VW_PROD_REF.supabase.co" \
    -p 5432 -U postgres -d postgres "$@" \
    -c 'BEGIN READ ONLY' -f - -c 'ROLLBACK'
}
prod_ro <<< "select current_database(), current_user, current_setting('transaction_read_only') as read_only;"
```

Expected connection result is `postgres | postgres | on`. Confirm the project ref independently in the dashboard.

## 2. Backup and recovery readiness

- In the Production dashboard, verify the most recent **completed** recoverable backup and its UTC timestamp. Check whether PITR is enabled and, if enabled, its recoverable range. Record the recovery point, recovery owner, expected data loss and expected restoration time. Verify evidence of a restore rehearsal on an isolated target. Treat backup/PITR availability as unknown until verified. [Supabase database backups](https://supabase.com/docs/guides/platform/backups)
- Capture the following schema definitions and effective grants in a restricted change artifact. Use `umask 077` and `prod_ro -o "$VW_RECOVERY_DIR/catalog-before.txt"` with the SQL block below as standard input. Set `VW_RECOVERY_DIR` to a private directory outside the repository. The queries export catalog metadata and omit customer rows.

```sql
select tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies where schemaname = 'public'
  and tablename in ('users','workspaces','workspace_members','invitations','messages')
order by 1,2;

select c.relname, c.relrowsecurity, c.relforcerowsecurity, c.relreplident,
       pg_get_userbyid(c.relowner) as owner, c.relacl
from pg_class c where c.oid in
  ('public.users'::regclass,'public.workspaces'::regclass,'public.workspace_members'::regclass,
   'public.invitations'::regclass,'public.messages'::regclass)
order by 1;

select p.oid::regprocedure as signature, pg_get_userbyid(p.proowner) as owner,
       p.proacl, pg_get_functiondef(p.oid) as definition
from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
  ('is_workspace_member','is_workspace_admin','protect_last_workspace_admin',
   'protect_invitation_attribution','enforce_invitation_lifecycle',
   'accept_workspace_invitation','keep_message_workspace');

select tgrelid::regclass as relation, tgname, tgenabled, pg_get_triggerdef(oid) as definition
from pg_trigger where not tgisinternal and tgrelid in
  ('public.workspace_members'::regclass,'public.invitations'::regclass,'public.messages'::regclass);

select conname, convalidated, pg_get_constraintdef(oid) as definition
from pg_constraint where conrelid = 'public.invitations'::regclass;
select indexname, indexdef from pg_indexes where schemaname = 'public' and tablename = 'invitations';

select pg_get_expr(d.adbin,d.adrelid) as sender_default
from pg_attrdef d join pg_attribute a on (a.attrelid,a.attnum) = (d.adrelid,d.adnum)
where d.adrelid = 'public.messages'::regclass and a.attname = 'sender_id';

select pubname, pg_get_userbyid(pubowner) as owner, puballtables, pubinsert,
       pubupdate, pubdelete, pubtruncate, pubviaroot
from pg_publication where pubname = 'supabase_realtime';
select schemaname, tablename, attnames, rowfilter from pg_publication_tables
where pubname = 'supabase_realtime';
select n.nspname from pg_publication_namespace pn join pg_namespace n on n.oid = pn.pnnspid
join pg_publication p on p.oid = pn.pnpubid where p.pubname = 'supabase_realtime';
```

## 3. Immediate read-only preflight

Run the SQL blocks through `prod_ro`. Keep output to aggregates, object names and session age. For checks that are repeated after each migration, keep this runbook and the protected output available in the change record.

```sql
with duplicates as (
  select count(*) as n from public.invitations where status = 'pending'
  group by workspace_id, pg_catalog.lower(email) having count(*) > 1
)
select count(*) as duplicate_pending_groups, coalesce(sum(n),0) as affected_rows from duplicates;

select count(*) filter (where i.status is null or i.status not in ('pending','accepted','expired','revoked')) as invalid_status,
       count(*) filter (where w.id is null) as missing_workspace,
       count(*) filter (where i.invited_by is not null and a.id is null) as unmapped_inviter,
       count(*) filter (where i.status = 'pending' and (i.expires_at is null or i.expires_at <= now())) as unusable_pending
from public.invitations i
left join public.workspaces w on w.id = i.workspace_id
left join public.users u on u.id = i.invited_by
left join auth.users a on a.id = u.auth_id;

select count(*) as duplicate_membership_groups from (
  select 1 from public.workspace_members group by user_id, workspace_id having count(*) > 1
) d;

select count(*) filter (where role is null or role not in ('admin','employee')) as invalid_role,
       count(*) filter (where status is null or status not in ('active','removed')) as invalid_status
from public.workspace_members;

select count(*) as workspaces_without_active_admin
from public.workspaces w where not exists (
  select 1 from public.workspace_members m where m.workspace_id=w.id and m.role='admin' and m.status='active'
);
```

Record this ACL output before deployment and repeat it after migrations 3 and 6. Before deployment, the audited state had five effective direct grants per role for each of the four listed privileges, with no `PUBLIC` or inherited route. After migration 3 and at completion, every `effective` result must be false. The grantor in the audited snapshot was `postgres`. Compare ordinary CRUD grants using the same query with the privilege list changed to `SELECT, INSERT, UPDATE, DELETE`.

```sql
with clients as (select oid,rolname from pg_roles where rolname in ('anon','authenticated')),
targets as (
  select oid,relname,relacl,relowner from pg_class
  where relnamespace = 'public'::regnamespace
    and relname in ('users','workspaces','workspace_members','invitations','messages')
)
select r.rolname as client, t.relname as relation, p.privilege,
       has_table_privilege(r.oid,t.oid,p.privilege) as effective,
       count(*) filter (where a.grantee=r.oid) as direct,
       count(*) filter (where a.grantee=0) as via_public,
       count(*) filter (where case when a.grantee<>0 and a.grantee<>r.oid
         then pg_has_role(r.oid,a.grantee,'USAGE') else false end) as inherited,
       count(*) filter (where case when a.grantee<>0 and a.grantee<>r.oid
         then pg_has_role(r.oid,a.grantee,'MEMBER') else false end) as other_role_memberships
from clients r cross join targets t
cross join (values ('TRUNCATE'),('TRIGGER'),('REFERENCES'),('MAINTAIN')) p(privilege)
left join lateral aclexplode(coalesce(t.relacl,acldefault('r',t.relowner))) a
  on a.privilege_type=p.privilege
group by r.oid,r.rolname,t.oid,t.relname,p.privilege order by 1,2,3;
```

Require one publication row, `messages_only = true`, owner `postgres`, and a valid message primary key with `relreplident = d`. The sole table entry must have no row filter and the six audited columns shown below. In the audited pre-deploy state all four event flags are true. Retake this check immediately before migration 6.

```sql
select pg_get_userbyid(p.pubowner) as owner, p.pubinsert, p.pubupdate, p.pubdelete, p.pubtruncate,
       not p.puballtables
       and not exists (select 1 from pg_publication_namespace where pnpubid = p.oid)
       and (select count(*) from pg_publication_tables where pubname = p.pubname) = 1
       and exists (select 1 from pg_publication_tables
         where pubname = p.pubname and schemaname = 'public' and tablename = 'messages') as messages_only
from pg_publication p where p.pubname = 'supabase_realtime';
select schemaname, tablename, rowfilter is null as no_filter,
       attnames = array['id','workspace_id','sender_id','channel','content','created_at']::name[] as expected_columns
from pg_publication_tables where pubname = 'supabase_realtime';
select c.relreplident, exists (select 1 from pg_index i
  where i.indrelid = c.oid and i.indisprimary and i.indisvalid) as valid_pk
from pg_class c where c.oid = 'public.messages'::regclass;
```

Run this ledger block in `psql` via `prod_ro`. Before step 1 the audited result was `LEDGER_ABSENT`. After step *n*, expect exactly the first *n* versions in the approved order. An empty ledger that appeared since the audit still warrants reconciliation.

```sql
select to_regclass('supabase_migrations.schema_migrations') is not null as ledger_exists \gset
\if :ledger_exists
select version from supabase_migrations.schema_migrations order by version;
\else
\echo LEDGER_ABSENT
\endif
```

Inspect contention before entering the window and before steps 5 and 6. Supply `-v vw_age='<approved interval>'` to `prod_ro`, using the age threshold agreed in the change record. Inspect blocking sessions linked to application tables even if their age is below the threshold.

```sql
select pid, application_name, state, wait_event_type, wait_event,
       now() - xact_start as transaction_age, pg_blocking_pids(pid) as blockers
from pg_stat_activity
where datname = current_database() and pid <> pg_backend_pid()
  and (xact_start < now() - :'vw_age'::interval or cardinality(pg_blocking_pids(pid)) > 0)
order by xact_start nulls last;

select l.pid, l.relation::regclass as relation, l.mode, l.granted, pg_blocking_pids(l.pid) as blockers
from pg_locks l where l.locktype = 'relation' and l.relation in
  ('public.users'::regclass,'public.workspaces'::regclass,'public.workspace_members'::regclass,
   'public.invitations'::regclass,'public.messages'::regclass)
order by l.granted, l.relation, l.pid;
```

## 4. Hard stops

- Source revision, branch, migration contents, target project, TLS verification, owner or deployment role mismatch.
- Any duplicate pending invitation group, incompatible statuses or orphan references, or duplicate/invalid memberships. Resolve unusable pending invitations before deployment if they would occupy a uniqueness slot needed at launch.
- A workspace with zero active admins. Review whether it is recoverable and reconcile before proceeding.
- Missing or changed prerequisite policies, function signatures, trigger bindings, constraints or publication membership. Stop if the scope of `supabase_realtime` exceeds `public.messages`, or if a required Realtime consumer depends on the outgoing DELETE events without an agreed replacement.
- Unknown or unexpected grant paths, unexpected ledger contents or changed existing objects. Reconcile the actual schema and history first.
- Missing verified recovery point or recovery owner, unresolved long transactions, exceeded lock/step budget, nonzero application exit, lost connection, missing history row or failed validation. Hold the next migration while determining whether the current one committed.

## 5. Maintenance window

Use a low-traffic window for the entire sequence so migration progress, ACL changes and ledger checks stay coordinated. Pause concurrent deployers and reduce invitation and messaging writes before steps 5 and 6. Step 5 can hold `ACCESS EXCLUSIVE` on `invitations` through constraint validation and the non-concurrent unique index build. Step 6 can hold `ACCESS EXCLUSIVE` on `messages` for the default and policy changes. Monitor lock queues, API latency and errors, and database activity in a second read-only session. [PostgreSQL — explicit locking](https://www.postgresql.org/docs/17/explicit-locking.html) · [PostgreSQL — index creation](https://www.postgresql.org/docs/17/sql-createindex.html)

The approved lock wait is 10 seconds. The statement and total transaction budgets are 2 minutes for steps 1–4 and 5 minutes for steps 5–6. PostgreSQL 17 enforces the total budget with `transaction_timeout`, which also covers the history insert. Inspect lock waits in the observer session. At an exceeded budget, timeout, disconnection or validation error, hold the next step and inspect the catalog and ledger. Cancel only the positively identified deployment backend if intervention is required. Keep application sessions running.

## 6. Atomic deployment execution

Run this section during the approved deployment window with Supabase CLI **3.2.0** and PostgreSQL 17. CLI creates its standard history table as a separate setup operation when needed. Once setup finishes, CLI applies each transactional file and its history insert in the same transaction. An explicit `COMMIT` in a migration would commit its schema changes before the history insert. The generator removes only the fixed outer `BEGIN;` and `COMMIT;` lines from files 2–6 so CLI owns that boundary. File 1 has no wrapper. A failed first application may therefore leave an empty, CLI-created ledger. Reconcile that state before retrying. [Supabase migration tracking](https://supabase.com/docs/guides/deployment/database-migrations)

The Git blobs at the approved revision are the source of truth. Use a private work directory outside the repository. The generator verifies each Git blob against the clean checkout, checks the wrapper lines at the audited positions, and reconstructs the original blob from the generated file to prove that the SQL body and other bytes are unchanged. Record the source, body and deployment SHA-256 digests. The CLI ledger records the original versions and names with the generated execution statements, which include the timeout gate.

Each generated file starts with three `SET LOCAL` statements and a guard that checks all three settings in the actual migration transaction. The guard aborts before schema changes if the settings differ. Keep the generated files private and preserve their cumulative prefix so each invocation exposes exactly one pending version. Use the approved local credential handoff for `SUPABASE_DB_PASSWORD` and an authenticated CLI profile. Use verified TLS for the established direct or rehearsed session-pooler path.

```bash
: "${VW_CLI:?Set the absolute path to Supabase CLI 3.2.0}"
test "$("$VW_CLI" --version)" = 3.2.0
umask 077
vw_deploy_dir=$(mktemp -d)
"$VW_CLI" --workdir "$vw_deploy_dir" init
mkdir -p "$vw_deploy_dir/supabase/migrations" "$vw_deploy_dir/supabase/.temp"
printf '%s\n' "$VW_PROD_REF" > "$vw_deploy_dir/supabase/.temp/project-ref"

normalize_step() {
  python3 - "$release" "$1" "$2" <<'PYGEN'
from hashlib import sha256
from pathlib import Path
import subprocess
import sys

release, index, destination = sys.argv[1:]
index = int(index)
audited = (
    ("20261118000100_membership_security.sql", 0, 0),
    ("20261118000200_protect_last_admin.sql", 6, 93),
    ("20261119000100_harden_workspace_profile_access.sql", 10, 29),
    ("20261119000200_protect_invitation_attribution.sql", 2, 38),
    ("20261119000300_secure_invitation_acceptance.sql", 1, 159),
    ("20261119000400_harden_message_ownership.sql", 1, 47),
)
if not 1 <= index <= len(audited):
    raise SystemExit("STOP: unknown migration index")
name, first, last = audited[index - 1]
source = Path("supabase/migrations") / name
raw = subprocess.check_output(["git", "show", f"{release}:{source}"])
if source.read_bytes() != raw:
    raise SystemExit("STOP: working-tree bytes differ from Git")
original = raw.splitlines(keepends=True)
body_lines = original.copy()
if first:
    if original[first - 1].strip().lower() != b"begin;" or original[last - 1].strip().lower() != b"commit;":
        raise SystemExit("STOP: outer transaction markers differ")
    del body_lines[last - 1]
    del body_lines[first - 1]
body = b"".join(body_lines)
minutes = 2 if index <= 4 else 5
prefix = f"""set local lock_timeout = '10s';
set local statement_timeout = '{minutes}min';
set local transaction_timeout = '{minutes}min';
do $vw_timeout_gate$
begin
  if current_setting('lock_timeout')::interval <> interval '10 seconds'
     or current_setting('statement_timeout')::interval <> interval '{minutes} minutes'
     or current_setting('transaction_timeout')::interval <> interval '{minutes} minutes' then
    raise exception 'Migration timeouts are not effective in this transaction';
  end if;
end;
$vw_timeout_gate$;
""".encode("ascii")
target = Path(destination) / name
with target.open("xb") as output:
    output.write(prefix + body)
generated = target.read_bytes()
if generated[:len(prefix)] != prefix or generated[len(prefix):] != body:
    raise SystemExit("STOP: generated SQL or timeout preamble differs")
reconstructed = generated[len(prefix):].splitlines(keepends=True)
if first:
    reconstructed.insert(first - 1, original[first - 1])
    reconstructed.insert(last - 1, original[last - 1])
if b"".join(reconstructed) != raw:
    raise SystemExit("STOP: exact reconstruction of the source failed")
print(f"{name} source={sha256(raw).hexdigest()} body={sha256(body).hexdigest()}"
      f" deployment={sha256(generated).hexdigest()}")
PYGEN
}

vw_audited_dir=$(mktemp -d "$vw_deploy_dir/audited.XXXXXX")
for index in {1..6}; do
  normalize_step "$index" "$vw_audited_dir"
done

apply_step() {
  local step="$1" file version have previous expected answer prefix_file index
  [[ "$step" =~ ^[1-6]$ ]] || return 1
  file="${migrations[step-1]}"
  version="${file%%_*}"
  have=$(prod_ro -At <<< "select to_regclass('supabase_migrations.schema_migrations') is not null;") || return 1
  if [[ "$step" = 1 ]]; then
    [[ "$have" = f ]] || { echo 'STOP: expected absent ledger before step 1'; return 1; }
  else
    [[ "$have" = t ]] || return 1
    previous=$(prod_ro -At <<< 'select version from supabase_migrations.schema_migrations order by version;') || return 1
    expected=$(printf '%s\n' "${migrations[@]:0:step-1}" | cut -d_ -f1)
    [[ "$previous" = "$expected" ]] || { echo 'STOP: ledger does not match approved prefix'; return 1; }
  fi
  local verified
  verified=$(mktemp -d "$vw_deploy_dir/verify.XXXXXX") || return 1
  for ((index=1; index<=step; index++)); do
    normalize_step "$index" "$verified" || return 1
    prefix_file="${migrations[index-1]}"
    cmp "$verified/$prefix_file" "$vw_audited_dir/$prefix_file" || return 1
  done
  cp "$verified/$file" "$vw_deploy_dir/supabase/migrations/$file" || return 1
  diff -u <(printf '%s\n' "${migrations[@]:0:step}") \
    <(cd "$vw_deploy_dir/supabase/migrations" && printf '%s\n' *.sql | LC_ALL=C sort) || return 1
  for prefix_file in "${migrations[@]:0:step}"; do
    cmp "$verified/$prefix_file" "$vw_deploy_dir/supabase/migrations/$prefix_file" || return 1
  done
  printf 'Confirm Production ref %s and migration %s by typing the migration version: ' "$VW_PROD_REF" "$file"
  read -r answer
  [[ "$answer" = "$version" && -n "${SUPABASE_DB_PASSWORD:-}" ]] || return 1
  test "$(cat "$vw_deploy_dir/supabase/.temp/project-ref")" = "$VW_PROD_REF" || return 1
  PGSSLMODE=verify-full PGSSLROOTCERT="$VW_PROD_CA" \
    "$VW_CLI" --workdir "$vw_deploy_dir" migration up --remote="$VW_PROD_REF" --yes || return 1
  have=$(prod_ro -At <<< 'select version from supabase_migrations.schema_migrations order by version;') || return 1
  expected=$(printf '%s\n' "${migrations[@]:0:step}" | cut -d_ -f1)
  [[ "$have" = "$expected" ]] || { echo 'STOP: ledger does not match applied prefix'; return 1; }
}
```

Run the entries below **individually**. After each invocation, run the referenced SQL check and compare it to the expected state before invoking the next. A zero exit or recorded version is only one part of the gate.

| Step | File and expected effect | Lock or risk | Immediate gate and stop condition |
|---|---|---|---|
| `apply_step 1` | `20261118000100_membership_security.sql` updates member/admin authorization and function grants. | Low. Function replacement and ACL updates. | Check A. Both helpers must match the SQL and exclude removed memberships. Stop on role or signature drift. |
| `apply_step 2` | `20261118000200_protect_last_admin.sql` installs the protection body and keeps the compatible existing trigger. | Low with the audited trigger. Creating a missing trigger would conflict with writes. | Check A. Require the enabled trigger, matching binding and expected function body. Stop if the trigger is missing, disabled or bound differently. |
| `apply_step 3` | `20261119000100_harden_workspace_profile_access.sql` replaces recursive profile reads and revokes four client privileges. | Policy DDL may wait on active readers/writers. | Check A and the ACL matrix in §3. Require 40 false effective results and unchanged ordinary DML grants. Stop if any elevated privilege survives or policy differs. |
| `apply_step 4` | `20261119000200_protect_invitation_attribution.sql` protects `invited_by` with an invoker trigger. | Trigger DDL can conflict with invitation writes. | Check B for attribution objects. Stop if the trigger, immutable attribution behavior in its body, or client execution restrictions differ. |
| `apply_step 5` | `20261119000300_secure_invitation_acceptance.sql` installs lifecycle protection, `revoked`, unique pending-email index and token-only acceptance RPC. | Maintenance window. Constraint validation and non-concurrent index creation inside a transaction. | Rerun invitation preflight immediately before application. Then Check B and validate constraint, index, trigger and RPC ACL. Stop on any failed check. |
| `apply_step 6` | `20261119000400_harden_message_ownership.sql` binds sender to Auth, protects the workspace and publishes only message INSERT/UPDATE. | Maintenance window. Exclusive table lock and publication change. | Rerun publication preflight immediately before application. Then Check C and the ACL matrix. Stop if any publication flag, policy or trigger differs. |

## 7. Post-deploy acceptance checks

### Check A — membership, profile and last active admin

```sql
select p.oid::regprocedure as signature, pg_get_function_result(p.oid) as result,
       p.prosecdef, p.proconfig, pg_get_functiondef(p.oid) as body,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated
from pg_proc p where p.pronamespace='public'::regnamespace
  and p.proname in ('is_workspace_member','is_workspace_admin','protect_last_workspace_admin');

select tgname,tgenabled,pg_get_triggerdef(oid) as definition from pg_trigger
where tgrelid='public.workspace_members'::regclass and tgname='protect_last_workspace_admin_trigger';

select policyname,qual from pg_policies
where schemaname='public' and tablename='users' and policyname='read self or coworkers';
```

The two helpers return boolean, use `auth.uid()` and require active membership. The admin helper also requires `role = 'admin'`. Require `anon=false`, `authenticated=true` for both. The last-admin trigger must be enabled (`O`), fire before deletion and updates of role, status or workspace, and call the definer function with an empty search path. Compare the body to the migration for workspace locking, valid workspace cascade handling and the other-active-admin check. After step 3, the profile policy uses self or a visible active coworker membership and has no recursive reference to `users` in its subquery. Repeat the ACL checks in §3 for both client roles.

### Check B — invitations

```sql
select tgname,tgenabled,pg_get_triggerdef(oid) as definition from pg_trigger
where tgrelid='public.invitations'::regclass and not tgisinternal order by tgname;

select p.oid::regprocedure as signature, pg_get_function_result(p.oid) as result,
       p.prosecdef, p.proconfig,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated,
       has_function_privilege('service_role',p.oid,'EXECUTE') as service_role,
       exists (select from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x
         where x.grantee=0 and x.privilege_type='EXECUTE') as public_execute,
       pg_get_functiondef(p.oid) as body
from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in
  ('protect_invitation_attribution','enforce_invitation_lifecycle','accept_workspace_invitation');

select convalidated,pg_get_constraintdef(oid) as definition from pg_constraint
where conrelid='public.invitations'::regclass and conname='invitations_status_check';
select i.indisvalid,i.indisready,i.indisunique,pg_get_indexdef(i.indexrelid) as definition
from pg_index i join pg_class c on c.oid=i.indexrelid
where i.indrelid='public.invitations'::regclass and c.relname='invitations_pending_workspace_email_key';
```

Step 4 requires the enabled invoker attribution trigger, with empty search path and no client or PUBLIC execute grants on its function. Step 5 also requires an enabled invoker lifecycle trigger, a validated CHECK including `revoked`, and a valid, ready, unique partial index on `(workspace_id, lower(email)) WHERE status = 'pending'`. Require one `accept_workspace_invitation(uuid) → text` RPC with `SECURITY DEFINER` and empty search path. Require `authenticated=true` and `anon=false`, `service_role=false`, `public_execute=false` on the RPC. Compare all bodies and trigger bindings to the pinned files. Repeat the duplicate-pending query.

### Check C — messages and publication

```sql
select policyname,cmd,roles,qual,with_check from pg_policies
where schemaname='public' and tablename='messages' order by policyname;

select pg_get_expr(d.adbin,d.adrelid) as sender_default
from pg_attrdef d join pg_attribute a on (a.attrelid,a.attnum)=(d.adrelid,d.adnum)
where d.adrelid='public.messages'::regclass and a.attname='sender_id';

select t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) as definition,
       pg_get_functiondef(t.tgfoid) as body
from pg_trigger t where t.tgrelid='public.messages'::regclass and t.tgname='keep_message_workspace';
```

Require `sender_id` default `auth.uid()`, active-member SELECT, and sender-bound active-membership INSERT/UPDATE/DELETE. The UPDATE policy validates both row versions. Require the enabled invoker trigger that prevents changing the message's workspace. Repeat §3's publication and ACL queries. Publication flags must be `true,true,false,false` for INSERT/UPDATE/DELETE/TRUNCATE respectively, and `messages_only` must remain true.

### Safe regression smoke checks

- Repeat catalog checks A/B/C and the §3 count queries. In an existing approved test tenant with existing approved test identities, read membership/profile/message endpoints. Compare response codes and presence or absence to the tenant's expected access. For an inactive account, expect zero visible rows for its former workspace. Use a read-only client operation and log aggregate outcomes. If Production has no approved fixture tenant, record functional tenant checks as **UNKNOWN** and use the staging results.
- On the read-only connection, this auth-independent sanity check must yield `false | false`. For positive member/admin cases and rejection of removing the last admin, use the existing rollback-only security tests on the isolated rehearsal database.
- Rehearse valid invitation acceptance, replay, spoofed writes, membership revocation and Realtime delivery with the invitation and message suites on an isolated database. Production smoke checks use existing approved rows and passive subscription observation. Keep unobserved Realtime event delivery **UNKNOWN** until genuine traffic and telemetry confirm it.

```sql
select public.is_workspace_member(null::uuid), public.is_workspace_admin(null::uuid);
```

## 8. Rollback and recovery

The CLI-owned migration transaction rolls back schema changes and its history insert together if either fails or the server ends the transaction. History-table initialization may commit separately. A lost connection can hide the final commit result, so check both the catalog and ledger before retrying. Stop at the first failed gate, freeze subsequent changes and classify the failed step as unapplied, applied, or partial based on evidence. Record the error and verify against the saved catalog. Keep schema and migration history synchronized through an approved correction. Prefer a forward fix that preserves security controls.

| Migration | Safe recovery and cautions |
|---|---|
| `20261118000100` | Restore the exact captured helper definitions only if needed for recovery. Keep active-membership requirements and restricted EXECUTE. Recheck dependent RLS policies. |
| `20261118000200` | Restore the prior compatible protection body. Keep the pre-existing trigger installed and enabled. Check affected workspace admin coverage before resuming writes. |
| `20261119000100` | For profile-read failure, temporarily constrain reads to self and retain all four privilege revocations. Restoring the previous recursive policy or elevated client grants reopens the original issue. |
| `20261119000200` | Capture attribution state and prefer correcting the trigger in place. If removal is approved, stop client invitation writes first and reconcile any inviter attribution changed in the affected period. |
| `20261119000300` | Disable acceptance first if it is implicated, then reconcile rows changed after deployment. Keep accepted invitation states and valid created memberships. Preserve the pending-email uniqueness protection when possible. The old CHECK cannot be restored while `revoked` rows exist. Agree on a state mapping and review changes to invite and membership records before restoring the old constraint. |
| `20261119000400` | Keep unauthorized-sender and cross-workspace protections. If policy/default changes need repair, prefer a targeted forward fix. Keep Realtime DELETE/TRUNCATE disabled unless an authorized replacement preserves tenant isolation. Account for message writes since deployment before any restore. |

Use a restore only with the recovery owner's approval after assessing writes since the recovery point and the impact of losing them. An isolated restore is useful for validating a recovery point and extracting narrowly scoped repair data. [Supabase database backups](https://supabase.com/docs/guides/platform/backups)

## 9. Observe after deployment

- Compare API error rate and latency with the pre-deploy baseline. Watch for unexpected permission-denied spikes, message insert failures and invalid sender or workspace errors.
- Monitor invitation acceptance outcomes, duplicate-pending conflicts and unexpected admin or membership failures. Distinguish expected denials and replays from failed legitimate operations.
- Monitor authenticated Realtime INSERT/UPDATE delivery, subscription errors and reconnects. Treat missing DELETE events as the planned publication behavior.
- Check lock waits, timeout/deadlock errors and delayed transactions. Keep the maintenance window open until the agreed latency/error criteria recover and the operator records the final ledger, ACL and publication checks.
- Record observations without payloads, credentials or customer identifiers.

## 10. Deployment-day checklist

- [ ] **PRECHECK** — Commit, branch, explicit Production target, owner, counts, ACL, publication, ledger and locks verified.
- [ ] **BACKUP** — Recovery point, restore evidence, owner and catalog snapshots recorded.
- [ ] **MAINTENANCE** — Window open, concurrent deployers paused, operator and observer ready, abort budgets agreed.
- [ ] **DEPLOY** — Apply steps 1–6 individually in order, with exact ledger and object gates after each.
- [ ] **VALIDATE** — Repeat A/B/C, verify all 40 privilege results are false, run safe smoke checks and record gaps.
- [ ] **MONITOR** — Track API, invitation, membership, message, Realtime and lock indicators, then close the window.

Prepared as an operator guide. Production was not modified during preparation.
