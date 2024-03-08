%%--------------------------------------------------------------------
%% Copyright (c) 2023-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc Main interface module for `emqx_durable_storage' application.
%%
%% It takes care of forwarding calls to the underlying DBMS. Currently
%% only the embedded `emqx_ds_replication_layer' storage is supported,
%% so all the calls are simply passed through.
-module(emqx_ds).

%% Management API:
-export([
    base_dir/0,
    open_db/2,
    update_db_config/2,
    add_generation/1,
    list_generations_with_lifetimes/1,
    drop_generation/2,
    drop_db/1
]).

%% Message storage API:
-export([store_batch/2, store_batch/3]).

%% Message replay API:
-export([
    get_streams/3,
    make_iterator/4,
    update_iterator/3,
    next/3, next/4,
    iterator_info_extractor/2,
    extract_iterator_info/3
]).

%% Message delete API:
-export([get_delete_streams/3, make_delete_iterator/4, delete_next/4]).

%% Misc. API:
-export([count/1]).

-export_type([
    create_db_opts/0,
    db/0,
    time/0,
    topic/0,
    stream/0,
    delete_stream/0,
    delete_selector/0,
    rank_x/0,
    rank_y/0,
    stream_rank/0,
    iterator/0,
    delete_iterator/0,
    iterator_id/0,
    message_id/0,
    message_key/0,
    message_store_opts/0,
    next_result/1, next_result/0,
    delete_next_result/1, delete_next_result/0,
    next_opts/0,
    store_batch_result/0,
    make_iterator_result/1, make_iterator_result/0,
    make_delete_iterator_result/1, make_delete_iterator_result/0,
    iterator_info_extractor/0,
    iterator_info_res/0,

    ds_specific_stream/0,
    ds_specific_iterator/0,
    ds_specific_generation_rank/0,
    ds_specific_delete_stream/0,
    ds_specific_delete_iterator/0,
    generation_rank/0,
    generation_info/0
]).

-include_lib("typerefl/include/types.hrl").

%%================================================================================
%% Type declarations
%%================================================================================

-define(APP, emqx_durable_storage).

-type db() :: atom().

%% Parsed topic.
-type topic() :: list(binary()).

%% Parsed topic filter.
-type topic_filter() :: list(binary() | '+' | '#' | '').

-type rank_x() :: term().

-type rank_y() :: integer().

-type stream_rank() :: {rank_x(), rank_y()}.

%% TODO: Not implemented
-type iterator_id() :: term().

-opaque iterator() :: ds_specific_iterator().

-opaque delete_iterator() :: ds_specific_delete_iterator().

-opaque stream() :: ds_specific_stream().

-opaque delete_stream() :: ds_specific_delete_stream().

-type delete_selector() :: fun((emqx_types:message()) -> boolean()).

-type ds_specific_iterator() :: term().

-type ds_specific_stream() :: term().

-type ds_specific_generation_rank() :: term().

-type message_key() :: binary().

-type store_batch_result() :: ok | {error, _}.

-type make_iterator_result(Iterator) :: {ok, Iterator} | {error, _}.

-type make_iterator_result() :: make_iterator_result(iterator()).

-type next_result(Iterator) ::
    {ok, Iterator, [{message_key(), emqx_types:message()}]} | {ok, end_of_stream} | {error, _}.

-type next_result() :: next_result(iterator()).

-type ds_specific_delete_iterator() :: term().

-type ds_specific_delete_stream() :: term().

-type make_delete_iterator_result(DeleteIterator) :: {ok, DeleteIterator} | {error, term()}.

-type make_delete_iterator_result() :: make_delete_iterator_result(delete_iterator()).

-type delete_next_result(DeleteIterator) ::
    {ok, DeleteIterator, non_neg_integer()} | {ok, end_of_stream} | {error, term()}.

-type delete_next_result() :: delete_next_result(delete_iterator()).

%% Timestamp
%% Earliest possible timestamp is 0.
%% TODO granularity?  Currently, we should always use milliseconds, as that's the unit we
%% use in emqx_guid.  Otherwise, the iterators won't match the message timestamps.
-type time() :: non_neg_integer().

-type message_store_opts() ::
    #{
        %% Whether to wait until the message storage has been acknowledged to return from
        %% `store_batch'.
        %% Default: `true'.
        sync => boolean(),
        %% Whether the whole batch given to `store_batch' should be inserted atomically as
        %% a unit.  Note: the whole batch must be crafted so that it belongs to a single
        %% shard (if applicable to the backend), as the batch will be split accordingly
        %% even if this flag is `true'.
        %% Default: `false'.
        atomic => boolean()
    }.

-type generic_db_opts() ::
    #{
        backend := atom(),
        serialize_by => clientid | topic,
        _ => _
    }.

-type create_db_opts() ::
    emqx_ds_replication_layer:builtin_db_opts() | generic_db_opts().

-type message_id() :: emqx_ds_replication_layer:message_id().

%% An opaque term identifying a generation.  Each implementation will possibly add
%% information to this term to match its inner structure (e.g.: by embedding the shard id,
%% in the case of `emqx_ds_replication_layer').
-opaque generation_rank() :: ds_specific_generation_rank().

