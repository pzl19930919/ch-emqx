%%--------------------------------------------------------------------
%% Copyright (c) 2017-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%%--------------------------------------------------------------------
%% @doc
%% A stateful interaction between a Client and a Server. Some Sessions
%% last only as long as the Network Connection, others can span multiple
%% consecutive Network Connections between a Client and a Server.
%%
%% The Session State in the Server consists of:
%%
%% The existence of a Session, even if the rest of the Session State is empty.
%%
%% The Clients subscriptions, including any Subscription Identifiers.
%%
%% QoS 1 and QoS 2 messages which have been sent to the Client, but have not
%% been completely acknowledged.
%%
%% QoS 1 and QoS 2 messages pending transmission to the Client and OPTIONALLY
%% QoS 0 messages pending transmission to the Client.
%%
%% QoS 2 messages which have been received from the Client, but have not been
%% completely acknowledged.The Will Message and the Will Delay Interval
%%
%% If the Session is currently not connected, the time at which the Session
%% will end and Session State will be discarded.
%% @end
%%--------------------------------------------------------------------

%% MQTT Session
-module(emqx_session).

-include("emqx.hrl").
-include("emqx_session.hrl").
-include("emqx_mqtt.hrl").
-include("logger.hrl").
-include("types.hrl").

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-export([init/1]).

-export([
    lookup/1,
    discard/1
]).

-export([
    info/1,
    info/2,
    is_session/1,
    stats/1,
    obtain_next_pkt_id/1,
    get_mqueue/1
]).

-export([
    subscribe/4,
    unsubscribe/4
]).

-export([
    publish/4,
    puback/3,
    pubrec/3,
    pubrel/3,
    pubcomp/3
]).

-export([
    deliver/3,
    enqueue/3,
    dequeue/2,
    filter_queue/2,
    ignore_local/4,
    retry/2,
    terminate/4
]).

-export([
    takeover/1,
    resume/2,
    replay/2
]).

-export([expire/3]).

%% Export for CT
-export([set_field/3]).

-type sessionID() :: emqx_guid:guid().

-export_type([
    session/0,
    sessionID/0
]).

-type inflight_data_phase() :: wait_ack | wait_comp.

-record(inflight_data, {
    phase :: inflight_data_phase(),
    message :: emqx_types:message(),
    timestamp :: non_neg_integer()
}).

-type session() :: #session{}.

-type publish() :: {maybe(emqx_types:packet_id()), emqx_types:message()}.

-type pubrel() :: {pubrel, emqx_types:packet_id()}.

-type replies() :: list(publish() | pubrel()).

-define(INFO_KEYS, [
    id,
    is_persistent,
    subscriptions,
    upgrade_qos,
    retry_interval,
    await_rel_timeout,
    created_at
]).

-define(STATS_KEYS, [
    subscriptions_cnt,
    subscriptions_max,
    inflight_cnt,
    inflight_max,
    mqueue_len,
    mqueue_max,
    mqueue_dropped,
    next_pkt_id,
    awaiting_rel_cnt,
    awaiting_rel_max
]).

-define(DEFAULT_BATCH_N, 1000).

-type options() :: #{
    max_subscriptions => non_neg_integer(),
    upgrade_qos => boolean(),
    retry_interval => timeout(),
    max_awaiting_rel => non_neg_integer() | infinity,
    await_rel_timeout => timeout(),
    max_inflight => integer(),
    mqueue => emqx_mqueue:options(),
    is_persistent => boolean(),
    expiry_interval => non_neg_integer(),
    clientid => emqx_types:clientid()
}.

%%--------------------------------------------------------------------
%% Init a Session
%%--------------------------------------------------------------------

-spec init(options()) -> session().
init(Opts) ->
    MaxInflight = maps:get(max_inflight, Opts),
    QueueOpts = maps:merge(
        #{
            max_len => 1000,
            store_qos0 => true
        },
        maps:get(mqueue, Opts, #{})
    ),
    ExpiryInterval = maps:get(expiry_interval, Opts),
    IsPersistent = maps:get(is_persistent, Opts, ExpiryInterval > 0),
    Session = #session{
        id = emqx_guid:gen(),
        clientid = maps:get(clientid, Opts, <<>>),
        is_persistent = IsPersistent,
        expiry_interval = ExpiryInterval,
        max_subscriptions = maps:get(max_subscriptions, Opts),
        subscriptions = #{},
        upgrade_qos = maps:get(upgrade_qos, Opts),
        inflight = emqx_inflight:new(MaxInflight),
        mqueue = emqx_mqueue:init(QueueOpts),
        next_pkt_id = 1,
        retry_interval = maps:get(retry_interval, Opts),
        awaiting_rel = #{},
        max_awaiting_rel = maps:get(max_awaiting_rel, Opts),
        await_rel_timeout = maps:get(await_rel_timeout, Opts),
        created_at = erlang:system_time(millisecond)
    },
    persist_open(Session, timestamp()).

