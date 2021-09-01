%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_authn_jwt).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).
-behaviour(emqx_authentication).

-export([ fields/1 ]).

-export([ refs/0
        , create/1
        , update/2
        , authenticate/2
        , destroy/1
        ]).

%%------------------------------------------------------------------------------
%% Hocon Schema
%%------------------------------------------------------------------------------

fields('hmac-based') ->
    [ {use_jwks,              {enum, [false]}}
    , {algorithm,             {enum, ['hmac-based']}}
    , {secret,                fun secret/1}
    , {secret_base64_encoded, fun secret_base64_encoded/1}
    ] ++ common_fields();

fields('public-key') ->
    [ {use_jwks,              {enum, [false]}}
    , {algorithm,             {enum, ['public-key']}}
    , {certificate,           fun certificate/1}
    ] ++ common_fields();

fields('jwks') ->
    [ {use_jwks,              {enum, [true]}}
    , {endpoint,              fun endpoint/1}
    , {refresh_interval,      fun refresh_interval/1}
    , {ssl,                   #{type => hoconsc:union(
                                         [ hoconsc:ref(?MODULE, ssl_enable)
                                         , hoconsc:ref(?MODULE, ssl_disable)
                                         ]),
                                default => #{<<"enable">> => false}}}
    ] ++ common_fields();

