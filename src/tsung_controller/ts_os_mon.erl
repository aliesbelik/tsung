%%%  This code was developped by Mickael Remond
%%%  <mickael.remond@erlang-fr.org> and contributors (their names can
%%%  be found in the CONTRIBUTORS file).  Copyright (C) 2003 Mickael
%%%  Remond
%%%
%%%  This program is free software; you can redistribute it and/or modify
%%%  it under the terms of the GNU General Public License as published by
%%%  the Free Software Foundation; either version 2 of the License, or
%%%  (at your option) any later version.
%%%
%%%  This program is distributed in the hope that it will be useful,
%%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%  GNU General Public License for more details.
%%%
%%%  You should have received a copy of the GNU General Public License
%%%  along with this program; if not, write to the Free Software
%%%  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
%%%

%%%  Created :  23 Dec 2003 by Mickael Remond <mickael.remond@erlang-fr.org>

%%----------------------------------------------------------------------
%% HEADER ts_os_mon
%% COPYRIGHT Mickael Remond (C) 2003
%% PURPOSE Monitor CPU, memory consumption and network traffic
%%         on a cluster of machines
%% DESCRIPTION
%%   TODO ...
%%----------------------------------------------------------------------
%%%  In addition, as a special exception, you have the permission to
%%%  link the code of this program with any library released under
%%%  the EPL license and distribute linked combinations including
%%% the two.

-module(ts_os_mon).
-author('mickael.remond@erlang-fr.org').
-modifiedby('nicolas@niclux.org').
-vc('$Id$ ').

-behaviour(gen_server).


%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("ts_profile.hrl").
-include("ts_os_mon.hrl").

%%--------------------------------------------------------------------
%% External exports
-export([start/0, start/1, stop/0, activate/0, send/2 ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


-define(SERVER, ts_os_mon).
-define(OTP_TIMEOUT, infinity).
-define(TIMEOUT, 30000).
-define(OPTIONS, [{timeout,?TIMEOUT}]).

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: activate/0
%% Purpose: This is used by tsung to start the cluster monitor service
%% It will only be started if there are cluster/monitor@host element
%% in the config file.
%%--------------------------------------------------------------------
activate() ->
    case ts_config_server:get_monitor_hosts() of
        [] ->
           ?LOG("os_mon disabled",?NOTICE),
            ok;
        Hosts ->
            gen_server:cast(?SERVER, {activate, Hosts})
    end.

%%% send data back to the controlling node
send(Mon_Server, Data) when is_pid(Mon_Server) ->
    Mon_Server ! {add, Data};
send(Mon_Server, Data) ->
    gen_server:cast(Mon_Server, {add, Data}).

%%--------------------------------------------------------------------
%% Function: start/1
%% Description: Starts the server, with a list of the hosts in the
%%              cluster to monitor
%%--------------------------------------------------------------------
start() ->
    ?LOG("starting os_mon",?NOTICE),
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], ?OPTIONS).

start(Args) ->
    ?LOGF("starting os_mon with args ~p",[Args],?NOTICE),
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, ?OPTIONS).

%%--------------------------------------------------------------------
%% Function: stop/0
%% Description: Stop the server
%%--------------------------------------------------------------------
stop() ->
    gen_server:call(?SERVER, {stop}, ?OTP_TIMEOUT).




%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init({Mon_Server, Interval}) ->
    ?LOG(" os_mon started",?NOTICE),
    %% to get the EXIT signal from spawn processes on remote nodes
    process_flag(trap_exit,true),
    {ok, #os_mon{mon_server=Mon_Server, pids=dict:new(),interval=Interval}};
init(_) ->
    init({{global, ts_mon},?INTERVAL}).

%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call({stop}, _From, State) ->
    {stop, normal, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast({activate, Hosts}, State) ->
    NewState = active_host(Hosts,State),
    {noreply, NewState};

handle_cast(Msg, State) ->
    ?LOGF("handle cast: unknown msg ~p~n",[Msg],?WARN),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({timeout, _Ref, send_snmp_request},  State ) ->
    SNMP_Pids = dict:fetch_keys(dict:filter(fun(_K,{snmp,_})-> true;
                                               (_,_)       -> false
                                            end, State#os_mon.pids)),
    ts_os_mon_snmp:get_data(SNMP_Pids,State),
    {noreply, State#os_mon{timer=undefined}};

% response from the SNMP server
handle_info({snmp_msg, Msg, Ip, Udp}, State) ->
    ts_os_mon_snmp:parse({snmp_msg, Msg, Ip, Udp}, State);

handle_info({'EXIT', From, Reason}, State) ->
    ?LOGF("received exit from ~p with reason ~p~n",[From, Reason],?ERR),
    %% get type  of died pid
    {Type, Node} = dict:fetch(From, State#os_mon.pids),
    Module = list_to_atom("ts_os_mon_" ++ atom_to_list(Type)),
    Module:restart({From, Node}, Reason, State);
handle_info(Info, State) ->
    ?LOGF("handle info: unknown msg ~p~n",[Info],?WARN),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(normal, State) ->
%%     ?LOGF("Terminating ts_os_mon, stop beams: ~p~n",[Nodes],?NOTICE),
    Pids = dict:fetch_keys(State#os_mon.pids),
    Stop= fun(Pid) when is_pid(Pid)->
                  {Type,Node}=dict:fetch(Pid,State#os_mon.pids),
                  Module= list_to_atom("ts_os_mon_" ++ atom_to_list(Type)),
                  Module:stop(Node,State)
                  end,
    lists:foreach(Stop, Pids),
    ok;
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------




%%--------------------------------------------------------------------
%% Function: active_host/2
%% Purpose: Activate monitoring
%%--------------------------------------------------------------------
%% FIXME: start remote beams in parallel
active_host([], State) ->
    State;
%% monitoring using snmp
active_host([{HostStr, {Type, Options}} | HostList], State=#os_mon{pids=Pids}) ->
    Module= list_to_atom("ts_os_mon_" ++ atom_to_list(Type)),
    NewPids = case Module:init(HostStr,Options, State) of
                  {ok, {Pid, Node}} ->
                      dict:store(Pid,{Type, Node},Pids);
                  {error, _Reason} ->
                      Pids
              end,
    active_host(HostList, State#os_mon{pids=NewPids}).


