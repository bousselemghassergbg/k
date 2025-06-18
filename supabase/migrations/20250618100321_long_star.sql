/*
  # Create Overall League

  1. Create Overall League
    - Creates a league called "Overall" for all users except admin
    - Moves all existing fantasy teams to this league
  
  2. Security
    - Maintains existing RLS policies
*/

-- Create the Overall league
INSERT INTO leagues (
  name,
  creator_id,
  max_participants,
  current_participants,
  entry_fee,
  prize_pool,
  budget_limit,
  status,
  gameweek_current
) VALUES (
  'Overall',
  NULL,
  10000,
  0,
  0,
  0,
  100,
  'active',
  1
) ON CONFLICT (name) DO NOTHING;

-- Get the Overall league ID
DO $$
DECLARE
  overall_league_id UUID;
  team_count INTEGER;
BEGIN
  -- Get the Overall league ID
  SELECT league_id INTO overall_league_id
  FROM leagues
  WHERE name = 'Overall'
  LIMIT 1;
  
  -- Move all fantasy teams (except admin's) to the Overall league
  UPDATE fantasy_teams 
  SET league_id = overall_league_id
  WHERE user_id != (
    SELECT user_id FROM users WHERE username = 'admin' OR email = 'bousselemghassen03@gmail.com' LIMIT 1
  )
  AND (league_id IS NULL OR league_id != overall_league_id);
  
  -- Update the participant count
  SELECT COUNT(*) INTO team_count
  FROM fantasy_teams
  WHERE league_id = overall_league_id;
  
  UPDATE leagues
  SET current_participants = team_count
  WHERE league_id = overall_league_id;
  
  RAISE NOTICE 'Overall league created with % participants', team_count;
END $$;