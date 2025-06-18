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
      // Try to update gameweek status first (if function exists)
      try {
        await supabase.rpc('update_gameweek_status');
      } catch (error) {
        console.warn('Update gameweek status function not available:', error);
      }
      
      // Fetch current and next gameweeks
      const { data: gameweeks, error } = await supabase
        .from('gameweeks')
        .select('*')
        .in('status', ['active', 'upcoming'])
        .order('gameweek_number')
        .limit(5);

      if (error) throw error;

      // Find current and next gameweeks
      const current = gameweeks?.find(gw => gw.status === 'active') || null;
      const next = gameweeks?.find(gw => gw.status === 'upcoming' && (!current || gw.gameweek_number > current.gameweek_number)) || null;

      // Check if transfers are allowed
      let transfersAllowed = true;
      try {
        const { data: transfersAllowedData, error: transferError } = await supabase
          .rpc('transfers_allowed');

        if (!transferError) {
          transfersAllowed = transfersAllowedData || false;
        }
      } catch (error) {
        console.warn('Transfers allowed function not available, defaulting to true:', error);
        // Default logic: transfers allowed if gameweek is upcoming or active
        transfersAllowed = current?.status === 'upcoming' || current?.status === 'active' || false;
      }

      const now = new Date();
      let timeUntilDeadline = null;
      let timeUntilStart = null;
      let timeUntilEnd = null;
      let isGameweekActive = false;

      const relevantGameweek = current || next;
      if (relevantGameweek) {
        // Use deadline_time if available, otherwise use start_date - 2 hours
        const deadlineTime = relevantGameweek.deadline_time 
          ? new Date(relevantGameweek.deadline_time)
          : new Date(new Date(relevantGameweek.start_date || relevantGameweek.start_time).getTime() - 2 * 60 * 60 * 1000);
        
        const startTime = new Date(relevantGameweek.start_time || relevantGameweek.start_date);
        const endTime = new Date(relevantGameweek.end_time || relevantGameweek.end_date);

        timeUntilDeadline = deadlineTime.getTime() - now.getTime();
        timeUntilStart = startTime.getTime() - now.getTime();
        timeUntilEnd = endTime.getTime() - now.getTime();
        
        isGameweekActive = now >= startTime && now <= endTime;

        // Override transfers allowed based on deadline
        if (timeUntilDeadline <= 0) {
          transfersAllowed = false;
        }
      }

      // Create proper gameweek objects with all required fields
      const currentGameweek = current ? {
        gameweek_id: current.gameweek_id,
        gameweek_number: current.gameweek_number,
        name: current.name || `Gameweek ${current.gameweek_number}`,
        deadline_time: current.deadline_time || new Date(new Date(current.start_date).getTime() - 2 * 60 * 60 * 1000).toISOString(),
        start_time: current.start_time || current.start_date,
        end_time: current.end_time || current.end_date,
        is_current: true,
        is_next: false,
        is_finished: current.status === 'finalized',
        status: current.status
      } : null;

      const nextGameweek = next ? {
        gameweek_id: next.gameweek_id,
        gameweek_number: next.gameweek_number,
        name: next.name || `Gameweek ${next.gameweek_number}`,
        deadline_time: next.deadline_time || new Date(new Date(next.start_date).getTime() - 2 * 60 * 60 * 1000).toISOString(),
        start_time: next.start_time || next.start_date,
        end_time: next.end_time || next.end_date,
        is_current: false,
        is_next: true,
        is_finished: next.status === 'finalized',
        status: next.status
      } : null;

      setGameweekStatus({
        current: currentGameweek,
        next: nextGameweek,
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