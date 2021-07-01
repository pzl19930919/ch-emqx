%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_mgmt_http).

-export([ start_listeners/0
        , stop_listeners/0
        , start_listener/1
        , stop_listener/1
        ]).

%% Authorization
-export([authorize_appid/1]).

-include_lib("emqx/include/emqx.hrl").

-define(APP, emqx_management).

%%--------------------------------------------------------------------
%% Start/Stop Listeners
%%--------------------------------------------------------------------

start_listeners() ->
    lists:foreach(fun start_listener/1, listeners()).

stop_listeners() ->
    lists:foreach(fun stop_listener/1, listeners()).

start_listener({Proto, Port, Options}) ->
    application:ensure_all_started(minirest),
    Modules =
        [ emqx_mgmt_api_apps
        , emqx_mgmt_api_alarms
        , emqx_mgmt_api_banned
        , emqx_mgmt_api_clients
        , emqx_mgmt_api_listeners
        , emqx_mgmt_api_metrics
        , emqx_mgmt_api_nodes
        , emqx_mgmt_api_plugins
        , emqx_mgmt_api_publish
        , emqx_mgmt_api_routes
        , emqx_mgmt_api_stats],
    Authorization = {?MODULE, authorize_appid},
    RanchOptions = ranch_opts(Port, Options),
    MinirestOptions =
        #{root_path => "/v5"
        , modules => Modules
        , https => Proto =:= https
        , authorization => Authorization},
    minirest:start(listener_name(Proto), maps:merge(MinirestOptions, RanchOptions)).

ranch_opts(Port, Options0) ->
    Options = lists:foldl(fun({K, _V}, Acc) when K =:= max_connections orelse K =:= num_acceptors ->
                                 Acc;
                             ({inet6, true}, Acc) -> [inet6 | Acc];
                             ({inet6, false}, Acc) -> Acc;
                             ({ipv6_v6only, true}, Acc) -> [{ipv6_v6only, true} | Acc];
                             ({ipv6_v6only, false}, Acc) -> Acc;
                             ({K, V}, Acc)->
                                 [{K, V} | Acc]
                          end, [], Options0),
    maps:from_list([{port, Port} | Options]).

stop_listener({Proto, Port, _}) ->
    io:format("Stop http:management listener on ~s successfully.~n",[format(Port)]),
    minirest:stop(listener_name(Proto)).

listeners() ->
    emqx_config:get([?APP, listeners], []).

listener_name(Proto) ->
    list_to_atom(atom_to_list(Proto) ++ ":management").

authorize_appid(Req) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, AppId, AppSecret} ->
            case emqx_mgmt_auth:is_authorized(AppId, AppSecret) of
                true -> ok;
                false -> {401}
            end;
         _ -> {401}
    end.

format(Port) when is_integer(Port) ->
    io_lib:format("0.0.0.0:~w", [Port]);
format({Addr, Port}) when is_list(Addr) ->
    io_lib:format("~s:~w", [Addr, Port]);
format({Addr, Port}) when is_tuple(Addr) ->
    io_lib:format("~s:~w", [inet:ntoa(Addr), Port]).
