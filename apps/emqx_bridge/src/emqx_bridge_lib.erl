%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_bridge_lib).

-export([
    maybe_withdraw_rule_action/3,
    maybe_upgrade_type/1,
    maybe_downgrade_type/2,
    get_conf/2
]).

-define(IS_ACTION_TYPE(TYPE, EXPR),
    case emqx_action_info:is_action_type(TYPE) of
        false -> TYPE;
        true -> EXPR
    end
).

%% @doc A bridge can be used as a rule action.
%% The bridge-ID in rule-engine's world is the action-ID.
%% This function is to remove a bridge (action) from all rules
%% using it if the `rule_actions' is included in `DeleteDeps' list
maybe_withdraw_rule_action(BridgeType, BridgeName, DeleteDeps) ->
    BridgeIds = external_ids(BridgeType, BridgeName),
    DeleteActions = lists:member(rule_actions, DeleteDeps),
    maybe_withdraw_rule_action_loop(BridgeIds, DeleteActions).

maybe_withdraw_rule_action_loop([], _DeleteActions) ->
    ok;
maybe_withdraw_rule_action_loop([BridgeId | More], DeleteActions) ->
    case emqx_rule_engine:get_rule_ids_by_action(BridgeId) of
        [] ->
            maybe_withdraw_rule_action_loop(More, DeleteActions);
        RuleIds when DeleteActions ->
            lists:foreach(
                fun(R) ->
                    emqx_rule_engine:ensure_action_removed(R, BridgeId)
                end,
                RuleIds
            ),
            maybe_withdraw_rule_action_loop(More, DeleteActions);
        RuleIds ->
            {error, #{
                reason => rules_depending_on_this_bridge,
                bridge_id => BridgeId,
                rule_ids => RuleIds
            }}
    end.

%% @doc Kafka producer bridge renamed from 'kafka' to 'kafka_producer' since
%% 5.3.1.
maybe_upgrade_type(Type) when is_atom(Type) ->
    ?IS_ACTION_TYPE(Type, do_upgrade_type(Type));
maybe_upgrade_type(Type0) when is_binary(Type0) ->
    Type = binary_to_existing_atom(Type0),
    atom_to_binary(?IS_ACTION_TYPE(Type, do_upgrade_type(Type)));
maybe_upgrade_type(Type0) when is_list(Type0) ->
    Type = list_to_existing_atom(Type0),
    atom_to_list(?IS_ACTION_TYPE(Type, do_upgrade_type(Type))).

do_upgrade_type(Type) ->
    emqx_bridge_v2:bridge_v1_type_to_action_type(Type).

%% @doc Kafka producer bridge type renamed from 'kafka' to 'kafka_producer'
%% since 5.3.1
maybe_downgrade_type(Type, Conf) when is_atom(Type) ->
    ?IS_ACTION_TYPE(Type, do_downgrade_type(Type, Conf));
maybe_downgrade_type(Type0, Conf) when is_binary(Type0) ->
    Type = binary_to_existing_atom(Type0),
    atom_to_binary(?IS_ACTION_TYPE(Type, do_downgrade_type(Type, Conf)));
maybe_downgrade_type(Type0, Conf) when is_list(Type0) ->
    Type = list_to_existing_atom(Type0),
    atom_to_list(?IS_ACTION_TYPE(Type, do_downgrade_type(Type, Conf))).

do_downgrade_type(Type, Conf) ->
    emqx_bridge_v2:action_type_to_bridge_v1_type(Type, Conf).

%% A rule might be referencing an old version bridge type name i.e. 'kafka'
%% instead of 'kafka_producer' so we need to try both
external_ids(Type, Name) ->
    case maybe_downgrade_type(Type, get_conf(Type, Name)) of
        Type ->
            [external_id(Type, Name)];
        BridgeV1Type ->
            [external_id(BridgeV1Type, Name), external_id(Type, Name)]
    end.

get_conf(BridgeType, BridgeName) ->
    case emqx_bridge_v2:is_bridge_v2_type(BridgeType) of
        true ->
            emqx_conf:get_raw([actions, BridgeType, BridgeName]);
        false ->
            undefined
    end.

%% Creates the external id for the bridge_v2 that is used by the rule actions
%% to refer to the bridge_v2
external_id(BridgeType, BridgeName) ->
    Name = bin(BridgeName),
    Type = bin(BridgeType),
    <<Type/binary, ":", Name/binary>>.

bin(Bin) when is_binary(Bin) -> Bin;
bin(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8).
