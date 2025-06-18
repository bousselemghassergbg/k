/*
  # Fix missing columns and functions

  1. Add missing columns to tables
    - Add `is_current`, `is_next`, `deadline_time`, `start_time`, `end_time`, `name` to gameweeks
    - Add `transfers_made_this_gw`, `transfers_banked` to fantasy_teams
  
  2. Add missing functions
    - `update_gameweek_status()` - Updates current/next gameweek status
    - `transfers_allowed()` - Checks if transfers are currently allowed
  
  3. Update existing data
    - Set appropriate gameweek statuses
    - Initialize transfer columns
*/

-- Add missing columns to gameweeks table
DO $$
BEGIN
  -- Add is_current column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'gameweeks' AND column_name = 'is_current'
  ) THEN
    ALTER TABLE gameweeks ADD COLUMN is_current BOOLEAN DEFAULT false;
  END IF;

  -- Add is_next column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'gameweeks' AND column_name = 'is_next'
  ) THEN
    ALTER TABLE gameweeks ADD COLUMN is_next BOOLEAN DEFAULT false;
  END IF;

  -- Add deadline_time column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'gameweeks' AND column_name = 'deadline_time'
  ) THEN
    ALTER TABLE gameweeks ADD COLUMN deadline_time TIMESTAMPTZ;
  END IF;

  -- Add start_time column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'gameweeks' AND column_name = 'start_time'
  ) THEN
    ALTER TABLE gameweeks ADD COLUMN start_time TIMESTAMPTZ;
  END IF;

  -- Add end_time column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'gameweeks' AND column_name = 'end_time'
  ) THEN
    ALTER TABLE gameweeks ADD COLUMN end_time TIMESTAMPTZ;
  END IF;

  -- Add name column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'gameweeks' AND column_name = 'name'
  ) THEN
    ALTER TABLE gameweeks ADD COLUMN name TEXT;
  END IF;

  -- Add is_finished column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'gameweeks' AND column_name = 'is_finished'
  ) THEN
    ALTER TABLE gameweeks ADD COLUMN is_finished BOOLEAN DEFAULT false;
  END IF;
END $$;

-- Add missing columns to fantasy_teams table
DO $$
BEGIN
  -- Add transfers_made_this_gw column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'fantasy_teams' AND column_name = 'transfers_made_this_gw'
  ) THEN
    ALTER TABLE fantasy_teams ADD COLUMN transfers_made_this_gw INTEGER DEFAULT 0;
  END IF;

  -- Add transfers_banked column
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'fantasy_teams' AND column_name = 'transfers_banked'
  ) THEN
    ALTER TABLE fantasy_teams ADD COLUMN transfers_banked INTEGER DEFAULT 0;
  END IF;
END $$;

-- Update existing gameweeks with proper data
UPDATE gameweeks SET
  deadline_time = COALESCE(deadline_time, start_date - INTERVAL '2 hours'),
  start_time = COALESCE(start_time, start_date),
  end_time = COALESCE(end_time, end_date),
  name = COALESCE(name, 'Gameweek ' || gameweek_number),
  is_finished = CASE WHEN status = 'finalized' THEN true ELSE false END;

-- Set current and next gameweeks based on status
UPDATE gameweeks SET is_current = false, is_next = false;

-- Set the active gameweek as current
UPDATE gameweeks SET is_current = true 
WHERE status = 'active' 
AND gameweek_number = (
  SELECT MIN(gameweek_number) FROM gameweeks WHERE status = 'active'
);

-- Set the next upcoming gameweek as next
UPDATE gameweeks SET is_next = true 
WHERE status = 'upcoming' 
AND gameweek_number = (
  SELECT MIN(gameweek_number) FROM gameweeks WHERE status = 'upcoming'
);

-- If no active gameweek, set the first upcoming as current
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM gameweeks WHERE is_current = true) THEN
    UPDATE gameweeks SET is_current = true 
    WHERE gameweek_number = (
      SELECT MIN(gameweek_number) FROM gameweeks WHERE status = 'upcoming'
    );
  END IF;
END $$;

-- Initialize transfer columns for existing teams
UPDATE fantasy_teams SET
  transfers_made_this_gw = COALESCE(transfers_made_this_gw, 0),
  transfers_banked = COALESCE(transfers_banked, 0);

-- Function to update gameweek status automatically
CREATE OR REPLACE FUNCTION update_gameweek_status()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_time TIMESTAMPTZ := now();
BEGIN
  -- Reset all current/next flags
  UPDATE gameweeks SET is_current = false, is_next = false;
  
  -- Set current gameweek (active or should be active based on time)
  UPDATE gameweeks SET is_current = true
  WHERE gameweek_number = (
    SELECT gameweek_number FROM gameweeks
    WHERE current_time >= start_time AND current_time <= end_time
    ORDER BY gameweek_number
    LIMIT 1
  );
  
  -- If no active gameweek found, set the next upcoming one as current
  IF NOT EXISTS (SELECT 1 FROM gameweeks WHERE is_current = true) THEN
    UPDATE gameweeks SET is_current = true
    WHERE gameweek_number = (
      SELECT MIN(gameweek_number) FROM gameweeks
      WHERE current_time < start_time
    );
  END IF;
  
  -- Set next gameweek
  UPDATE gameweeks SET is_next = true
  WHERE gameweek_number = (
    SELECT MIN(gameweek_number) FROM gameweeks
    WHERE gameweek_number > (SELECT gameweek_number FROM gameweeks WHERE is_current = true LIMIT 1)
  );
  
  -- Update status based on time
  UPDATE gameweeks SET
    status = CASE
      WHEN current_time < deadline_time THEN 'upcoming'
      WHEN current_time >= deadline_time AND current_time < start_time THEN 'locked'
      WHEN current_time >= start_time AND current_time <= end_time THEN 'active'
      WHEN current_time > end_time THEN 'finalized'
      ELSE status
    END
  WHERE deadline_time IS NOT NULL AND start_time IS NOT NULL AND end_time IS NOT NULL;
END;
$$;

-- Function to check if transfers are allowed
CREATE OR REPLACE FUNCTION transfers_allowed()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_time TIMESTAMPTZ := now();
  deadline_passed BOOLEAN := false;
BEGIN
  -- Check if we're past the deadline for the current/next gameweek
  SELECT EXISTS (
    SELECT 1 FROM gameweeks
    WHERE (is_current = true OR is_next = true)
    AND deadline_time IS NOT NULL
    AND current_time >= deadline_time
  ) INTO deadline_passed;
  
  RETURN NOT deadline_passed;
END;
$$;

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_gameweeks_current ON gameweeks(is_current) WHERE is_current = true;
CREATE INDEX IF NOT EXISTS idx_gameweeks_next ON gameweeks(is_next) WHERE is_next = true;
CREATE INDEX IF NOT EXISTS idx_gameweeks_times ON gameweeks(deadline_time, start_time, end_time);