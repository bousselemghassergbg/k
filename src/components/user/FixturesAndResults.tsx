import React, { useState, useEffect } from 'react';
import { Calendar, Clock, CheckCircle, XCircle, Filter, Search } from 'lucide-react';
import { supabase } from '../../lib/supabase';

interface Match {
  match_id: string;
  gameweek: number;
  home_team_name: string;
  away_team_name: string;
  home_score: number | null;
  away_score: number | null;
  match_date: string | null;
  status: 'scheduled' | 'live' | 'completed' | 'postponed';
}

export default function FixturesAndResults() {
  const [matches, setMatches] = useState<Match[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedGameweek, setSelectedGameweek] = useState<number | null>(null);
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [searchTerm, setSearchTerm] = useState('');

  useEffect(() => {
    fetchMatches();
  }, []);

  const fetchMatches = async () => {
    try {
      const { data, error } = await supabase
        .from('real_matches')
        .select(`
          match_id,
          gameweek,
          home_score,
          away_score,
          match_date,
          status,
          home_team:home_team_id (
            name
          ),
          away_team:away_team_id (
            name
          )
        `)
        .order('gameweek', { ascending: false })
        .order('match_date', { ascending: false });

      if (error) throw error;

      const matchesWithTeamNames = data?.map(match => ({
        match_id: match.match_id,
        gameweek: match.gameweek,
        home_team_name: match.home_team?.name || 'TBD',
        away_team_name: match.away_team?.name || 'TBD',
        home_score: match.home_score,
        away_score: match.away_score,
        match_date: match.match_date,
        status: match.status,
      })) || [];

      setMatches(matchesWithTeamNames);

      // Auto-select the latest gameweek
      if (matchesWithTeamNames.length > 0) {
        setSelectedGameweek(matchesWithTeamNames[0].gameweek);
      }
    } catch (error) {
      console.error('Error fetching matches:', error);
    } finally {
      setLoading(false);
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'scheduled': return 'bg-blue-100 text-blue-800';
      case 'live': return 'bg-green-100 text-green-800';
      case 'completed': return 'bg-gray-100 text-gray-800';
      case 'postponed': return 'bg-red-100 text-red-800';
      default: return 'bg-gray-100 text-gray-800';
    }
  };

  const getStatusIcon = (status: string) => {
    switch (status) {
      case 'scheduled': return <Calendar className="h-4 w-4" />;
      case 'live': return <Clock className="h-4 w-4" />;
      case 'completed': return <CheckCircle className="h-4 w-4" />;
      case 'postponed': return <XCircle className="h-4 w-4" />;
      default: return <Calendar className="h-4 w-4" />;
    }
  };

  const gameweeks = [...new Set(matches.map(match => match.gameweek))].sort((a, b) => b - a);

  const filteredMatches = matches.filter(match => {
    const matchesGameweek = !selectedGameweek || match.gameweek === selectedGameweek;
    const matchesStatus = !statusFilter || match.status === statusFilter;
    const matchesSearch = !searchTerm || 
      match.home_team_name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      match.away_team_name.toLowerCase().includes(searchTerm.toLowerCase());
    
    return matchesGameweek && matchesStatus && matchesSearch;
  });

  if (loading) {
    return (
      <div className="flex justify-center items-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-emerald-600"></div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="bg-white rounded-xl shadow-sm p-6">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">Fixtures & Results</h1>
        <p className="text-gray-600">
          View upcoming fixtures and past results filtered by gameweek.
        </p>
      </div>

      {/* Filters */}
      <div className="bg-white rounded-xl shadow-sm p-6">
        <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Gameweek
            </label>
            <select
              value={selectedGameweek || ''}
              onChange={(e) => setSelectedGameweek(e.target.value ? parseInt(e.target.value) : null)}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-emerald-500 focus:border-emerald-500"
            >
              <option value="">All Gameweeks</option>
              {gameweeks.map(gw => (
                <option key={gw} value={gw}>
                  Gameweek {gw}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Status
            </label>
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-emerald-500 focus:border-emerald-500"
            >
              <option value="">All Status</option>
              <option value="scheduled">Scheduled</option>
              <option value="live">Live</option>
              <option value="completed">Completed</option>
              <option value="postponed">Postponed</option>
            </select>
          </div>

          <div className="md:col-span-2">
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Search Teams
            </label>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 h-4 w-4" />
              <input
                type="text"
                placeholder="Search for teams..."
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
                className="pl-10 pr-4 py-2 w-full border border-gray-300 rounded-lg focus:ring-2 focus:ring-emerald-500 focus:border-emerald-500"
              />
            </div>
          </div>
        </div>
      </div>

      {/* Matches */}
      <div className="bg-white rounded-xl shadow-sm overflow-hidden">
        <div className="p-6 border-b border-gray-200">
          <h2 className="text-xl font-semibold text-gray-900">
            {selectedGameweek ? `Gameweek ${selectedGameweek} Matches` : 'All Matches'}
            <span className="text-sm font-normal text-gray-500 ml-2">
              ({filteredMatches.length} matches)
            </span>
          </h2>
        </div>

        {filteredMatches.length === 0 ? (
          <div className="text-center py-12">
            <Calendar className="h-12 w-12 text-gray-400 mx-auto mb-4" />
            <h3 className="text-lg font-medium text-gray-900 mb-2">No matches found</h3>
            <p className="text-gray-500">Try adjusting your filters to see more matches.</p>
          </div>
        ) : (
          <div className="divide-y divide-gray-200">
            {filteredMatches.map((match) => (
              <div key={match.match_id} className="p-6 hover:bg-gray-50 transition-colors">
                <div className="flex items-center justify-between">
                  <div className="flex items-center space-x-4">
                    <div className="text-center">
                      <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-emerald-100 text-emerald-800">
                        GW {match.gameweek}
                      </span>
                    </div>
                    
                    <div className="flex items-center space-x-4 min-w-0 flex-1">
                      <div className="text-right min-w-0 flex-1">
                        <div className="font-medium text-gray-900 truncate">
                          {match.home_team_name}
                        </div>
                      </div>
                      
                      <div className="flex items-center space-x-2 px-4">
                        {match.status === 'completed' && match.home_score !== null && match.away_score !== null ? (
                          <div className="text-center">
                            <div className="text-lg font-bold text-gray-900">
                              {match.home_score} - {match.away_score}
                            </div>
                            <div className="text-xs text-gray-500">FT</div>
                          </div>
                        ) : match.status === 'live' ? (
                          <div className="text-center">
                            <div className="text-lg font-bold text-green-600">
                              {match.home_score || 0} - {match.away_score || 0}
                            </div>
                            <div className="text-xs text-green-600 font-medium">LIVE</div>
                          </div>
                        ) : (
                          <div className="text-center">
                            <div className="text-lg font-bold text-gray-400">vs</div>
                            {match.match_date && (
                              <div className="text-xs text-gray-500">
                                {new Date(match.match_date).toLocaleDateString()}
                              </div>
                            )}
                          </div>
                        )}
                      </div>
                      
                      <div className="min-w-0 flex-1">
                        <div className="font-medium text-gray-900 truncate">
                          {match.away_team_name}
                        </div>
                      </div>
                    </div>
                  </div>

                  <div className="flex items-center space-x-4">
                    {match.match_date && (
                      <div className="text-sm text-gray-500 text-right">
                        <div>{new Date(match.match_date).toLocaleDateString()}</div>
                        <div>{new Date(match.match_date).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</div>
                      </div>
                    )}
                    
                    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${getStatusColor(match.status)}`}>
                      {getStatusIcon(match.status)}
                      <span className="ml-1 capitalize">{match.status}</span>
                    </span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}