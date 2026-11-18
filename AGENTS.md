<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Virtual Workspace — Backend Instructions

### Project
- Stack: Next.js 16, TypeScript, Supabase.
- Multi-tenant Virtual Office SaaS.
- Reuse existing architecture and code.
- Never rebuild working functionality unnecessarily.

### Responsibilities
- Focus on Backend, PostgreSQL, Authentication,
  RLS, Security, and Realtime.
- Do not modify frontend-owned files without approval.
- Work on feature/backend-hardening or an approved branch.

### Database Safety
- Supabase Production is strictly read-only.
- Never execute SQL writes or migrations on Production.
- Never delete or reset production data.
- Prefer a separate development database.
- Never expose .env files, tokens, or secrets.
- Ask for approval before any database changes.

### Git Safety
- Never commit, push, merge, or switch branches
  without explicit approval.
- Never push directly to main.
- Review git diff before proposing a commit.

### Workflow
1. Inspect relevant files before making changes.
2. Explain the plan briefly for complex tasks.
3. Change only files needed for the current task.
4. Preserve existing behavior.
5. Write or update tests where appropriate.
6. Run only safe local tests.
7. Report what changed and which tests ran.
8. Mark unverified findings as UNKNOWN.

### Efficiency
- Use targeted searches instead of scanning the repository.
- Avoid node_modules and .next except for the relevant
  Next.js documentation required above.
- Keep responses concise and in Arabic.
- Keep code and technical terms in English.
- Avoid generating lengthy reports unless requested.
- Stop when the requested task is complete.
