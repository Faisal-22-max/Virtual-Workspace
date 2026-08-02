# Virtual Workspace

An immersive virtual office platform that gives distributed teams real-time presence and lightweight, spontaneous communication.

## Tech Stack

- **Frontend:** Next.js (App Router, TypeScript, Tailwind CSS)
- **Backend:** Supabase (PostgreSQL, Auth, Realtime)

## Prerequisites

- Node.js 18+
- Git

## Getting Started

```bash
git clone https://github.com/Faisal-22-max/Virtual-Workspace.git
cd Virtual-Workspace
npm install
```

Request the `.env.local` file from the project owner and place it in the project root before running the app.

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Project Structure

```
app/
  ├── lib/supabase.ts    # Supabase client
  ├── layout.tsx
  └── page.tsx
```

## Database

Core tables: `workspaces`, `users`, `workspace_members`, `invitations`. All tables are protected with Row Level Security (RLS).

## Contributing

- Work on feature branches, not directly on `main`.
- Submit changes via Pull Request.
- Review any database migration before applying it.

## License

Private — All rights reserved.