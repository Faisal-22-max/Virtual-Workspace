
-- Migration: Protect the last active workspace admin
-- Depends on: public.workspaces, public.workspace_members
-- Existing trigger is preserved if already installed.

BEGIN;

CREATE OR REPLACE FUNCTION public.protect_last_workspace_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- Non-active admins and employees are not protected.
    IF OLD.role <> 'admin'
       OR OLD.status <> 'active' THEN

        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;

        RETURN NEW;
    END IF;

    -- No check needed if active admin coverage remains.
    IF TG_OP = 'UPDATE' THEN
        IF NEW.role = 'admin'
           AND NEW.status = 'active'
           AND NEW.workspace_id = OLD.workspace_id THEN
            RETURN NEW;
        END IF;
    END IF;

    -- Serialize changes to admins in this workspace.
    PERFORM 1
    FROM public.workspaces
    WHERE id = OLD.workspace_id
    FOR UPDATE;

    -- Allow ON DELETE CASCADE when deleting the workspace.
    IF NOT FOUND THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;

        RAISE EXCEPTION 'Workspace does not exist';
    END IF;

    -- Another active admin must remain.
    IF NOT EXISTS (
        SELECT 1
        FROM public.workspace_members wm
        WHERE wm.workspace_id = OLD.workspace_id
          AND wm.id <> OLD.id
          AND wm.role = 'admin'
          AND wm.status = 'active'
    ) THEN
        RAISE EXCEPTION
            'Cannot remove or demote the last active workspace admin'
            USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

-- Create the trigger only if it does not exist.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid =
            'public.workspace_members'::regclass
          AND tgname =
            'protect_last_workspace_admin_trigger'
          AND NOT tgisinternal
    ) THEN
        CREATE TRIGGER protect_last_workspace_admin_trigger
        BEFORE DELETE OR UPDATE OF role, status, workspace_id
        ON public.workspace_members
        FOR EACH ROW
        EXECUTE FUNCTION public.protect_last_workspace_admin();
    END IF;
END;
$$;

COMMIT;

-- ROLLBACK (manual, if required):
-- DROP TRIGGER IF EXISTS
-- protect_last_workspace_admin_trigger
-- ON public.workspace_members;
--
-- DROP FUNCTION IF EXISTS
-- public.protect_last_workspace_admin();