fields(ssl_enable) ->
    [ {enable,                 #{type => true}}
    , {cacertfile,             fun cacertfile/1}
    , {certfile,               fun certfile/1}
    , {keyfile,                fun keyfile/1}
    , {verify,                 fun verify/1}
    , {server_name_indication, fun server_name_indication/1}
    ];

fields(ssl_disable) ->
    [ {enable, #{type => false}} ].

common_fields() ->
    [ {mechanism,       {enum, [jwt]}}
    , {verify_claims,   fun verify_claims/1}
    ] ++ emqx_authn_schema:common_fields().

secret(type) -> binary();
secret(_) -> undefined.

secret_base64_encoded(type) -> boolean();
secret_base64_encoded(default) -> false;
secret_base64_encoded(_) -> undefined.

certificate(type) -> string();
certificate(_) -> undefined.

endpoint(type) -> string();
endpoint(_) -> undefined.

refresh_interval(type) -> integer();
refresh_interval(default) -> 300;
refresh_interval(validator) -> [fun(I) -> I > 0 end];
refresh_interval(_) -> undefined.

cacertfile(type) -> string();
cacertfile(_) -> undefined.

certfile(type) -> string();
certfile(_) -> undefined.

keyfile(type) -> string();
keyfile(_) -> undefined.

verify(type) -> boolean();
verify(default) -> false;
verify(_) -> undefined.

server_name_indication(type) -> string();
server_name_indication(_) -> undefined.

verify_claims(type) -> list();
verify_claims(default) -> #{};
verify_claims(validate) -> [fun check_verify_claims/1];
verify_claims(converter) ->
    fun(VerifyClaims) ->
        maps:to_list(VerifyClaims)
    end;
verify_claims(_) -> undefined.

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

refs() ->
   [ hoconsc:ref(?MODULE, 'hmac-based')
   , hoconsc:ref(?MODULE, 'public-key')
   , hoconsc:ref(?MODULE, 'jwks')
   ].

create(#{verify_claims := VerifyClaims} = Config) ->
    create2(Config#{verify_claims => handle_verify_claims(VerifyClaims)}).

update(#{use_jwks := false} = Config, #{jwk := Connector})
  when is_pid(Connector) ->
    _ = emqx_authn_jwks_connector:stop(Connector),
    create(Config);

update(#{use_jwks := false} = Config, _) ->
    create(Config);

update(#{use_jwks := true} = Config, #{jwk := Connector} = State)
  when is_pid(Connector) ->
    ok = emqx_authn_jwks_connector:update(Connector, Config),
    case maps:get(verify_cliams, Config, undefined) of
        undefined ->
            {ok, State};
        VerifyClaims ->
            {ok, State#{verify_claims => handle_verify_claims(VerifyClaims)}}
    end;

update(#{use_jwks := true} = Config, _) ->
    create(Config).

authenticate(#{auth_method := _}, _) ->
    ignore;
authenticate(Credential = #{password := JWT}, #{jwk := JWK,
                                                verify_claims := VerifyClaims0}) ->
    JWKs = case erlang:is_pid(JWK) of
               false ->
                   [JWK];
               true ->
                   {ok, JWKs0} = emqx_authn_jwks_connector:get_jwks(JWK),
                   JWKs0
           end,
    VerifyClaims = replace_placeholder(VerifyClaims0, Credential),
    case verify(JWT, JWKs, VerifyClaims) of
        {ok, Extra} -> {ok, Extra};
        {error, invalid_signature} -> ignore;
        {error, {claims, _}} -> {error, bad_username_or_password}
    end.

destroy(#{jwk := Connector}) when is_pid(Connector) ->
    _ = emqx_authn_jwks_connector:stop(Connector),
    ok;
destroy(_) ->
    ok.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

create2(#{use_jwks := false,
          algorithm := 'hmac-based',
          secret := Secret0,
          secret_base64_encoded := Base64Encoded,
          verify_claims := VerifyClaims}) ->
    Secret = case Base64Encoded of
                 true ->
                     base64:decode(Secret0);
                 false ->
                     Secret0
             end,
    JWK = jose_jwk:from_oct(Secret),
    {ok, #{jwk => JWK,
           verify_claims => VerifyClaims}};

create2(#{use_jwks := false,
          algorithm := 'public-key',
          certificate := Certificate,
          verify_claims := VerifyClaims}) ->
    JWK = jose_jwk:from_pem_file(Certificate),
    {ok, #{jwk => JWK,
           verify_claims => VerifyClaims}};

create2(#{use_jwks := true,
          verify_claims := VerifyClaims,
          ssl := #{enable := Enable} = SSL} = Config) ->
    SSLOpts = case Enable of
                  true -> maps:without([enable], SSL);
                  false -> #{}
              end,
    case emqx_authn_jwks_connector:start_link(Config#{ssl_opts => SSLOpts}) of
        {ok, Connector} ->
            {ok, #{jwk => Connector,
                   verify_claims => VerifyClaims}};
        {error, Reason} ->
            {error, Reason}
    end.

replace_placeholder(L, Variables) ->
    replace_placeholder(L, Variables, []).

replace_placeholder([], _Variables, Acc) ->
    Acc;
replace_placeholder([{Name, {placeholder, PL}} | More], Variables, Acc) ->
    Value = maps:get(PL, Variables),
    replace_placeholder(More, Variables, [{Name, Value} | Acc]);
replace_placeholder([{Name, Value} | More], Variables, Acc) ->
    replace_placeholder(More, Variables, [{Name, Value} | Acc]).

verify(_JWS, [], _VerifyClaims) ->
    {error, invalid_signature};
verify(JWS, [JWK | More], VerifyClaims) ->
    try jose_jws:verify(JWK, JWS) of
        {true, Payload, _JWS} ->
            Claims = emqx_json:decode(Payload, [return_maps]),
            case verify_claims(Claims, VerifyClaims) of
                ok ->
                    {ok, #{superuser => maps:get(<<"superuser">>, Claims, false)}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {false, _, _} ->
            verify(JWS, More, VerifyClaims)
    catch
        _:_Reason:_Stacktrace ->
            %% TODO: Add log
            {error, invalid_signature}
    end.

verify_claims(Claims, VerifyClaims0) ->
    Now = os:system_time(seconds),
    VerifyClaims = [{<<"exp">>, fun(ExpireTime) ->
                                    Now < ExpireTime
                                end},
                    {<<"iat">>, fun(IssueAt) ->
                                    IssueAt =< Now
                                end},
                    {<<"nbf">>, fun(NotBefore) ->
                                    NotBefore =< Now
                                end}] ++ VerifyClaims0,
    do_verify_claims(Claims, VerifyClaims).

do_verify_claims(_Claims, []) ->
    ok;
do_verify_claims(Claims, [{Name, Fun} | More]) when is_function(Fun) ->
    case maps:take(Name, Claims) of
        error ->
            do_verify_claims(Claims, More);
        {Value, NClaims} ->
            case Fun(Value) of
                true ->
                    do_verify_claims(NClaims, More);
                _ ->
                    {error, {claims, {Name, Value}}}
            end
    end;
do_verify_claims(Claims, [{Name, Value} | More]) ->
    case maps:take(Name, Claims) of
        error ->
            {error, {missing_claim, Name}};
        {Value, NClaims} ->
            do_verify_claims(NClaims, More);
        {Value0, _} ->
            {error, {claims, {Name, Value0}}}
    end.

check_verify_claims(Conf) ->
    Claims = hocon_schema:get_value("verify_claims", Conf),
    do_check_verify_claims(Claims).

do_check_verify_claims([]) ->
    false;
do_check_verify_claims([{Name, Expected} | More]) ->
    check_claim_name(Name) andalso
    check_claim_expected(Expected) andalso
    do_check_verify_claims(More).

check_claim_name(exp) ->
    false;
check_claim_name(iat) ->
    false;
check_claim_name(nbf) ->
    false;
check_claim_name(_) ->
    true.

check_claim_expected(Expected) ->
    try handle_placeholder(Expected) of
        _ -> true
    catch
        _:_ ->
            false
    end.

handle_verify_claims(VerifyClaims) ->
    handle_verify_claims(VerifyClaims, []).

handle_verify_claims([], Acc) ->
    Acc;
handle_verify_claims([{Name, Expected0} | More], Acc) ->
    Expected = handle_placeholder(Expected0),
    handle_verify_claims(More, [{Name, Expected} | Acc]).

handle_placeholder(Placeholder0) ->
    case re:run(Placeholder0, "^\\$\\{[a-z0-9\\-]+\\}$", [{capture, all}]) of
        {match, [{Offset, Length}]} ->
            Placeholder1 = binary:part(Placeholder0, Offset + 2, Length - 3),
            Placeholder2 = validate_placeholder(Placeholder1),
            {placeholder, Placeholder2};
        nomatch ->
            Placeholder0
    end.

validate_placeholder(<<"mqtt-clientid">>) ->
    clientid;
validate_placeholder(<<"mqtt-username">>) ->
    username.
