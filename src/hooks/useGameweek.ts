import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';

interface Gameweek {
  gameweek_id: number;
  gameweek_number: number;
  name: string;
  deadline_time: string;
  start_time: string;
  end_time: string;
  is_current: boolean;
  is_next: boolean;
  is_finished: boolean;
  status: string;
}

interface GameweekStatus {
  current: Gameweek | null;
  next: Gameweek | null;
  transfersAllowed: boolean;
  timeUntilDeadline: number | null;
  timeUntilStart: number | null;
  timeUntilEnd: number | null;
  isGameweekActive: boolean;
}

export function useGameweek() {
  const [gameweekStatus, setGameweekStatus] = useState<GameweekStatus>({
    current: null,
    next: null,
    transfersAllowed: true,
    timeUntilDeadline: null,
    timeUntilStart: null,
    timeUntilEnd: null,
    isGameweekActive: false,
  });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchGameweekStatus();
    
    // Update every minute
    const interval = setInterval(fetchGameweekStatus, 60000);
    
    return () => clearInterval(interval);
  }, []);

  const fetchGameweekStatus = async () => {
    try {
      // Update gameweek status first
      try {
        await supabase.rpc('update_gameweek_status');
      } catch (error) {
        console.warn('Update gameweek status function not available:', error);
      }
      
      // Fetch current and next gameweeks
      const { data: gameweeks, error } = await supabase
        .from('gameweeks')
        .select('*')
        .order('gameweek_number')
        .limit(10);

      if (error) throw error;

      // Find current and next gameweeks
      const current = gameweeks?.find(gw => gw.is_current) || null;
      const next = gameweeks?.find(gw => gw.is_next) || null;

      // Check if transfers are allowed
      let transfersAllowed = true;
      try {
        const { data: transfersAllowedData, error: transferError } = await supabase
          .rpc('transfers_allowed');

        if (!transferError) {
          transfersAllowed = transfersAllowedData || false;
        }
      } catch (error) {
        console.warn('Transfers allowed function not available:', error);
        // Default logic: transfers allowed if no active gameweek or before deadline
        const relevantGameweek = current || next;
        if (relevantGameweek) {
          const now = new Date();
          const deadlineTime = new Date(relevantGameweek.deadline_time);
          transfersAllowed = now < deadlineTime && relevantGameweek.status !== 'active';
        }
      }

      const now = new Date();
      let timeUntilDeadline = null;
      let timeUntilStart = null;
      let timeUntilEnd = null;
      let isGameweekActive = false;

      const relevantGameweek = current || next;
      if (relevantGameweek) {
        const deadlineTime = new Date(relevantGameweek.deadline_time);
        const startTime = new Date(relevantGameweek.start_time);
        const endTime = new Date(relevantGameweek.end_time);

        timeUntilDeadline = deadlineTime.getTime() - now.getTime();
        timeUntilStart = startTime.getTime() - now.getTime();
        timeUntilEnd = endTime.getTime() - now.getTime();
        
        isGameweekActive = relevantGameweek.status === 'active';
      }

      setGameweekStatus({
        current,
        next,
        transfersAllowed,
        timeUntilDeadline: timeUntilDeadline && timeUntilDeadline > 0 ? timeUntilDeadline : null,
        timeUntilStart: timeUntilStart && timeUntilStart > 0 ? timeUntilStart : null,
        timeUntilEnd: timeUntilEnd && timeUntilEnd > 0 ? timeUntilEnd : null,
        isGameweekActive,
      });
    } catch (error) {
      console.error('Error fetching gameweek status:', error);
    } finally {
      setLoading(false);
    }
  };

  const formatTimeRemaining = (milliseconds: number | null): string => {
    if (!milliseconds || milliseconds <= 0) return '';
    
    const days = Math.floor(milliseconds / (1000 * 60 * 60 * 24));
    const hours = Math.floor((milliseconds % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    const minutes = Math.floor((milliseconds % (1000 * 60 * 60)) / (1000 * 60));
    
    if (days > 0) {
      return `${days}d ${hours}h ${minutes}m`;
    } else if (hours > 0) {
      return `${hours}h ${minutes}m`;
    } else {
      return `${minutes}m`;
    }
  };

  return {
    gameweekStatus,
    loading,
    formatTimeRemaining,
    refreshStatus: fetchGameweekStatus,
  };
}