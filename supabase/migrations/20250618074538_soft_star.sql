-- Update existing gameweeks with missing columns
UPDATE gameweeks SET
  deadline_time = COALESCE(deadline_time, start_date - INTERVAL '2 hours'),
  start_time = COALESCE(start_time, start_date),
  end_time = COALESCE(end_time, end_date),
  name = COALESCE(name, 'Gameweek ' || gameweek_number),
  is_finished = CASE WHEN status = 'finalized' THEN true ELSE false END,
  is_current = CASE WHEN status = 'active' THEN true ELSE false END,
  is_next = false;

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
    UPDATE gameweeks SET is_current = true, status = 'active'
    WHERE gameweek_number = (
      SELECT MIN(gameweek_number) FROM gameweeks WHERE status = 'upcoming'
    );
  END IF;
END $$;

-- Update fantasy teams with missing transfer columns
UPDATE fantasy_teams SET
  transfers_made_this_gw = COALESCE(transfers_made_this_gw, 0),
  transfers_banked = COALESCE(transfers_banked, 0)
WHERE transfers_made_this_gw IS NULL OR transfers_banked IS NULL;