-type generation_info() :: #{
    created_at := time(),
    since := time(),
    until := time() | undefined
}.

-define(persistent_term(DB), {emqx_ds_db_backend, DB}).

-define(module(DB), (persistent_term:get(?persistent_term(DB)))).

-type iterator_info_extractor() :: {module(), atom(), [term()]}.

-type iterator_info_res() :: #{
    last_seen_key := undefined | message_key(),
    topic_filter := topic_filter()
}.

-type next_opts() :: #{use_cache => boolean()}.

-export([to_topic_filter/1]).
-typerefl_from_string({topic_filter/0, emqx_ds, to_topic_filter}).
-reflect_type([topic_filter/0]).

%%================================================================================
%% Behavior callbacks
%%================================================================================

-callback open_db(db(), create_db_opts()) -> ok | {error, _}.

-callback add_generation(db()) -> ok | {error, _}.

-callback update_db_config(db(), create_db_opts()) -> ok | {error, _}.

-callback list_generations_with_lifetimes(db()) ->
    #{generation_rank() => generation_info()}.

-callback drop_generation(db(), generation_rank()) -> ok | {error, _}.

-callback drop_db(db()) -> ok | {error, _}.

-callback store_batch(db(), [emqx_types:message()], message_store_opts()) -> store_batch_result().

-callback get_streams(db(), topic_filter(), time()) -> [{stream_rank(), ds_specific_stream()}].

-callback make_iterator(db(), ds_specific_stream(), topic_filter(), time()) ->
    make_iterator_result(ds_specific_iterator()).

-callback update_iterator(db(), ds_specific_iterator(), message_key()) ->
    make_iterator_result(ds_specific_iterator()).

-callback next(db(), Iterator, pos_integer()) -> next_result(Iterator).

-callback get_delete_streams(db(), topic_filter(), time()) -> [ds_specific_delete_stream()].

-callback make_delete_iterator(db(), ds_specific_delete_stream(), topic_filter(), time()) ->
    make_delete_iterator_result(ds_specific_delete_iterator()).

-callback delete_next(db(), DeleteIterator, delete_selector(), pos_integer()) ->
    delete_next_result(DeleteIterator).

-callback count(db()) -> non_neg_integer().

-callback iterator_info_extractor(db(), ds_specific_stream()) ->
    undefined | {ok, iterator_info_extractor()}.

-callback extract_iterator_info(ds_specific_iterator(), iterator_info_extractor()) ->
    iterator_info_res().

-optional_callbacks([
    list_generations_with_lifetimes/1,
    drop_generation/2,

    iterator_info_extractor/2,
    extract_iterator_info/2,

    get_delete_streams/3,
    make_delete_iterator/4,
    delete_next/4,

    count/1
]).

%%================================================================================
%% API funcions
%%================================================================================

-spec base_dir() -> file:filename().
base_dir() ->
    application:get_env(?APP, db_data_dir, emqx:data_dir()).

