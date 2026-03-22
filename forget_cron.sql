-- ============================================================
-- STEP 1: Create the forget_log table
-- Run this in Supabase SQL Editor
-- ============================================================
CREATE TABLE IF NOT EXISTS public.forget_log (
  id bigint generated always as identity primary key,
  run_at timestamptz default now(),
  daily_memories_deleted int default 0,
  emotional_memories_deleted int default 0,
  dreams_deleted int default 0,
  details text default ''
);

ALTER TABLE public.forget_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow anon read forget_log" ON public.forget_log;
CREATE POLICY "Allow anon read forget_log" ON public.forget_log
  FOR SELECT TO anon USING (true);

-- ============================================================
-- STEP 2: Create the forget function
-- ============================================================
CREATE OR REPLACE FUNCTION public.run_daily_forget()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_daily int;
  v_emotional int;
  v_dreams int;
  v_daily_detail text;
  v_emotional_detail text;
  v_dream_detail text;
  v_all_details text;
BEGIN
  -- 1. daily memories: not recalled in 15 days
  --    NEVER delete layer='core'
  WITH deleted AS (
    DELETE FROM public.memories
    WHERE layer = 'daily'
      AND last_recalled < now() - interval '15 days'
    RETURNING id, title
  )
  SELECT count(*),
         coalesce(string_agg(id::text || ':' || coalesce(title, '?'), '; '), '')
  INTO v_daily, v_daily_detail
  FROM deleted;

  -- 2. dreams: past decay period AND importance <= 2
  --    importance >= 3 are NEVER auto-deleted
  WITH deleted AS (
    DELETE FROM public.dreams
    WHERE importance <= 2
      AND last_mentioned < now() - (decay_days || ' days')::interval
    RETURNING id, title
  )
  SELECT count(*),
         coalesce(string_agg(id::text || ':' || coalesce(title, '?'), '; '), '')
  INTO v_dreams, v_dream_detail
  FROM deleted;

  -- 3. emotional memories: not recalled in 60 days AND recall_count <= 1
  --    NEVER delete layer='core'
  WITH deleted AS (
    DELETE FROM public.memories
    WHERE layer = 'emotional'
      AND last_recalled < now() - interval '60 days'
      AND recall_count <= 1
    RETURNING id, title
  )
  SELECT count(*),
         coalesce(string_agg(id::text || ':' || coalesce(title, '?'), '; '), '')
  INTO v_emotional, v_emotional_detail
  FROM deleted;

  -- Build details string
  v_all_details := '';
  IF v_daily > 0 THEN
    v_all_details := 'daily(' || v_daily || '): ' || v_daily_detail;
  END IF;
  IF v_dreams > 0 THEN
    IF v_all_details != '' THEN v_all_details := v_all_details || ' | '; END IF;
    v_all_details := v_all_details || 'dreams(' || v_dreams || '): ' || v_dream_detail;
  END IF;
  IF v_emotional > 0 THEN
    IF v_all_details != '' THEN v_all_details := v_all_details || ' | '; END IF;
    v_all_details := v_all_details || 'emotional(' || v_emotional || '): ' || v_emotional_detail;
  END IF;
  IF v_all_details = '' THEN
    v_all_details := 'nothing to forget today';
  END IF;

  -- Log
  INSERT INTO public.forget_log
    (daily_memories_deleted, emotional_memories_deleted, dreams_deleted, details)
  VALUES
    (v_daily, v_emotional, v_dreams, v_all_details);
END;
$$;

-- ============================================================
-- STEP 3: Schedule with pg_cron
-- Beijing 04:00 = UTC 20:00
-- ============================================================
SELECT cron.schedule(
  'daily-forget',
  '0 20 * * *',
  'SELECT public.run_daily_forget()'
);