-spec lookup(emqx_types:clientid()) -> {persistent, session()} | none.
lookup(_ClientId) ->
    % case emqx_persistent_session:lookup(ClientId) of
    %     {persistent, Session} ->
    %         {persistent, Session};
    %     {expired, Session} ->
    %         _ = emqx_persistent_session:discard(Session),
    %         none;
    %     none ->
    %         none
    % end.
    none.

-spec discard(session()) -> session().
discard(Session) ->
    ok = persist_discard(Session),
    Session#session{is_persistent = false, expiry_interval = 0}.

%%--------------------------------------------------------------------
%% Info, Stats
%%--------------------------------------------------------------------

is_session(#session{}) -> true;
is_session(_) -> false.

%% @doc Get infos of the session.
-spec info(session()) -> emqx_types:infos().
info(Session) ->
    maps:from_list(info(?INFO_KEYS, Session)).

info(Keys, Session) when is_list(Keys) ->
    [{Key, info(Key, Session)} || Key <- Keys];
info(id, #session{id = Id}) ->
    Id;
info(clientid, #session{clientid = ClientId}) ->
    ClientId;
info(is_persistent, #session{is_persistent = Bool}) ->
    Bool;
info(subscriptions, #session{subscriptions = Subs}) ->
    Subs;
info(subscriptions_cnt, #session{subscriptions = Subs}) ->
    maps:size(Subs);
info(subscriptions_max, #session{max_subscriptions = MaxSubs}) ->
    MaxSubs;
info(upgrade_qos, #session{upgrade_qos = UpgradeQoS}) ->
    UpgradeQoS;
info(inflight, #session{inflight = Inflight}) ->
    Inflight;
info(inflight_cnt, #session{inflight = Inflight}) ->
    emqx_inflight:size(Inflight);
info(inflight_max, #session{inflight = Inflight}) ->
    emqx_inflight:max_size(Inflight);
info(retry_interval, #session{retry_interval = Interval}) ->
    Interval;
info(mqueue, #session{mqueue = MQueue}) ->
    MQueue;
info(mqueue_len, #session{mqueue = MQueue}) ->
    emqx_mqueue:len(MQueue);
info(mqueue_max, #session{mqueue = MQueue}) ->
    emqx_mqueue:max_len(MQueue);
info(mqueue_dropped, #session{mqueue = MQueue}) ->
    emqx_mqueue:dropped(MQueue);
info(next_pkt_id, #session{next_pkt_id = PacketId}) ->
    PacketId;
info(awaiting_rel, #session{awaiting_rel = AwaitingRel}) ->
    AwaitingRel;
info(awaiting_rel_cnt, #session{awaiting_rel = AwaitingRel}) ->
    maps:size(AwaitingRel);
info(awaiting_rel_max, #session{max_awaiting_rel = Max}) ->
    Max;
info(await_rel_timeout, #session{await_rel_timeout = Timeout}) ->
    Timeout;
info(created_at, #session{created_at = CreatedAt}) ->
    CreatedAt.

%% @doc Get stats of the session.
-spec stats(session()) -> emqx_types:stats().
stats(Session) -> info(?STATS_KEYS, Session).

%%--------------------------------------------------------------------
%% Ignore local messages
%%--------------------------------------------------------------------

ignore_local(ClientInfo, Delivers, Subscriber, Session) ->
    Subs = info(subscriptions, Session),
    lists:filter(
        fun({deliver, Topic, #message{from = Publisher} = Msg}) ->
            case maps:find(Topic, Subs) of
                {ok, #{nl := 1}} when Subscriber =:= Publisher ->
                    ok = emqx_hooks:run('delivery.dropped', [ClientInfo, Msg, no_local]),
                    ok = emqx_metrics:inc('delivery.dropped'),
                    ok = emqx_metrics:inc('delivery.dropped.no_local'),
                    false;
                _ ->
                    true
            end
        end,
        Delivers
    ).

%%--------------------------------------------------------------------
%% Client -> Broker: SUBSCRIBE
%%--------------------------------------------------------------------

-spec subscribe(
    emqx_types:clientinfo(),
    emqx_types:topic(),
    emqx_types:subopts(),
    session()
) ->
    {ok, session()} | {error, emqx_types:reason_code()}.
subscribe(
    ClientInfo = #{clientid := ClientId},
    TopicFilter,
    SubOpts,
    Session = #session{subscriptions = Subs}
) ->
    IsNew = not maps:is_key(TopicFilter, Subs),
    case IsNew andalso is_subscriptions_full(Session) of
        false ->
            ok = emqx_broker:subscribe(TopicFilter, ClientId, SubOpts),
            _ = emqx_persistent_session_ds:register_subscription(TopicFilter, Session),
            ok = emqx_hooks:run(
                'session.subscribed',
                [ClientInfo, TopicFilter, SubOpts#{is_new => IsNew}]
            ),
            Session1 = Session#session{subscriptions = maps:put(TopicFilter, SubOpts, Subs)},
            {ok, persist_update(Session1)};
        true ->
            {error, ?RC_QUOTA_EXCEEDED}
    end.

is_subscriptions_full(#session{max_subscriptions = infinity}) ->
    false;
is_subscriptions_full(#session{
    subscriptions = Subs,
    max_subscriptions = MaxLimit
}) ->
    maps:size(Subs) >= MaxLimit.

%%--------------------------------------------------------------------
%% Client -> Broker: UNSUBSCRIBE
%%--------------------------------------------------------------------

-spec unsubscribe(emqx_types:clientinfo(), emqx_types:topic(), emqx_types:subopts(), session()) ->
    {ok, session()} | {error, emqx_types:reason_code()}.
unsubscribe(
    ClientInfo,
    TopicFilter,
    UnSubOpts,
    Session = #session{subscriptions = Subs}
) ->
    case maps:find(TopicFilter, Subs) of
        {ok, SubOpts} ->
            ok = emqx_broker:unsubscribe(TopicFilter),
            _ = emqx_persistent_session_ds:unregister_subscription(TopicFilter, Session),
            ok = emqx_hooks:run(
                'session.unsubscribed',
                [ClientInfo, TopicFilter, maps:merge(SubOpts, UnSubOpts)]
            ),
            Session1 = Session#session{subscriptions = maps:remove(TopicFilter, Subs)},
            {ok, persist_update(Session1)};
        error ->
            {error, ?RC_NO_SUBSCRIPTION_EXISTED}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBLISH
%%--------------------------------------------------------------------

-spec publish(emqx_types:clientinfo(), emqx_types:packet_id(), emqx_types:message(), session()) ->
    {ok, emqx_types:publish_result(), session()}
    | {error, emqx_types:reason_code()}.
publish(
    _ClientInfo,
    PacketId,
    Msg = #message{qos = ?QOS_2, timestamp = Ts},
    Session = #session{awaiting_rel = AwaitingRel}
) ->
    case is_awaiting_full(Session) of
        false ->
            case maps:is_key(PacketId, AwaitingRel) of
                false ->
                    Results = emqx_broker:publish(Msg),
                    AwaitingRel1 = maps:put(PacketId, Ts, AwaitingRel),
                    Session1 = Session#session{awaiting_rel = AwaitingRel1},
                    {ok, Results, persist_update(Session1)};
                true ->
                    drop_qos2_msg(PacketId, Msg, ?RC_PACKET_IDENTIFIER_IN_USE)
            end;
        true ->
            drop_qos2_msg(PacketId, Msg, ?RC_RECEIVE_MAXIMUM_EXCEEDED)
    end;
%% Publish QoS0/1 directly
publish(_ClientInfo, _PacketId, Msg, Session) ->
    {ok, emqx_broker:publish(Msg), Session}.

drop_qos2_msg(PacketId, Msg, RC) ->
    ?SLOG(
        warning,
        #{
            msg => "dropped_qos2_packet",
            reason => emqx_reason_codes:name(RC),
            packet_id => PacketId
        },
        #{topic => Msg#message.topic}
    ),
    ok = emqx_metrics:inc('messages.dropped'),
    ok = emqx_hooks:run('message.dropped', [Msg, #{node => node()}, emqx_reason_codes:name(RC)]),
    {error, RC}.

is_awaiting_full(#session{max_awaiting_rel = infinity}) ->
    false;
is_awaiting_full(#session{
    awaiting_rel = AwaitingRel,
    max_awaiting_rel = MaxLimit
}) ->
    maps:size(AwaitingRel) >= MaxLimit.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBACK
%%--------------------------------------------------------------------

-spec puback(emqx_types:clientinfo(), emqx_types:packet_id(), session()) ->
    {ok, emqx_types:message(), session()}
    | {ok, emqx_types:message(), replies(), session()}
    | {error, emqx_types:reason_code()}.
puback(ClientInfo, PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, #inflight_data{phase = wait_ack, message = Msg}} ->
            on_delivery_completed(Msg, Session),
            Inflight1 = emqx_inflight:delete(PacketId, Inflight),
            return_with(Msg, dequeue(ClientInfo, Session#session{inflight = Inflight1}));
        {value, _} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

return_with(Msg, {ok, Session}) ->
    {ok, Msg, Session};
return_with(Msg, {ok, Publishes, Session}) ->
    {ok, Msg, Publishes, Session}.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBREC
%%--------------------------------------------------------------------

-spec pubrec(emqx_types:clientinfo(), emqx_types:packet_id(), session()) ->
    {ok, emqx_types:message(), session()}
    | {error, emqx_types:reason_code()}.
pubrec(_ClientInfo, PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, #inflight_data{phase = wait_ack, message = Msg} = Data} ->
            Update = Data#inflight_data{phase = wait_comp},
            Inflight1 = emqx_inflight:update(PacketId, Update, Inflight),
            Session1 = Session#session{inflight = Inflight1},
            {ok, Msg, persist_update(Session1)};
        {value, _} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBREL
%%--------------------------------------------------------------------

-spec pubrel(emqx_types:clientinfo(), emqx_types:packet_id(), session()) ->
    {ok, session()} | {error, emqx_types:reason_code()}.
pubrel(_ClientInfo, PacketId, Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:take(PacketId, AwaitingRel) of
        {_Ts, AwaitingRel1} ->
            Session1 = Session#session{awaiting_rel = AwaitingRel1},
            {ok, persist_update(Session1)};
        error ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBCOMP
%%--------------------------------------------------------------------

-spec pubcomp(emqx_types:clientinfo(), emqx_types:packet_id(), session()) ->
    {ok, session()}
    | {ok, replies(), session()}
    | {error, emqx_types:reason_code()}.
pubcomp(ClientInfo, PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, #inflight_data{phase = wait_comp, message = Msg}} ->
            on_delivery_completed(Msg, Session),
            Inflight1 = emqx_inflight:delete(PacketId, Inflight),
            dequeue(ClientInfo, Session#session{inflight = Inflight1});
        {value, _Other} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Dequeue Msgs
%%--------------------------------------------------------------------

dequeue(ClientInfo, Session = #session{inflight = Inflight, mqueue = Q}) ->
    case emqx_mqueue:is_empty(Q) of
        true ->
            {ok, Session};
        false ->
            {Msgs, Q1} = dequeue(ClientInfo, batch_n(Inflight), [], Q),
            do_deliver(ClientInfo, Msgs, [], true, Session#session{mqueue = Q1})
    end.

dequeue(_ClientInfo, 0, Msgs, Q) ->
    {lists:reverse(Msgs), Q};
dequeue(ClientInfo, Cnt, Msgs, Q) ->
    case emqx_mqueue:out(Q) of
        {empty, _Q} ->
            dequeue(ClientInfo, 0, Msgs, Q);
        {{value, Msg}, Q1} ->
            case emqx_message:is_expired(Msg) of
                true ->
                    ok = emqx_hooks:run('delivery.dropped', [ClientInfo, Msg, expired]),
                    ok = inc_delivery_expired_cnt(),
                    dequeue(ClientInfo, Cnt, Msgs, Q1);
                false ->
                    dequeue(ClientInfo, acc_cnt(Msg, Cnt), [Msg | Msgs], Q1)
            end
    end.

filter_queue(Pred, #session{mqueue = Q} = Session) ->
    Session#session{mqueue = emqx_mqueue:filter(Pred, Q)}.

acc_cnt(#message{qos = ?QOS_0}, Cnt) -> Cnt;
acc_cnt(_Msg, Cnt) -> Cnt - 1.

%%--------------------------------------------------------------------
%% Broker -> Client: Deliver
%%--------------------------------------------------------------------

-spec deliver(emqx_types:clientinfo(), list(emqx_types:deliver()), session()) ->
    {ok, session()} | {ok, replies(), session()}.
%% Optimize
deliver(ClientInfo, [Deliver], Session) ->
    % TODO
    % There are 2 persistence-related side-effects, they should ideally go in a
    % single transaction. They weren't performed in a single transaction before,
    % the order of those side-effects is preserved, overall it supposedly affects
    % if consistency violation would be message loss or message duplication.
    ok = persist_delivers([Deliver], Session),
    Msg = enrich_deliver(Deliver, Session),
    case deliver_msg(ClientInfo, Msg, Session) of
        {Dirty, Session1} ->
            {ok, persist_update_dirty(Dirty, Session1)};
        {Dirty, [Publish], Session1} ->
            {ok, [Publish], persist_update_dirty(Dirty, Session1)}
    end;
deliver(ClientInfo, Delivers, Session) ->
    ok = persist_delivers(Delivers, Session),
    Msgs = [enrich_deliver(D, Session) || D <- Delivers],
    do_deliver(ClientInfo, Msgs, [], false, Session).

do_deliver(_ClientInfo, [], Publishes, Dirty, Session) ->
    {ok, lists:reverse(Publishes), persist_update_dirty(Dirty, Session)};
do_deliver(ClientInfo, [Msg | More], Acc, DirtyAcc, Session) ->
    case deliver_msg(ClientInfo, Msg, Session) of
        {Dirty, Session1} ->
            do_deliver(ClientInfo, More, Acc, DirtyAcc or Dirty, Session1);
        {Dirty, [Publish], Session1} ->
            do_deliver(ClientInfo, More, [Publish | Acc], DirtyAcc or Dirty, Session1)
    end.

deliver_msg(_ClientInfo, Msg = #message{qos = ?QOS_0}, Session) ->
    %
    on_delivery_completed(Msg, Session),
    {false, [{undefined, maybe_ack(Msg)}], Session};
deliver_msg(
    ClientInfo,
    Msg = #message{qos = QoS},
    Session =
        #session{next_pkt_id = PacketId, inflight = Inflight}
) when
    QoS =:= ?QOS_1 orelse QoS =:= ?QOS_2
->
    case emqx_inflight:is_full(Inflight) of
        true ->
            case maybe_nack(Msg) of
                true -> {false, Session};
                false -> {true, enqueue_msg(ClientInfo, Msg, Session)}
            end;
        false ->
            %% Note that we publish message without shared ack header
            %% But add to inflight with ack headers
            %% This ack header is required for redispatch-on-terminate feature to work
            Publish = {PacketId, maybe_ack(Msg)},
            MarkedMsg = mark_begin_deliver(Msg),
            Inflight1 = emqx_inflight:insert(PacketId, with_ts(MarkedMsg), Inflight),
            {true, [Publish], next_pkt_id(Session#session{inflight = Inflight1})}
    end.

-spec enqueue(
    emqx_types:clientinfo(),
    list(emqx_types:deliver()) | emqx_types:message(),
    session()
) -> session().
enqueue(ClientInfo, Delivers, Session) when is_list(Delivers) ->
    Session1 = lists:foldl(
        fun(Deliver, Session0) ->
            Msg = enrich_deliver(Deliver, Session),
            enqueue_msg(ClientInfo, Msg, Session0)
        end,
        Session,
        Delivers
    ),
    ok = persist_delivers(Delivers, Session1),
    persist_update(Session1);
enqueue(ClientInfo, Msg, Session) ->
    % NOTE: no `persist_delivers/2` here, should be fine as long as this clause is test-only.
    persist_update(enqueue_msg(ClientInfo, Msg, Session)).

enqueue_msg(ClientInfo, #message{} = Msg, Session = #session{mqueue = Q}) ->
    % TODO: dirtyness
    {Dropped, NewQ} = emqx_mqueue:in(Msg, Q),
    (Dropped =/= undefined) andalso handle_dropped(ClientInfo, Dropped, Session),
    Session#session{mqueue = NewQ}.

handle_dropped(ClientInfo, Msg = #message{qos = QoS, topic = Topic}, #session{mqueue = Q}) ->
    Payload = emqx_message:to_log_map(Msg),
    #{store_qos0 := StoreQos0} = QueueInfo = emqx_mqueue:info(Q),
    case (QoS == ?QOS_0) andalso (not StoreQos0) of
        true ->
            ok = emqx_hooks:run('delivery.dropped', [ClientInfo, Msg, qos0_msg]),
            ok = emqx_metrics:inc('delivery.dropped'),
            ok = emqx_metrics:inc('delivery.dropped.qos0_msg'),
            ok = inc_pd('send_msg.dropped'),
            ?SLOG(
                warning,
                #{
                    msg => "dropped_qos0_msg",
                    queue => QueueInfo,
                    payload => Payload
                },
                #{topic => Topic}
            );
        false ->
            ok = emqx_hooks:run('delivery.dropped', [ClientInfo, Msg, queue_full]),
            ok = emqx_metrics:inc('delivery.dropped'),
            ok = emqx_metrics:inc('delivery.dropped.queue_full'),
            ok = inc_pd('send_msg.dropped'),
            ok = inc_pd('send_msg.dropped.queue_full'),
            ?SLOG(
                warning,
                #{
                    msg => "dropped_msg_due_to_mqueue_is_full",
                    queue => QueueInfo,
                    payload => Payload
                },
                #{topic => Topic}
            )
    end.

enrich_deliver({deliver, Topic, Msg}, Session = #session{subscriptions = Subs}) ->
    enrich_subopts(get_subopts(Topic, Subs), Msg, Session).

maybe_ack(Msg) ->
    emqx_shared_sub:maybe_ack(Msg).

maybe_nack(Msg) ->
    emqx_shared_sub:maybe_nack_dropped(Msg).

get_subopts(Topic, SubMap) ->
    case maps:find(Topic, SubMap) of
        {ok, #{nl := Nl, qos := QoS, rap := Rap, subid := SubId}} ->
            [{nl, Nl}, {qos, QoS}, {rap, Rap}, {subid, SubId}];
        {ok, #{nl := Nl, qos := QoS, rap := Rap}} ->
            [{nl, Nl}, {qos, QoS}, {rap, Rap}];
        error ->
            []
    end.

enrich_subopts([], Msg, _Session) ->
    Msg;
enrich_subopts([{nl, 1} | Opts], Msg, Session) ->
    enrich_subopts(Opts, emqx_message:set_flag(nl, Msg), Session);
enrich_subopts([{nl, 0} | Opts], Msg, Session) ->
    enrich_subopts(Opts, Msg, Session);
enrich_subopts(
    [{qos, SubQoS} | Opts],
    Msg = #message{qos = PubQoS},
    Session = #session{upgrade_qos = true}
) ->
    enrich_subopts(Opts, Msg#message{qos = max(SubQoS, PubQoS)}, Session);
enrich_subopts(
    [{qos, SubQoS} | Opts],
    Msg = #message{qos = PubQoS},
    Session = #session{upgrade_qos = false}
) ->
    enrich_subopts(Opts, Msg#message{qos = min(SubQoS, PubQoS)}, Session);
enrich_subopts([{rap, 1} | Opts], Msg, Session) ->
    enrich_subopts(Opts, Msg, Session);
enrich_subopts([{rap, 0} | Opts], Msg = #message{headers = #{retained := true}}, Session) ->
    enrich_subopts(Opts, Msg, Session);
enrich_subopts([{rap, 0} | Opts], Msg, Session) ->
    enrich_subopts(Opts, emqx_message:set_flag(retain, false, Msg), Session);
enrich_subopts([{subid, SubId} | Opts], Msg, Session) ->
    Props = emqx_message:get_header(properties, Msg, #{}),
    Msg1 = emqx_message:set_header(properties, Props#{'Subscription-Identifier' => SubId}, Msg),
    enrich_subopts(Opts, Msg1, Session).

%%--------------------------------------------------------------------
%% Retry Delivery
%%--------------------------------------------------------------------

-spec retry(emqx_types:clientinfo(), session()) ->
    {ok, session()} | {ok, replies(), timeout(), session()}.
retry(ClientInfo, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:is_empty(Inflight) of
        true ->
            {ok, Session};
        false ->
            Now = erlang:system_time(millisecond),
            retry_delivery(
                emqx_inflight:to_list(fun sort_fun/2, Inflight),
                [],
                Now,
                Session,
                ClientInfo
            )
    end.

retry_delivery([], Acc, _Now, Session = #session{retry_interval = Interval}, _ClientInfo) ->
    {ok, lists:reverse(Acc), Interval, persist_update(Session)};
retry_delivery(
    [{PacketId, #inflight_data{timestamp = Ts} = Data} | More],
    Acc,
    Now,
    Session = #session{retry_interval = Interval, inflight = Inflight},
    ClientInfo
) ->
    case (Age = age(Now, Ts)) >= Interval of
        true ->
            {Acc1, Inflight1} = do_retry_delivery(PacketId, Data, Now, Acc, Inflight, ClientInfo),
            retry_delivery(More, Acc1, Now, Session#session{inflight = Inflight1}, ClientInfo);
        false ->
            {ok, lists:reverse(Acc), Interval - max(0, Age), persist_update(Session)}
    end.

do_retry_delivery(
    PacketId,
    #inflight_data{phase = wait_ack, message = Msg} = Data,
    Now,
    Acc,
    Inflight,
    ClientInfo
) ->
    case emqx_message:is_expired(Msg) of
        true ->
            ok = emqx_hooks:run('delivery.dropped', [ClientInfo, Msg, expired]),
            ok = inc_delivery_expired_cnt(),
            {Acc, emqx_inflight:delete(PacketId, Inflight)};
        false ->
            Msg1 = emqx_message:set_flag(dup, true, Msg),
            Update = Data#inflight_data{message = Msg1, timestamp = Now},
            Inflight1 = emqx_inflight:update(PacketId, Update, Inflight),
            {[{PacketId, Msg1} | Acc], Inflight1}
    end;
do_retry_delivery(PacketId, Data, Now, Acc, Inflight, _) ->
    Update = Data#inflight_data{timestamp = Now},
    Inflight1 = emqx_inflight:update(PacketId, Update, Inflight),
    {[{pubrel, PacketId} | Acc], Inflight1}.

%%--------------------------------------------------------------------
%% Expire Awaiting Rel
%%--------------------------------------------------------------------

-spec expire(emqx_types:clientinfo(), awaiting_rel, session()) ->
    {ok, session()} | {ok, timeout(), session()}.
expire(_ClientInfo, awaiting_rel, Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:size(AwaitingRel) of
        0 -> {ok, Session};
        _ -> expire_awaiting_rel(erlang:system_time(millisecond), Session)
    end.

expire_awaiting_rel(
    Now,
    Session = #session{
        awaiting_rel = AwaitingRel,
        await_rel_timeout = Timeout
    }
) ->
    NotExpired = fun(_PacketId, Ts) -> age(Now, Ts) < Timeout end,
    AwaitingRel1 = maps:filter(NotExpired, AwaitingRel),
    ExpiredCnt = maps:size(AwaitingRel) - maps:size(AwaitingRel1),
    (ExpiredCnt > 0) andalso inc_await_pubrel_timeout(ExpiredCnt),
    NSession = Session#session{awaiting_rel = AwaitingRel1},
    NSession1 = persist_update(NSession),
    case maps:size(AwaitingRel1) of
        0 -> {ok, NSession1};
        _ -> {ok, Timeout, NSession1}
    end.

%%--------------------------------------------------------------------
%% Takeover, Resume and Replay
%%--------------------------------------------------------------------

-spec takeover(session()) -> ok.
takeover(#session{subscriptions = Subs}) ->
    lists:foreach(fun emqx_broker:unsubscribe/1, maps:keys(Subs)).

-spec resume(emqx_types:clientinfo(), session()) -> ok.
resume(ClientInfo = #{clientid := ClientId}, Session = #session{subscriptions = Subs}) ->
    lists:foreach(
        fun({TopicFilter, SubOpts}) ->
            ok = emqx_broker:subscribe(TopicFilter, ClientId, SubOpts)
        end,
        maps:to_list(Subs)
    ),
    ok = emqx_metrics:inc('session.resumed'),
    emqx_hooks:run('session.resumed', [ClientInfo, info(Session)]).

-spec replay(emqx_types:clientinfo(), session()) -> {ok, replies(), session()}.
replay(ClientInfo, Session = #session{inflight = Inflight}) ->
    Pubs = lists:map(
        fun
            ({PacketId, #inflight_data{phase = wait_comp}}) ->
                {pubrel, PacketId};
            ({PacketId, #inflight_data{message = Msg}}) ->
                {PacketId, emqx_message:set_flag(dup, true, Msg)}
        end,
        emqx_inflight:to_list(Inflight)
    ),
    case dequeue(ClientInfo, Session) of
        {ok, NSession} -> {ok, Pubs, NSession};
        {ok, More, NSession} -> {ok, lists:append(Pubs, More), NSession}
    end.

-spec terminate(emqx_types:clientinfo(), emqx_types:conninfo(), Reason :: term(), session()) -> ok.
terminate(ClientInfo, ConnInfo, Reason, Session) ->
    run_terminate_hooks(ClientInfo, Reason, Session),
    maybe_redispatch_shared_messages(Reason, Session),
    % FIXME: unclear about the purpose of this
    (Reason == expired) andalso
        persist_update(Session, maps:get(disconnected_at, ConnInfo, timestamp())),
    ok.

run_terminate_hooks(ClientInfo, discarded, Session) ->
    run_hook('session.discarded', [ClientInfo, info(Session)]);
run_terminate_hooks(ClientInfo, takenover, Session) ->
    run_hook('session.takenover', [ClientInfo, info(Session)]);
run_terminate_hooks(ClientInfo, Reason, Session) ->
    run_hook('session.terminated', [ClientInfo, Reason, info(Session)]).

maybe_redispatch_shared_messages(takenover, _Session) ->
    ok;
maybe_redispatch_shared_messages(kicked, _Session) ->
    ok;
maybe_redispatch_shared_messages(_Reason, Session) ->
    redispatch_shared_messages(Session).

redispatch_shared_messages(#session{inflight = Inflight, mqueue = Q}) ->
    AllInflights = emqx_inflight:to_list(fun sort_fun/2, Inflight),
    F = fun
        ({_PacketId, #inflight_data{message = #message{qos = ?QOS_1} = Msg}}) ->
            %% For QoS 2, here is what the spec says:
            %% If the Client's Session terminates before the Client reconnects,
            %% the Server MUST NOT send the Application Message to any other
            %% subscribed Client [MQTT-4.8.2-5].
            {true, Msg};
        ({_PacketId, #inflight_data{}}) ->
            false
    end,
    InflightList = lists:filtermap(F, AllInflights),
    emqx_shared_sub:redispatch(InflightList ++ emqx_mqueue:to_list(Q)).

-compile({inline, [run_hook/2]}).
run_hook(Name, Args) ->
    ok = emqx_metrics:inc(Name),
    emqx_hooks:run(Name, Args).

%%--------------------------------------------------------------------
%% Persistence
%%--------------------------------------------------------------------

-define(NEED_PERSISTENCE(SESSION),
    (SESSION#session.is_persistent andalso (SESSION#session.clientid /= undefined))
).

persist_update_dirty(true, Session) ->
    persist_update(Session);
persist_update_dirty(false, Session) ->
    Session.

persist_update(Session) ->
    persist_update(Session, timestamp()).

persist_open(Session, _Timestamp) when ?NEED_PERSISTENCE(Session) ->
    % TODO: error handling
    _ = emqx_persistent_session_ds:persist_session(Session),
    Session;
persist_open(Session, _) ->
    Session.

persist_discard(Session) when ?NEED_PERSISTENCE(Session) ->
    _ = emqx_persistent_session_ds:discard_session(Session),
    Session;
persist_discard(Session) ->
    Session.

persist_update(Session, _Timestamp) when ?NEED_PERSISTENCE(Session) ->
    % FIXME
    % Supposedly with ds-based impl we wouldn't update session so often, instead we
    % need more fine-grained DB activities, mostly working on iterators.
    Session;
persist_update(Session, _) ->
    Session.

persist_delivers(_Delivers, Session) when ?NEED_PERSISTENCE(Session) ->
    % NOTE
    % Supposedly, this is needed to signal to the storage that messages
    % are not needed anymore, because they are now a part of session and
    % persisted as such. Though, transactional guarantees are missing AFAICS.
    % emqx_persistent_session:mark_as_delivered(Session#session.id, Delivers);
    ok;
persist_delivers(_Delivers, _Session) ->
    ok.

timestamp() ->
    erlang:system_time(millisecond).

%%--------------------------------------------------------------------
%% Inc message/delivery expired counter
%%--------------------------------------------------------------------
inc_delivery_expired_cnt() ->
    inc_delivery_expired_cnt(1).

inc_delivery_expired_cnt(N) ->
    ok = inc_pd('send_msg.dropped', N),
    ok = inc_pd('send_msg.dropped.expired', N),
    ok = emqx_metrics:inc('delivery.dropped', N),
    emqx_metrics:inc('delivery.dropped.expired', N).

inc_await_pubrel_timeout(N) ->
    ok = inc_pd('recv_msg.dropped', N),
    ok = inc_pd('recv_msg.dropped.await_pubrel_timeout', N),
    ok = emqx_metrics:inc('messages.dropped', N),
    emqx_metrics:inc('messages.dropped.await_pubrel_timeout', N).

inc_pd(Key) ->
    inc_pd(Key, 1).
inc_pd(Key, Inc) ->
    _ = emqx_pd:inc_counter(Key, Inc),
    ok.

%%--------------------------------------------------------------------
%% Next Packet Id
%%--------------------------------------------------------------------

obtain_next_pkt_id(Session) ->
    {Session#session.next_pkt_id, next_pkt_id(Session)}.

next_pkt_id(Session = #session{next_pkt_id = ?MAX_PACKET_ID}) ->
    Session#session{next_pkt_id = 1};
next_pkt_id(Session = #session{next_pkt_id = Id}) ->
    Session#session{next_pkt_id = Id + 1}.

%%--------------------------------------------------------------------
%% Message Latency Stats
%%--------------------------------------------------------------------
on_delivery_completed(
    Msg,
    #session{created_at = CreateAt, clientid = ClientId}
) ->
    emqx:run_hook(
        'delivery.completed',
        [
            Msg,
            #{session_birth_time => CreateAt, clientid => ClientId}
        ]
    ).

mark_begin_deliver(Msg) ->
    emqx_message:set_header(deliver_begin_at, erlang:system_time(millisecond), Msg).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

-compile({inline, [sort_fun/2, batch_n/1, with_ts/1, age/2]}).

sort_fun({_, A}, {_, B}) ->
    A#inflight_data.timestamp =< B#inflight_data.timestamp.

batch_n(Inflight) ->
    case emqx_inflight:max_size(Inflight) of
        0 -> ?DEFAULT_BATCH_N;
        Sz -> Sz - emqx_inflight:size(Inflight)
    end.

with_ts(Msg) ->
    #inflight_data{
        phase = wait_ack,
        message = Msg,
        timestamp = erlang:system_time(millisecond)
    }.

age(Now, Ts) -> Now - Ts.

%%--------------------------------------------------------------------
%% For CT tests
%%--------------------------------------------------------------------

set_field(Name, Value, Session) ->
    Pos = emqx_utils:index_of(Name, record_info(fields, session)),
    setelement(Pos + 1, Session, Value).

get_mqueue(#session{mqueue = Q}) ->
    emqx_mqueue:to_list(Q).
