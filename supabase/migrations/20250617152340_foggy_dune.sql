/*
  # Gameweek Management System

  1. New Tables
    - `gameweeks` - Manages gameweek periods and status
    - `fantasy_team_gameweek_points` - Stores team points per gameweek
  
  2. Functions
    - `generate_gameweeks_from_matches()` - Auto-generates gameweeks from real matches
    - `calculate_fantasy_team_points()` - Calculates team points with substitutions
    - `finalize_gameweek()` - Finalizes gameweek and calculates ranks
    - `set_gameweek_status()` - Controls gameweek status
    - `setup_general_league()` - Creates default league
    - `create_default_fantasy_team()` - Auto-creates teams for new users
  
  3. Security
    - Enable RLS on new tables
    - Add appropriate policies
*/

-- Create gameweeks table if it doesn't exist
CREATE TABLE IF NOT EXISTS gameweeks (
  gameweek_id SERIAL PRIMARY KEY,
  gameweek_number INTEGER UNIQUE NOT NULL,
  start_date TIMESTAMPTZ NOT NULL,
  end_date TIMESTAMPTZ NOT NULL,
  status TEXT DEFAULT 'upcoming' CHECK (status IN ('upcoming', 'active', 'locked', 'finalized')),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Create fantasy_team_gameweek_points table if it doesn't exist
CREATE TABLE IF NOT EXISTS fantasy_team_gameweek_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fantasy_team_id UUID REFERENCES fantasy_teams(fantasy_team_id) ON DELETE CASCADE,
  gameweek INTEGER NOT NULL,
  points INTEGER DEFAULT 0,
  rank_in_league INTEGER,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(fantasy_team_id, gameweek)
);

-- Enable RLS
ALTER TABLE gameweeks ENABLE ROW LEVEL SECURITY;
ALTER TABLE fantasy_team_gameweek_points ENABLE ROW LEVEL SECURITY;

-- Policies for gameweeks (read-only for users, full access for authenticated)
CREATE POLICY "Anyone can read gameweeks"
  ON gameweeks
  FOR SELECT
  TO authenticated
  USING (true);

-- Policies for fantasy_team_gameweek_points
CREATE POLICY "Users can read their own team points"
  ON fantasy_team_gameweek_points
  FOR SELECT
  TO authenticated
  USING (
    fantasy_team_id IN (
      SELECT fantasy_team_id FROM fantasy_teams WHERE user_id = auth.uid()
    )
  );

-- Function to generate gameweeks from matches
CREATE OR REPLACE FUNCTION generate_gameweeks_from_matches()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  match_record RECORD;
  gw_start DATE;
  gw_end DATE;
BEGIN
  -- Clear existing gameweeks
  DELETE FROM gameweeks;
  
  -- Generate gameweeks based on real_matches
  FOR match_record IN 
    SELECT DISTINCT gameweek 
    FROM real_matches 
    WHERE gameweek IS NOT NULL 
    ORDER BY gameweek
  LOOP
    -- Calculate start and end dates for this gameweek
    SELECT 
      MIN(DATE(match_date)) - INTERVAL '1 day',
      MAX(DATE(match_date)) + INTERVAL '1 day'
    INTO gw_start, gw_end
    FROM real_matches 
    WHERE gameweek = match_record.gameweek 
    AND match_date IS NOT NULL;
    
    -- If no dates found, use defaults
    IF gw_start IS NULL THEN
      gw_start := CURRENT_DATE + (match_record.gameweek - 1) * INTERVAL '7 days';
      gw_end := gw_start + INTERVAL '7 days';
    END IF;
    
    -- Insert gameweek
    INSERT INTO gameweeks (gameweek_number, start_date, end_date, status)
    VALUES (
      match_record.gameweek,
      gw_start::TIMESTAMPTZ,
      gw_end::TIMESTAMPTZ,
      CASE 
        WHEN match_record.gameweek = 1 THEN 'finalized'
        WHEN match_record.gameweek = 2 THEN 'active'
        ELSE 'upcoming'
      END
    )
    ON CONFLICT (gameweek_number) DO UPDATE SET
      start_date = EXCLUDED.start_date,
      end_date = EXCLUDED.end_date;
  END LOOP;
  
  RAISE NOTICE 'Generated % gameweeks', (SELECT COUNT(*) FROM gameweeks);
END;
$$;

