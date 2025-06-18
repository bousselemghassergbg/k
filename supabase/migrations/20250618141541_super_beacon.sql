/*
  # Fix Gameweek Management and Points System

  1. Fix gameweek finalization issues
  2. Fix fantasy team points calculation and display
  3. Fix transfer system when no active gameweek
  4. Add missing current_gameweek column to fantasy_teams
  5. Update functions to properly handle all scenarios
*/

-- Add missing current_gameweek column to fantasy_teams if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'fantasy_teams' AND column_name = 'current_gameweek'
  ) THEN
    ALTER TABLE fantasy_teams ADD COLUMN current_gameweek INTEGER DEFAULT 1;
  END IF;
END $$;

-- Add missing transfer_cost column to transactions if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'transactions' AND column_name = 'transfer_cost'
  ) THEN
    ALTER TABLE transactions ADD COLUMN transfer_cost NUMERIC DEFAULT 0;
  END IF;
END $$;

-- Update existing fantasy teams with current gameweek
UPDATE fantasy_teams 
SET current_gameweek = COALESCE(current_gameweek, 1)
WHERE current_gameweek IS NULL;

-- Fix the calculate_fantasy_team_points function
CREATE OR REPLACE FUNCTION calculate_fantasy_team_points(p_fantasy_team_id UUID, p_gameweek INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  total_points INTEGER := 0;
  player_record RECORD;
  captain_id UUID;
  vice_captain_id UUID;
  captain_points INTEGER := 0;
  substitute_record RECORD;
BEGIN
  -- Get captain and vice captain
  SELECT player_id INTO captain_id
  FROM rosters 
  WHERE fantasy_team_id = p_fantasy_team_id AND is_captain = true;
  
  SELECT player_id INTO vice_captain_id
  FROM rosters 
  WHERE fantasy_team_id = p_fantasy_team_id AND is_vice_captain = true;
  
  -- Calculate points for starting players
  FOR player_record IN
    SELECT 
      r.player_id,
      r.is_starter,
      r.is_captain,
      r.is_vice_captain,
      p.position,
      COALESCE(gs.total_points, 0) as player_points,
      COALESCE(gs.minutes_played, 0) as minutes_played
    FROM rosters r
    JOIN players p ON r.player_id = p.player_id
    LEFT JOIN gameweek_scores gs ON r.player_id = gs.player_id AND gs.gameweek = p_gameweek
    WHERE r.fantasy_team_id = p_fantasy_team_id
    ORDER BY r.is_starter DESC, gs.total_points DESC NULLS LAST
  LOOP
    IF player_record.is_starter THEN
      -- Check if player needs substitution (0 minutes played)
      IF player_record.minutes_played = 0 THEN
        -- Find substitute from bench with same position
        SELECT 
          r2.player_id,
          COALESCE(gs2.total_points, 0) as sub_points,
          COALESCE(gs2.minutes_played, 0) as sub_minutes
        INTO substitute_record
        FROM rosters r2
        JOIN players p2 ON r2.player_id = p2.player_id
        LEFT JOIN gameweek_scores gs2 ON r2.player_id = gs2.player_id AND gs2.gameweek = p_gameweek
        WHERE r2.fantasy_team_id = p_fantasy_team_id 
        AND r2.is_starter = false
        AND p2.position = player_record.position
        AND COALESCE(gs2.minutes_played, 0) > 0
        ORDER BY gs2.total_points DESC NULLS LAST
        LIMIT 1;
        
        -- Use substitute points if found
        IF substitute_record.player_id IS NOT NULL THEN
          total_points := total_points + substitute_record.sub_points;
          
          -- Apply captain bonus if this was the captain
          IF player_record.is_captain THEN
            captain_points := substitute_record.sub_points;
          END IF;
        END IF;
      ELSE
        -- Use starter's points
        total_points := total_points + player_record.player_points;
        
        -- Apply captain bonus
        IF player_record.is_captain THEN
          captain_points := player_record.player_points;
        END IF;
      END IF;
    END IF;
  END LOOP;
  
  -- Apply captain multiplier (double points)
  IF captain_points > 0 THEN
    total_points := total_points + captain_points;
  ELSIF vice_captain_id IS NOT NULL THEN
    -- Fallback to vice captain if captain didn't play
    SELECT COALESCE(gs.total_points, 0) INTO captain_points
    FROM gameweek_scores gs
    WHERE gs.player_id = vice_captain_id AND gs.gameweek = p_gameweek;
    
    IF captain_points > 0 THEN
      total_points := total_points + captain_points;
    END IF;
  END IF;
  
  RETURN total_points;
END;
$$;

-- Enhanced finalize_gameweek function
CREATE OR REPLACE FUNCTION finalize_gameweek(p_gameweek INTEGER)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  team_record RECORD;
  team_points INTEGER;
  rank_counter INTEGER := 1;
BEGIN
  -- Check if all matches in gameweek are completed
  IF EXISTS (
    SELECT 1 FROM real_matches 
    WHERE gameweek = p_gameweek 
    AND status != 'completed'
  ) THEN
    RAISE EXCEPTION 'Cannot finalize gameweek %. Not all matches are completed.', p_gameweek;
  END IF;
  
  -- Calculate points for all fantasy teams
  FOR team_record IN
    SELECT fantasy_team_id, league_id
    FROM fantasy_teams
    ORDER BY fantasy_team_id
  LOOP
    -- Calculate team points
    team_points := calculate_fantasy_team_points(team_record.fantasy_team_id, p_gameweek);
    
    -- Insert or update gameweek points
    INSERT INTO fantasy_team_gameweek_points (fantasy_team_id, gameweek, points)
    VALUES (team_record.fantasy_team_id, p_gameweek, team_points)
    ON CONFLICT (fantasy_team_id, gameweek) 
    DO UPDATE SET points = EXCLUDED.points;
    
    -- Update fantasy team points
    UPDATE fantasy_teams 
    SET 
      total_points = COALESCE(total_points, 0) + team_points - COALESCE(gameweek_points, 0),
      gameweek_points = team_points,
      current_gameweek = p_gameweek + 1,
      transfers_made_this_gw = 0,
      transfers_banked = LEAST(COALESCE(transfers_banked, 0) + 1, 1)
    WHERE fantasy_team_id = team_record.fantasy_team_id;
  END LOOP;
  
  -- Calculate league rankings
  FOR team_record IN
    SELECT DISTINCT league_id FROM fantasy_teams WHERE league_id IS NOT NULL
  LOOP
    rank_counter := 1;
    FOR team_record IN
      SELECT ft.fantasy_team_id
      FROM fantasy_teams ft
      JOIN fantasy_team_gameweek_points fgp ON ft.fantasy_team_id = fgp.fantasy_team_id
      WHERE ft.league_id = team_record.league_id AND fgp.gameweek = p_gameweek
      ORDER BY fgp.points DESC
    LOOP
      UPDATE fantasy_team_gameweek_points
      SET rank_in_league = rank_counter
      WHERE fantasy_team_id = team_record.fantasy_team_id AND gameweek = p_gameweek;
      
      rank_counter := rank_counter + 1;
    END LOOP;
  END LOOP;
  
  -- Update overall rankings based on total points
  rank_counter := 1;
  FOR team_record IN
    SELECT fantasy_team_id
    FROM fantasy_teams
    ORDER BY total_points DESC, fantasy_team_id
  LOOP
    UPDATE fantasy_teams
    SET rank = rank_counter
    WHERE fantasy_team_id = team_record.fantasy_team_id;
    
    rank_counter := rank_counter + 1;
  END LOOP;
  
  -- Set gameweek status to finalized
  UPDATE gameweeks 
  SET 
    status = 'finalized',
    is_finished = true,
    is_current = false
  WHERE gameweek_number = p_gameweek;
  
  -- Set next gameweek as current if it exists
  UPDATE gameweeks 
  SET 
    status = 'active',
    is_current = true,
    is_next = false
  WHERE gameweek_number = p_gameweek + 1;
  
  -- Update is_next for the gameweek after that
  UPDATE gameweeks 
  SET is_next = true
  WHERE gameweek_number = p_gameweek + 2;
  
  RAISE NOTICE 'Gameweek % finalized successfully', p_gameweek;
END;
$$;

-- Enhanced update_gameweek_status function
CREATE OR REPLACE FUNCTION update_gameweek_status()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_time TIMESTAMPTZ := now();
  current_gw INTEGER;
  next_gw INTEGER;
BEGIN
  -- Reset all current/next flags
  UPDATE gameweeks SET is_current = false, is_next = false;
  
  -- Find current gameweek based on time or status
  SELECT gameweek_number INTO current_gw
  FROM gameweeks
  WHERE (
    (current_time >= start_time AND current_time <= end_time) OR
    status = 'active'
  )
  ORDER BY gameweek_number
  LIMIT 1;
  
  -- If no active gameweek found, get the next upcoming one
  IF current_gw IS NULL THEN
    SELECT gameweek_number INTO current_gw
    FROM gameweeks
    WHERE status IN ('upcoming', 'locked') OR current_time < start_time
    ORDER BY gameweek_number
    LIMIT 1;
  END IF;
  
  -- Set current gameweek
  IF current_gw IS NOT NULL THEN
    UPDATE gameweeks SET is_current = true
    WHERE gameweek_number = current_gw;
    
    -- Find next gameweek
    SELECT gameweek_number INTO next_gw
    FROM gameweeks
    WHERE gameweek_number > current_gw
    ORDER BY gameweek_number
    LIMIT 1;
    
    -- Set next gameweek
    IF next_gw IS NOT NULL THEN
      UPDATE gameweeks SET is_next = true
      WHERE gameweek_number = next_gw;
    END IF;
  END IF;
  
  -- Update status based on time and current status
  UPDATE gameweeks SET
    status = CASE
      WHEN status = 'finalized' THEN 'finalized'
      WHEN deadline_time IS NOT NULL AND current_time < deadline_time THEN 'upcoming'
      WHEN deadline_time IS NOT NULL AND current_time >= deadline_time AND current_time < start_time THEN 'locked'
      WHEN start_time IS NOT NULL AND current_time >= start_time AND current_time <= end_time THEN 'active'
      WHEN end_time IS NOT NULL AND current_time > end_time THEN 'finalized'
      ELSE status
    END
  WHERE deadline_time IS NOT NULL AND start_time IS NOT NULL AND end_time IS NOT NULL;
END;
$$;

-- Enhanced transfers_allowed function
CREATE OR REPLACE FUNCTION transfers_allowed()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_time TIMESTAMPTZ := now();
  deadline_passed BOOLEAN := false;
  has_active_gw BOOLEAN := false;
BEGIN
  -- Check if there's an active gameweek
  SELECT EXISTS (
    SELECT 1 FROM gameweeks
    WHERE status = 'active'
  ) INTO has_active_gw;
  
  -- If no active gameweek, check if we're before the next gameweek deadline
  IF NOT has_active_gw THEN
    SELECT EXISTS (
      SELECT 1 FROM gameweeks
      WHERE status IN ('upcoming', 'locked')
      AND deadline_time IS NOT NULL
      AND current_time >= deadline_time
    ) INTO deadline_passed;
    
    -- If no upcoming gameweek with deadline, allow transfers
    IF NOT deadline_passed THEN
      SELECT NOT EXISTS (
        SELECT 1 FROM gameweeks
        WHERE status = 'upcoming'
        AND deadline_time IS NOT NULL
        AND current_time >= deadline_time
      ) INTO deadline_passed;
      
      RETURN NOT deadline_passed;
    END IF;
  ELSE
    -- If there's an active gameweek, transfers are locked
    RETURN false;
  END IF;
  
  RETURN NOT deadline_passed;
END;
$$;

-- Function to get the latest finalized gameweek
CREATE OR REPLACE FUNCTION get_latest_finalized_gameweek()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  latest_gw INTEGER;
BEGIN
  SELECT MAX(gameweek_number) INTO latest_gw
  FROM gameweeks
  WHERE status = 'finalized';
  
  RETURN COALESCE(latest_gw, 0);
END;
$$;

-- Function to get current or latest gameweek for points display
CREATE OR REPLACE FUNCTION get_display_gameweek()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_gw INTEGER;
  latest_finalized INTEGER;
BEGIN
  -- Try to get current active gameweek
  SELECT gameweek_number INTO current_gw
  FROM gameweeks
  WHERE status = 'active'
  LIMIT 1;
  
  -- If no active gameweek, get latest finalized
  IF current_gw IS NULL THEN
    SELECT MAX(gameweek_number) INTO latest_finalized
    FROM gameweeks
    WHERE status = 'finalized';
    
    RETURN COALESCE(latest_finalized, 1);
  END IF;
  
  RETURN current_gw;
END;
$$;

-- Update existing gameweek data to ensure consistency
UPDATE gameweeks SET
  deadline_time = COALESCE(deadline_time::timestamptz, start_date - INTERVAL '2 hours'),
  start_time = COALESCE(start_time::timestamptz, start_date),
  end_time = COALESCE(end_time::timestamptz, end_date),
  name = COALESCE(name, 'Gameweek ' || gameweek_number),
  is_finished = CASE WHEN status = 'finalized' THEN true ELSE false END;

-- Fix fantasy team total points by recalculating from gameweek points
UPDATE fantasy_teams 
SET total_points = COALESCE((
  SELECT SUM(points) 
  FROM fantasy_team_gameweek_points 
  WHERE fantasy_team_gameweek_points.fantasy_team_id = fantasy_teams.fantasy_team_id
), 0);

-- Update gameweek points to show latest finalized gameweek points
UPDATE fantasy_teams 
SET gameweek_points = COALESCE((
  SELECT points 
  FROM fantasy_team_gameweek_points 
  WHERE fantasy_team_gameweek_points.fantasy_team_id = fantasy_teams.fantasy_team_id
  AND gameweek = get_latest_finalized_gameweek()
), 0);

-- Ensure all fantasy teams have proper current_gameweek
UPDATE fantasy_teams 
SET current_gameweek = COALESCE((
  SELECT MAX(gameweek_number) + 1
  FROM gameweeks
  WHERE status = 'finalized'
), 1)
WHERE current_gameweek IS NULL OR current_gameweek = 0;

-- Run the update function to set proper gameweek status
SELECT update_gameweek_status();

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_fantasy_team_gameweek_points_lookup ON fantasy_team_gameweek_points(fantasy_team_id, gameweek);
CREATE INDEX IF NOT EXISTS idx_gameweeks_status_lookup ON gameweeks(status, gameweek_number);
CREATE INDEX IF NOT EXISTS idx_gameweek_scores_lookup ON gameweek_scores(player_id, gameweek);