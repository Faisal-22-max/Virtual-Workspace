"""Run the invitation race against the disposable Colima Supabase database."""

import subprocess
import time
import uuid


PSQL = [
    "docker", "--context", "colima", "exec", "-i", "supabase_db_vw-local-baseline",
    "psql", "-X", "-h", "/var/run/postgresql", "-U", "postgres", "-d", "postgres",
    "-v", "ON_ERROR_STOP=1", "-Atq", "-f", "-",
]


def sql(statement):
    result = subprocess.run(PSQL, input=statement, capture_output=True, text=True, timeout=25)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def open_session():
    return subprocess.Popen(
        PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


def send(session, statement):
    session.stdin.write(statement + "\n")
    session.stdin.flush()


def finish(session):
    if session.stdin is not None:
        session.stdin.close()
        session.stdin = None
    stdout, stderr = session.communicate(timeout=35)
    if session.returncode:
        raise RuntimeError(stderr.strip())
    return stdout.strip()


def wait_until(statement, description):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if sql(statement) == "t":
            return
        time.sleep(0.1)
    raise RuntimeError(description)


def main():
    workspace, invitee, token = (uuid.uuid4() for _ in range(3))
    email = f"invitation-race-{invitee}@example.com"
    holder_name = f"invite-race-holder-{workspace}"
    waiter_name = f"invite-race-waiter-{workspace}"
    acceptance = f"""
      set local statement_timeout = '30s';
      set local idle_in_transaction_session_timeout = '45s';
      set local role authenticated;
      set local request.jwt.claim.sub = '{invitee}';
      set local request.jwt.claims = '{{"sub":"{invitee}","role":"authenticated"}}';
      select public.accept_workspace_invitation('{token}');
    """

    holder = waiter = None
    try:
        sql(f"""
          begin;
          insert into auth.users (id, email, email_confirmed_at)
          values ('{invitee}', '{email}', now());
          insert into public.workspaces (id, name, slug)
          values ('{workspace}', 'Invitation race fixture', 'invitation-race-{workspace}');
          insert into public.invitations (token, workspace_id, email)
          values ('{token}', '{workspace}', '{email}');
          commit;
        """)

        holder = open_session()
        send(holder, f"begin; {acceptance} set local application_name = '{holder_name}';")
        wait_until(f"""
          select exists (
            select 1 from pg_stat_activity
            where application_name = '{holder_name}' and state = 'idle in transaction'
          );
        """, "The first acceptance did not reach its transaction barrier")

        waiter = open_session()
        send(waiter, f"begin; set local application_name = '{waiter_name}'; {acceptance} commit;")
        wait_until(f"""
          select exists (
            select 1 from pg_stat_activity as waiter
            join pg_stat_activity as holder on holder.pid = any(pg_blocking_pids(waiter.pid))
            where waiter.application_name = '{waiter_name}' and holder.application_name = '{holder_name}'
          );
        """, "The second acceptance did not block on the first transaction")

        send(holder, "commit;")
        if (finish(holder), finish(waiter)) != ("accepted", "invalid_invitation"):
            raise RuntimeError("Expected exactly one successful acceptance and one rejected replay")

        final_state = sql(f"""
          select count(membership.id), invitation.status, min(membership.role), min(membership.status)
          from public.invitations as invitation
          join public.users as profile on profile.auth_id = '{invitee}'
          left join public.workspace_members as membership
            on membership.user_id = profile.id and membership.workspace_id = invitation.workspace_id
          where invitation.token = '{token}' and invitation.workspace_id = '{workspace}'
          group by invitation.status;
        """)
        if final_state != "1|accepted|employee|active":
            raise RuntimeError("Expected one active employee membership and one accepted invitation")
    finally:
        try:
            for session in (holder, waiter):
                if session is not None and session.poll() is None:
                    finish(session)
        finally:
            sql(f"""
              begin;
              delete from public.workspaces where id = '{workspace}';
              delete from auth.users where id = '{invitee}';
              commit;
            """)

    print("PASS I31 concurrent attempts yielded one acceptance and one rejected replay")
    print("PASS I32 one active employee membership and one accepted invitation")


if __name__ == "__main__":
    main()