%% @doc Different DBs are completely independent from each other. They
%% could represent something like different tenants.
-spec open_db(db(), create_db_opts()) -> ok.
open_db(DB, Opts = #{backend := Backend}) when Backend =:= builtin orelse Backend =:= fdb ->
    Module =
        case Backend of
            builtin -> emqx_ds_replication_layer;
            fdb -> emqx_fdb_ds
        end,
    persistent_term:put(?persistent_term(DB), Module),
    ?module(DB):open_db(DB, Opts).

-spec add_generation(db()) -> ok.
add_generation(DB) ->
    ?module(DB):add_generation(DB).

-spec update_db_config(db(), create_db_opts()) -> ok.
update_db_config(DB, Opts) ->
    ?module(DB):update_db_config(DB, Opts).

-spec list_generations_with_lifetimes(db()) -> #{generation_rank() => generation_info()}.
list_generations_with_lifetimes(DB) ->
    Mod = ?module(DB),
    call_if_implemented(Mod, list_generations_with_lifetimes, [DB], #{}).

-spec drop_generation(db(), ds_specific_generation_rank()) -> ok | {error, _}.
drop_generation(DB, GenId) ->
    Mod = ?module(DB),
    case erlang:function_exported(Mod, drop_generation, 2) of
        true ->
            Mod:drop_generation(DB, GenId);
        false ->
            {error, not_implemented}
    end.

%% @doc TODO: currently if one or a few shards are down, they won't be

%% deleted.
-spec drop_db(db()) -> ok.
drop_db(DB) ->
    case persistent_term:get(?persistent_term(DB), undefined) of
        undefined ->
            ok;
        Module ->
            Module:drop_db(DB)
    end.

-spec store_batch(db(), [emqx_types:message()], message_store_opts()) -> store_batch_result().
store_batch(DB, Msgs, Opts) ->
    ?module(DB):store_batch(DB, Msgs, Opts).

-spec store_batch(db(), [emqx_types:message()]) -> store_batch_result().
store_batch(DB, Msgs) ->
    store_batch(DB, Msgs, #{}).

%% @doc Get a list of streams needed for replaying a topic filter.
%%
%% Motivation: under the hood, EMQX may store different topics at
%% different locations or even in different databases. A wildcard
%% topic filter may require pulling data from any number of locations.
%%
%% Stream is an abstraction exposed by `emqx_ds' that, on one hand,
%% reflects the notion that different topics can be stored
%% differently, but hides the implementation details.
%%
%% While having to work with multiple iterators to replay a topic
%% filter may be cumbersome, it opens up some possibilities:
%%
%% 1. It's possible to parallelize replays
%%
%% 2. Streams can be shared between different clients to implement
%% shared subscriptions
%%
%% IMPORTANT RULES:
%%
%% 0. There is no 1-to-1 mapping between MQTT topics and streams. One
%% stream can contain any number of MQTT topics.
%%
%% 1. New streams matching the topic filter and start time can appear
%% without notice, so the replayer must periodically call this
%% function to get the updated list of streams.
%%
%% 2. Streams may depend on one another. Therefore, care should be
%% taken while replaying them in parallel to avoid out-of-order
%% replay. This function returns stream together with its
%% "coordinate": `stream_rank()'.
%%
%% Stream rank is a tuple of two terms, let's call them X and Y. If
%% X coordinate of two streams is different, they are independent and
%% can be replayed in parallel. If it's the same, then the stream with
%% smaller Y coordinate should be replayed first. If Y coordinates are
%% equal, then the streams are independent.
%%
%% Stream is fully consumed when `next/3' function returns
%% `end_of_stream'. Then and only then the client can proceed to
%% replaying streams that depend on the given one.
-spec get_streams(db(), topic_filter(), time()) -> [{stream_rank(), stream()}].
get_streams(DB, TopicFilter, StartTime) ->
    ?module(DB):get_streams(DB, TopicFilter, StartTime).

-spec make_iterator(db(), stream(), topic_filter(), time()) -> make_iterator_result().
make_iterator(DB, Stream, TopicFilter, StartTime) ->
    ?module(DB):make_iterator(DB, Stream, TopicFilter, StartTime).

-spec update_iterator(db(), iterator(), message_key()) ->
    make_iterator_result().
update_iterator(DB, OldIter, DSKey) ->
    ?module(DB):update_iterator(DB, OldIter, DSKey).

-spec next(db(), iterator(), pos_integer()) -> next_result().
next(DB, Iter, BatchSize) ->
    ?module(DB):next(DB, Iter, BatchSize).

-spec next(db(), iterator(), pos_integer(), next_opts()) -> next_result().
next(DB, Iter, BatchSize, Opts) ->
    ?module(DB):next(DB, Iter, BatchSize, Opts).

-spec get_delete_streams(db(), topic_filter(), time()) -> [delete_stream()].
get_delete_streams(DB, TopicFilter, StartTime) ->
    Mod = ?module(DB),
    call_if_implemented(Mod, get_delete_streams, [DB, TopicFilter, StartTime], []).

-spec make_delete_iterator(db(), ds_specific_delete_stream(), topic_filter(), time()) ->
    make_delete_iterator_result().
make_delete_iterator(DB, Stream, TopicFilter, StartTime) ->
    Mod = ?module(DB),
    call_if_implemented(
        Mod, make_delete_iterator, [DB, Stream, TopicFilter, StartTime], {error, not_implemented}
    ).

-spec delete_next(db(), delete_iterator(), delete_selector(), pos_integer()) ->
    delete_next_result().
delete_next(DB, Iter, Selector, BatchSize) ->
    Mod = ?module(DB),
    call_if_implemented(
        Mod, delete_next, [DB, Iter, Selector, BatchSize], {error, not_implemented}
    ).

-spec count(db()) -> non_neg_integer() | {error, not_implemented}.
count(DB) ->
    Mod = ?module(DB),
    call_if_implemented(Mod, count, [DB], {error, not_implemented}).

-spec iterator_info_extractor(db(), stream()) -> undefined | {ok, iterator_info_extractor()}.
iterator_info_extractor(DB, Stream) ->
    Mod = ?module(DB),
    call_if_implemented(Mod, iterator_info_extractor, [DB, Stream], undefined).

-spec extract_iterator_info(db(), iterator(), iterator_info_extractor()) ->
    iterator_info_res().
extract_iterator_info(DB, Iter, ExtractorFn) ->
    ?module(DB):extract_iterator_info(Iter, ExtractorFn).

%%================================================================================
%% Internal exports
%%================================================================================

to_topic_filter(TopicStr) ->
    TopicBin = unicode:characters_to_binary(TopicStr),
    try
        emqx_topic:validate(filter, TopicBin),
        {ok, emqx_topic:words(TopicBin)}
    catch
        error:Reason ->
            {error, Reason}
    end.

%%================================================================================
%% Internal functions
%%================================================================================

call_if_implemented(Mod, Fun, Args, Default) ->
    case erlang:function_exported(Mod, Fun, length(Args)) of
        true ->
            apply(Mod, Fun, Args);
        false ->
            Default
    end.
