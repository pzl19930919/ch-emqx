%%--------------------------------------------------------------------
%% Copyright (c) 2018-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_banned).

-behaviour(gen_server).

-include("emqx.hrl").
-include("logger.hrl").
-include("types.hrl").


%% Mnesia bootstrap
-export([mnesia/1]).

-boot_mnesia({mnesia, [boot]}).

-export([start_link/0, stop/0]).

-export([ check/1
        , check_api_banned/1
        , create/1
        , look_up/1
        , delete/1
        , info/1
        , format/1
        , parse/1
        , to_timestamp/1
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-elvis([{elvis_style, state_record_and_type, disable}]).

-define(BANNED_TAB, ?MODULE).

%%--------------------------------------------------------------------
%% Mnesia bootstrap
%%--------------------------------------------------------------------

mnesia(boot) ->
    ok = mria:create_table(?BANNED_TAB, [
                {type, set},
                {rlog_shard, ?COMMON_SHARD},
                {storage, disc_copies},
                {record_name, banned},
                {attributes, record_info(fields, banned)},
                {storage_properties, [{ets, [{read_concurrency, true}]}]}]).

%% @doc Start the banned server.
-spec(start_link() -> startlink_ret()).
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% for tests
-spec(stop() -> ok).
stop() -> gen_server:stop(?MODULE).

-spec(check(emqx_types:clientinfo()) -> boolean()).
check(ClientInfo) ->
    do_check({clientid, maps:get(clientid, ClientInfo, undefined)})
        orelse do_check({username, maps:get(username, ClientInfo, undefined)})
            orelse do_check({peerhost, maps:get(peerhost, ClientInfo, undefined)}).

do_check({_, undefined}) ->
    false;
do_check(Who) when is_tuple(Who) ->
    case mnesia:dirty_read(?BANNED_TAB, Who) of
        [] -> false;
        [#banned{until = Until}] ->
            Until > erlang:system_time(second)
    end.

format(#banned{who = Who0,
               by = By,
               reason = Reason,
               at = At,
               until = Until}) ->
    {As, Who} = maybe_format_host(Who0),
    #{
        as     => As,
        who    => Who,
        by     => By,
        reason => Reason,
        at     => to_rfc3339(At),
        until  => to_rfc3339(Until)
    }.

parse(Params) ->
    Who    = pares_who(Params),
    By     = maps:get(<<"by">>, Params, <<"mgmt_api">>),
    Reason = maps:get(<<"reason">>, Params, <<"">>),
    At     = parse_time(maps:get(<<"at">>, Params, undefined), erlang:system_time(second)),
    Until  = parse_time(maps:get(<<"until">>, Params, undefined), At + 5 * 60),
    #banned{
        who    = Who,
        by     = By,
        reason = Reason,
        at     = At,
        until  = Until
    }.

pares_who(#{as := As, who := Who}) ->
    pares_who(#{<<"as">> => As, <<"who">> => Who});
pares_who(#{<<"as">> := peerhost, <<"who">> := Peerhost0}) ->
    {ok, Peerhost} = inet:parse_address(binary_to_list(Peerhost0)),
    {peerhost, Peerhost};
pares_who(#{<<"as">> := As, <<"who">> := Who}) ->
    {As, Who}.

parse_time(undefined, Default) ->
    Default;
parse_time(Rfc3339, _Default) ->
    to_timestamp(Rfc3339).

maybe_format_host({peerhost, Host}) ->
    AddrBinary = list_to_binary(inet:ntoa(Host)),
    {peerhost, AddrBinary};
maybe_format_host({As, Who}) ->
    {As, Who}.

to_rfc3339(Timestamp) ->
    list_to_binary(calendar:system_time_to_rfc3339(Timestamp, [{unit, second}])).

to_timestamp(Rfc3339) when is_binary(Rfc3339) ->
    to_timestamp(binary_to_list(Rfc3339));
to_timestamp(Rfc3339) ->
    calendar:rfc3339_to_system_time(Rfc3339, [{unit, second}]).

-spec(create(emqx_types:banned() | map()) ->
    {ok, emqx_types:banned()} | {error, {already_exist, emqx_types:banned()}}).
create(#{who    := Who,
         by     := By,
         reason := Reason,
         at     := At,
         until  := Until}) ->
    Banned = #banned{
        who = Who,
        by = By,
        reason = Reason,
        at = At,
        until = Until
    },
    create(Banned);

create(Banned = #banned{who = Who})  ->
    case look_up(Who) of
        [] ->
            mria:dirty_write(?BANNED_TAB, Banned),
            {ok, Banned};
        [OldBanned = #banned{until = Until}] ->
            case Until < erlang:system_time(second) of
                true ->
                    {error, {already_exist, OldBanned}};
                false ->
                    mria:dirty_write(?BANNED_TAB, Banned),
                    {ok, Banned}
            end
    end.

look_up(Who) when is_map(Who) ->
    look_up(pares_who(Who));
look_up(Who) ->
    mnesia:dirty_read(?BANNED_TAB, Who).

-spec(delete({clientid, emqx_types:clientid()}
           | {username, emqx_types:username()}
           | {peerhost, emqx_types:peerhost()}
           | {api_user, binary()}) -> ok).
delete(Who) when is_map(Who)->
    delete(pares_who(Who));
delete(Who) ->
    mria:dirty_delete(?BANNED_TAB, Who).

info(InfoKey) ->
    mnesia:table_info(?BANNED_TAB, InfoKey).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, ensure_expiry_timer(#{expiry_timer => undefined})}.

handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_msg", cast => Msg}),
    {noreply, State}.

handle_info({timeout, TRef, expire}, State = #{expiry_timer := TRef}) ->
    _ = mria:transaction(?COMMON_SHARD, fun expire_banned_items/1, [erlang:system_time(second)]),
    {noreply, ensure_expiry_timer(State), hibernate};

handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {noreply, State}.

terminate(_Reason, #{expiry_timer := TRef}) ->
    emqx_misc:cancel_timer(TRef).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% api user & app id banned
%%--------------------------------------------------------------------

check_api_banned(User) ->
    case look_up({api_user, User}) of
        {error, not_found} ->
            new_api_banned(User);
        {ok, #banned{reason = R}} when R < 10 ->
            update_api_banned(User, R + 1);
        {ok, #banned{until = Until}} ->
            case Until - erlang:system_time(second) of
                Interval when Interval > 0 ->
                    {lock_user, {User, Interval}};
                _ ->
                    delete({api_user, User})
            end
    end.

new_api_banned(User) ->
    Now = erlang:system_time(second),
    NewBanned = #banned{
        who = {api_user, User},
        by = <<"emqx_dashboard">>,
        reason = 1,
        at = Now,
        until = Now + 60
    },
    emqx_banned:create(NewBanned).

update_api_banned(User, Count) ->
    Now = erlang:system_time(second),
    NewBanned = #banned{
        who = {api_user, User},
        by = <<"emqx_dashboard">>,
        reason = Count,
        at = Now,
        until = Now + 300
    },
    emqx_banned:create(NewBanned).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

-ifdef(TEST).
ensure_expiry_timer(State) ->
    State#{expiry_timer := emqx_misc:start_timer(10, expire)}.
-else.
ensure_expiry_timer(State) ->
    State#{expiry_timer := emqx_misc:start_timer(timer:minutes(1), expire)}.
-endif.

expire_banned_items(Now) ->
    mnesia:foldl(
      fun(B = #banned{until = Until}, _Acc) when Until < Now ->
              mnesia:delete_object(?BANNED_TAB, B, sticky_write);
         (_, _Acc) -> ok
      end, ok, ?BANNED_TAB).
