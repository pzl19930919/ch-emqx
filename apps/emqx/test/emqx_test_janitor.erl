%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_test_janitor).

-behaviour(gen_server).

%% `gen_server' API
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% API
-export([
    start_link/0,
    push_on_exit_callback/2
]).

%%----------------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------------

start_link() ->
    gen_server:start_link(?MODULE, self(), []).

push_on_exit_callback(Server, Callback) when is_function(Callback, 0) ->
    gen_server:call(Server, {push, Callback}).

%%----------------------------------------------------------------------------------
%% `gen_server' API
%%----------------------------------------------------------------------------------

init(Parent) ->
    process_flag(trap_exit, true),
    {ok, #{callbacks => [], owner => Parent}}.

terminate(_Reason, #{callbacks := Callbacks}) ->
    lists:foreach(fun(Fun) -> Fun() end, Callbacks).

handle_call({push, Callback}, _From, State = #{callbacks := Callbacks}) ->
    {reply, ok, State#{callbacks := [Callback | Callbacks]}};
handle_call(_Req, _From, State) ->
    {reply, error, State}.

handle_cast(_Req, State) ->
    {noreply, State}.

handle_info({'EXIT', Parent, _Reason}, State = #{owner := Parent}) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {noreply, State}.
