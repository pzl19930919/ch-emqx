%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_rule_index_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

t_insert(_) ->
    Tab = new(),
    true = emqx_rule_index:insert(<<"sensor/1/metric/2">>, t_insert_1, <<>>, Tab),
    true = emqx_rule_index:insert(<<"sensor/+/#">>, t_insert_2, <<>>, Tab),
    true = emqx_rule_index:insert(<<"sensor/#">>, t_insert_3, <<>>, Tab),
    ?assertEqual(<<"sensor/#">>, topic(match(<<"sensor">>, Tab))),
    ?assertEqual(t_insert_3, id(match(<<"sensor">>, Tab))),
    true = ets:delete(Tab).

t_match(_) ->
    Tab = new(),
    true = emqx_rule_index:insert(<<"sensor/1/metric/2">>, t_match_1, <<>>, Tab),
    true = emqx_rule_index:insert(<<"sensor/+/#">>, t_match_2, <<>>, Tab),
    true = emqx_rule_index:insert(<<"sensor/#">>, t_match_3, <<>>, Tab),
    ?assertMatch(
        [<<"sensor/#">>, <<"sensor/+/#">>],
        [topic(M) || M <- matches(<<"sensor/1">>, Tab)]
    ),
    true = ets:delete(Tab).

t_match2(_) ->
    Tab = new(),
    true = emqx_rule_index:insert(<<"#">>, t_match2_1, <<>>, Tab),
    true = emqx_rule_index:insert(<<"+/#">>, t_match2_2, <<>>, Tab),
    true = emqx_rule_index:insert(<<"+/+/#">>, t_match2_3, <<>>, Tab),
    ?assertEqual(
        [<<"#">>, <<"+/#">>, <<"+/+/#">>],
        [topic(M) || M <- matches(<<"a/b/c">>, Tab)]
    ),
    ?assertEqual(
        false,
        emqx_rule_index:match(<<"$SYS/broker/zenmq">>, Tab)
    ),
    true = ets:delete(Tab).

t_match3(_) ->
    Tab = new(),
    Records = [
        {<<"d/#">>, t_match3_1},
        {<<"a/b/+">>, t_match3_2},
        {<<"a/#">>, t_match3_3},
        {<<"#">>, t_match3_4},
        {<<"$SYS/#">>, t_match3_sys}
    ],
    lists:foreach(
        fun({Topic, ID}) -> emqx_rule_index:insert(Topic, ID, <<>>, Tab) end,
        Records
    ),
    Matched = matches(<<"a/b/c">>, Tab),
    case length(Matched) of
        3 -> ok;
        _ -> error({unexpected, Matched})
    end,
    ?assertEqual(
        t_match3_sys,
        id(match(<<"$SYS/a/b/c">>, Tab))
    ),
    true = ets:delete(Tab).

t_match4(_) ->
    Tab = new(),
    Records = [{<<"/#">>, t_match4_1}, {<<"/+">>, t_match4_2}, {<<"/+/a/b/c">>, t_match4_3}],
    lists:foreach(
        fun({Topic, ID}) -> emqx_rule_index:insert(Topic, ID, <<>>, Tab) end,
        Records
    ),
    ?assertEqual(
        [<<"/#">>, <<"/+">>],
        [topic(M) || M <- matches(<<"/">>, Tab)]
    ),
    ?assertEqual(
        [<<"/#">>, <<"/+/a/b/c">>],
        [topic(M) || M <- matches(<<"/0/a/b/c">>, Tab)]
    ),
    true = ets:delete(Tab).

t_match5(_) ->
    Tab = new(),
    T = <<"a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z">>,
    Records = [
        {<<"#">>, t_match5_1},
        {<<T/binary, "/#">>, t_match5_2},
        {<<T/binary, "/+">>, t_match5_3}
    ],
    lists:foreach(
        fun({Topic, ID}) -> emqx_rule_index:insert(Topic, ID, <<>>, Tab) end,
        Records
    ),
    ?assertEqual(
        [<<"#">>, <<T/binary, "/#">>],
        [topic(M) || M <- matches(T, Tab)]
    ),
    ?assertEqual(
        [<<"#">>, <<T/binary, "/#">>, <<T/binary, "/+">>],
        [topic(M) || M <- matches(<<T/binary, "/1">>, Tab)]
    ),
    true = ets:delete(Tab).

t_match6(_) ->
    Tab = new(),
    T = <<"a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z">>,
    W = <<"+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/#">>,
    emqx_rule_index:insert(W, ID = t_match6, <<>>, Tab),
    ?assertEqual(ID, id(match(T, Tab))),
    true = ets:delete(Tab).

t_match7(_) ->
    Tab = new(),
    T = <<"a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z">>,
    W = <<"a/+/c/+/e/+/g/+/i/+/k/+/m/+/o/+/q/+/s/+/u/+/w/+/y/+/#">>,
    emqx_rule_index:insert(W, t_match7, <<>>, Tab),
    ?assertEqual(W, topic(match(T, Tab))),
    true = ets:delete(Tab).

t_match_unique(_) ->
    Tab = new(),
    emqx_rule_index:insert(<<"a/b/c">>, t_match_id1, <<>>, Tab),
    emqx_rule_index:insert(<<"a/b/+">>, t_match_id1, <<>>, Tab),
    emqx_rule_index:insert(<<"a/b/c/+">>, t_match_id2, <<>>, Tab),
    ?assertEqual(
        [t_match_id1, t_match_id1],
        [id(M) || M <- emqx_rule_index:matches(<<"a/b/c">>, Tab, [])]
    ),
    ?assertEqual(
        [t_match_id1],
        [id(M) || M <- emqx_rule_index:matches(<<"a/b/c">>, Tab, [unique])]
    ).

t_match_ordering(_) ->
    Tab = new(),
    emqx_rule_index:insert(<<"a/b/+">>, t_match_id2, <<>>, Tab),
    emqx_rule_index:insert(<<"a/b/c">>, t_match_id1, <<>>, Tab),
    emqx_rule_index:insert(<<"a/b/#">>, t_match_id3, <<>>, Tab),
    Ids1 = [id(M) || M <- emqx_rule_index:matches(<<"a/b/c">>, Tab, [])],
    Ids2 = [id(M) || M <- emqx_rule_index:matches(<<"a/b/c">>, Tab, [unique])],
    ?assertEqual(Ids1, Ids2),
    ?assertEqual([t_match_id1, t_match_id2, t_match_id3], Ids1).

new() ->
    ets:new(?MODULE, [public, ordered_set, {write_concurrency, true}]).

match(T, Tab) ->
    emqx_rule_index:match(T, Tab).

matches(T, Tab) ->
    lists:sort(emqx_rule_index:matches(T, Tab, [])).

id(Match) ->
    emqx_rule_index:get_id(Match).

topic(Match) ->
    emqx_rule_index:get_topic(Match).