-- Function to set gameweek status
CREATE OR REPLACE FUNCTION set_gameweek_status(p_gameweek INTEGER, p_status TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE gameweeks 
  SET status = p_status 
  WHERE gameweek_number = p_gameweek;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Gameweek % not found', p_gameweek;
  END IF;
  
  RAISE NOTICE 'Gameweek % status set to %', p_gameweek, p_status;
END;
$$;

-- Function to calculate fantasy team points for a gameweek
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
  formation_counts RECORD;
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

-- Function to finalize a gameweek
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
    
    -- Update fantasy team total points
    UPDATE fantasy_teams 
    SET 
      total_points = total_points + team_points,
      gameweek_points = team_points,
      current_gameweek = p_gameweek + 1,
      transfers_made_this_gw = 0,
      transfers_banked = LEAST(transfers_banked + 1, 1)
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
  
  -- Update overall rankings
  rank_counter := 1;
  FOR team_record IN
    SELECT fantasy_team_id
    FROM fantasy_teams
    ORDER BY total_points DESC
  LOOP
    UPDATE fantasy_teams
    SET rank = rank_counter
    WHERE fantasy_team_id = team_record.fantasy_team_id;
    
    rank_counter := rank_counter + 1;
  END LOOP;
  
  -- Set gameweek status to finalized
  UPDATE gameweeks SET status = 'finalized' WHERE gameweek_number = p_gameweek;
  
  RAISE NOTICE 'Gameweek % finalized successfully', p_gameweek;
END;
$$;

-- Function to setup general league
CREATE OR REPLACE FUNCTION setup_general_league()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  general_league_id UUID;
BEGIN
  -- Check if general league already exists
  SELECT league_id INTO general_league_id
  FROM leagues
  WHERE name = 'General League'
  LIMIT 1;
  
  -- Create general league if it doesn't exist
  IF general_league_id IS NULL THEN
    INSERT INTO leagues (
      name,
      max_participants,
      current_participants,
      entry_fee,
      prize_pool,
      budget_limit,
      status,
      gameweek_current
    ) VALUES (
      'General League',
      1000,
      0,
      0,
      0,
      100,
      'active',
      1
    ) RETURNING league_id INTO general_league_id;
  END IF;
  
  RETURN general_league_id;
END;
$$;

-- Function to create default fantasy team for new users
CREATE OR REPLACE FUNCTION create_default_fantasy_team(p_user_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  general_league_id UUID;
  new_team_id UUID;
  username_val TEXT;
BEGIN
  -- Get or create general league
  general_league_id := setup_general_league();
  
  -- Get username
  SELECT username INTO username_val FROM users WHERE user_id = p_user_id;
  
  -- Create fantasy team
  INSERT INTO fantasy_teams (
    user_id,
    league_id,
    team_name,
    total_points,
    gameweek_points,
    rank,
    budget_remaining,
    transfers_remaining,
    current_gameweek
  ) VALUES (
    p_user_id,
    general_league_id,
    COALESCE(username_val, 'Team') || '''s Team',
    0,
    0,
    1,
    100,
    1,
    1
  ) RETURNING fantasy_team_id INTO new_team_id;
  
  -- Update league participant count
  UPDATE leagues 
  SET current_participants = current_participants + 1
  WHERE league_id = general_league_id;
  
  RETURN new_team_id;
END;
$$;

-- Generate initial gameweeks from existing matches
SELECT generate_gameweeks_from_matches();

-- Handle existing gameweek 1 data
DO $$
DECLARE
  team_record RECORD;
  team_points INTEGER;
BEGIN
  -- If gameweek 1 has completed matches, calculate points for existing teams
  IF EXISTS (SELECT 1 FROM real_matches WHERE gameweek = 1 AND status = 'completed') THEN
    
    -- Calculate points for all existing fantasy teams for gameweek 1
    FOR team_record IN
      SELECT fantasy_team_id FROM fantasy_teams
    LOOP
      team_points := calculate_fantasy_team_points(team_record.fantasy_team_id, 1);
      
      -- Insert gameweek points
      INSERT INTO fantasy_team_gameweek_points (fantasy_team_id, gameweek, points)
      VALUES (team_record.fantasy_team_id, 1, team_points)
      ON CONFLICT (fantasy_team_id, gameweek) DO NOTHING;
    END LOOP;
    
    -- Set gameweek 1 as finalized if all matches are completed
    IF NOT EXISTS (SELECT 1 FROM real_matches WHERE gameweek = 1 AND status != 'completed') THEN
      UPDATE gameweeks SET status = 'finalized' WHERE gameweek_number = 1;
    END IF;
  END IF;
END $$;

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_gameweeks_number ON gameweeks(gameweek_number);
CREATE INDEX IF NOT EXISTS idx_gameweeks_status ON gameweeks(status);
CREATE INDEX IF NOT EXISTS idx_fantasy_team_gameweek_points_team ON fantasy_team_gameweek_points(fantasy_team_id);
CREATE INDEX IF NOT EXISTS idx_fantasy_team_gameweek_points_gameweek ON fantasy_team_gameweek_points(gameweek);