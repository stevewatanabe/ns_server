%% @author Couchbase <info@couchbase.com>
%% @copyright 2009-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% @doc Web server for menelaus.

-module(menelaus_auth).
-author('Northscale <info@northscale.com>').

-include("ns_common.hrl").
-include("rbac.hrl").
-include_lib("ns_common/include/cut.hrl").

-define(count_auth(Type, Res),
        ns_server_stats:notify_counter({<<"authentications">>,
                                        [{<<"type">>, <<Type>>},
                                         {<<"res">>, <<Res>>}]})).

-export([has_permission/2,
         is_internal/1,
         filter_accessible_buckets/3,
         extract_auth/1,
         extract_identity_from_cert/1,
         extract_ui_auth_token/1,
         uilogin/2,
         uilogin_phase2/4,
         can_use_cert_for_auth/1,
         complete_uilogout/1,
         maybe_refresh_token/1,
         get_authn_res/1,
         get_identity/1,
         get_authenticated_identity/1,
         get_user_id/1,
         get_session_id/1,
         is_UI_req/1,
         verify_rest_auth/2,
         new_session_id/0,
         get_resp_headers/1,
         acting_on_behalf/1,
         init_auth/1,
         on_behalf_context/1,
         get_authn_res_from_on_behalf_of/3]).

%% rpc from ns_couchdb node
-export([authenticate/1,
         authenticate_external/2]).

%% External API

new_session_id() ->
    base64:encode(crypto:strong_rand_bytes(16)).

filter_accessible_buckets(Fun, Buckets, Req) ->
    AuthnRes = get_authn_res(Req),
    Roles = menelaus_roles:get_compiled_roles(AuthnRes),
    lists:filter(?cut(menelaus_roles:is_allowed(Fun(_), Roles)), Buckets).

-spec get_cookies(mochiweb_request()) -> [{string(), string()}].
get_cookies(Req) ->
    case mochiweb_request:get_header_value("Cookie", Req) of
        undefined -> [];
        RawCookies ->
            RV = mochiweb_cookies:parse_cookie(RawCookies),
            RV
    end.

-spec lookup_cookie(mochiweb_request(), string()) -> string() | undefined.
lookup_cookie(Req, Cookie) ->
    proplists:get_value(Cookie, get_cookies(Req)).

-spec ui_auth_cookie_name(mochiweb_request()) -> string().
ui_auth_cookie_name(Req) ->
    %% NOTE: cookies are _not_ per-port and in general quite
    %% unexpectedly a stupid piece of mess. In order to have working
    %% dev mode clusters where different nodes are at different ports
    %% we use different cookie names for different host:port
    %% combination.
    case mochiweb_request:get_header_value("host", Req) of
        undefined ->
            "ui-auth";
        Host ->
            "ui-auth-" ++ mochiweb_util:quote_plus(Host)
    end.

-spec extract_ui_auth_token(mochiweb_request()) ->
                                    {token, auth_token() | undefined} | not_ui.
extract_ui_auth_token(Req) ->
    %% /saml/deauth is called technically outside of UI so it doesn't have
    %% the ns-server-ui header, while it still needs to be authenticated
    %% to perform the logout
    case mochiweb_request:get_header_value("ns-server-ui", Req) == "yes" orelse
         mochiweb_request:get(raw_path, Req) == "/saml/deauth" of
        true ->
            Token =
                case mochiweb_request:get_header_value("ns-server-auth-token",
                                                       Req) of
                    undefined ->
                        lookup_cookie(Req, ui_auth_cookie_name(Req));
                    T ->
                        T
                end,
            {token, Token};
        false ->
            not_ui
    end.

-spec generate_auth_cookie(mochiweb_request(), auth_token()) -> {string(), string()}.
generate_auth_cookie(Req, Token) ->
    Options = [{path, "/"}, {http_only, true}],
    SslOptions = case mochiweb_request:get(socket, Req) of
                     {ssl, _} -> [{secure, true}];
                     _ -> ""
                 end,
    mochiweb_cookies:cookie(ui_auth_cookie_name(Req), Token, Options ++ SslOptions).

-spec kill_auth_cookie(mochiweb_request()) -> {string(), string()}.
kill_auth_cookie(Req) ->
    {Name, Content} = generate_auth_cookie(Req, ""),
    {Name, Content ++ "; expires=Thu, 01 Jan 1970 00:00:00 GMT"}.

-spec complete_uilogout(mochiweb_request()) ->
                {Session :: #uisession{} | undefined, [{string(), string()}]}.
complete_uilogout(Req) ->
    case get_authn_res(Req) of
        #authn_res{type = ui, session_id = SessionId} ->
            UISession = menelaus_ui_auth:logout(SessionId),
            ns_audit:logout(Req),
            {UISession, [kill_auth_cookie(Req)]};
        _ ->
            {undefined, []}
    end.

-spec maybe_refresh_token(mochiweb_request()) -> [{string(), string()}].
maybe_refresh_token(Req) ->
    case extract_ui_auth_token(Req) of
        not_ui -> [];
        {token, undefined} -> [];
        {token, Token} ->
            case menelaus_ui_auth:maybe_refresh(Token) of
                nothing ->
                    [];
                {new_token, NewToken} ->
                    [generate_auth_cookie(Req, NewToken)]
            end
    end.

maybe_store_rejected_user(undefined, Req) ->
    Req;
maybe_store_rejected_user(User, Req) ->
    store_authn_res(#authn_res{identity = {User, unknown}}, Req).

store_authn_res(#authn_res{} = AuthnRes, Req) ->
    mochiweb_request:set_meta(authn_res, AuthnRes, Req).

append_resp_headers(Headers, Req) ->
    CurHeaders = mochiweb_request:get_meta(resp_headers, [], Req),
    mochiweb_request:set_meta(resp_headers, CurHeaders ++ Headers, Req).

get_resp_headers(Req) ->
    mochiweb_request:get_meta(resp_headers, [], Req).

-spec get_authn_res(mochiweb_request()) -> #authn_res{} | undefined.
get_authn_res(Req) ->
    mochiweb_request:get_meta(authn_res, undefined, Req).

-spec get_identity(mochiweb_request()) -> rbac_identity() | undefined.
get_identity(Req) ->
    case get_authn_res(Req) of
        undefined -> undefined;
        #authn_res{identity = Id} -> Id
    end.

-spec get_authenticated_identity(mochiweb_request()) ->
          rbac_identity() | undefined.
get_authenticated_identity(Req) ->
    case get_authn_res(Req) of
        undefined -> undefined;
        #authn_res{authenticated_identity = Id} -> Id
    end.

-spec get_session_id(mochiweb_request()) -> binary() | undefined.
get_session_id(Req) ->
    case get_authn_res(Req) of
        undefined -> undefined;
        #authn_res{session_id = SessionId} -> SessionId
    end.

-spec get_user_id(mochiweb_request()) -> rbac_user_id() | undefined.
get_user_id(Req) ->
    case mochiweb_request:get_meta(authn_res, undefined, Req) of
        #authn_res{identity = {Name, _}} -> Name;
        undefined -> undefined
    end.

is_UI_req(Req) ->
    case get_authn_res(Req) of
        undefined -> false;
        #authn_res{type = ui} -> true;
        #authn_res{} -> false
    end.

-spec extract_auth(mochiweb_request()) -> {User :: string(), Passwd :: string()}
                                              | {scram_sha, string()}
                                              | {token, string() | undefined}
                                              | {client_cert_auth, string()}
                                              | undefined.
extract_auth(Req) ->
    case extract_ui_auth_token(Req) of
        {token, Token} ->
            {token, Token};
        not_ui ->
            Sock = mochiweb_request:get(socket, Req),
            case ns_ssl_services_setup:get_user_name_from_client_cert(Sock) of
                undefined ->
                    case mochiweb_request:get_header_value("authorization", Req) of
                        "Basic " ++ Value ->
                            parse_basic_auth_header(Value);
                        "SCRAM-" ++ Value ->
                            {scram_sha, Value};
                        undefined ->
                            undefined;
                        _ ->
                            error
                    end;
                failed ->
                    error;
                UName ->
                    {client_cert_auth, UName}
            end
    end.

get_rejected_user(Auth) ->
    case Auth of
        {client_cert_auth, User} ->
            User;
        {User, _} when is_list(User) ->
            User;
        _ ->
            undefined
    end.

parse_basic_auth_header(Value) ->
    case (catch base64:decode_to_string(Value)) of
        UserPasswordStr when is_list(UserPasswordStr) ->
            case string:chr(UserPasswordStr, $:) of
                0 ->
                    case UserPasswordStr of
                        "" ->
                            undefined;
                        _ ->
                            {UserPasswordStr, ""}
                    end;
                I ->
                    {string:substr(UserPasswordStr, 1, I - 1),
                     string:substr(UserPasswordStr, I + 1)}
            end;
        _ ->
            error
    end.

-spec has_permission(rbac_permission(), mochiweb_request()) -> boolean().
has_permission(Permission, Req) ->
    menelaus_roles:is_allowed(Permission, get_authn_res(Req)).

-spec is_internal(mochiweb_request()) -> boolean().
is_internal(Req) ->
    is_internal_identity(get_identity(Req)).

is_internal_identity({"@" ++ _, admin}) -> true;
is_internal_identity(_) -> false.

init_auth(Identity) ->
    #authn_res{identity = Identity, authenticated_identity = Identity}.

-spec authenticate(error | undefined |
                   {token, auth_token()} |
                   {scram_sha, string()} |
                   {client_cert_auth, string()} |
                   {rbac_user_id(), rbac_password()}) ->
          {ok, #authn_res{}, [RespHeader]} |
          {error, auth_failure | temporary_failure} |
          {unfinished, RespHeaders :: [RespHeader]}
                                        when RespHeader :: {string(), string()}.
authenticate(error) ->
    ?count_auth("error", "failure"),
    {error, auth_failure};
authenticate(undefined) ->
    ?count_auth("anon", "succ"),
    {ok, init_auth({"", anonymous}), []};
authenticate({token, Token} = Param) ->
    ?call_on_ns_server_node(
       case menelaus_ui_auth:check(Token) of
           false ->
               ?count_auth("token", "failure"),
               %% this is needed so UI can get /pools on unprovisioned
               %% system with leftover cookie
               case ns_config_auth:is_system_provisioned() of
                   false ->
                       {ok, init_auth({"", wrong_token}), []};
                   true ->
                       {error, auth_failure}
               end;
           {ok, AuthnRes} ->
               ?count_auth("token", "succ"),
               {ok, AuthnRes, []}
       end, [Param]);
authenticate({client_cert_auth, "@" ++ _ = Username}) ->
    ?count_auth("client_cert_int", "succ"),
    {ok, init_auth({Username, admin}), []};
authenticate({client_cert_auth, Username} = Param) ->
    %% Just returning the username as the request is already authenticated based
    %% on the client certificate.
    ?call_on_ns_server_node(
       case ns_config_auth:get_user(admin) of
           Username ->
               ?count_auth("client_cert", "succ"),
               {ok, init_auth({Username, admin}), []};
           _ ->
               Identity = {Username, local},
               case menelaus_users:user_exists(Identity) of
                   true ->
                       ?count_auth("client_cert", "succ"),
                       {ok, init_auth(Identity), []};
                   false ->
                       ?count_auth("client_cert", "failure"),
                       {error, auth_failure}
               end
       end, [Param]);
authenticate({scram_sha, AuthHeader}) ->
    case scram_sha:authenticate(AuthHeader) of
        {ok, Identity, RespHeaders} ->
            ?count_auth("scram_sha", "succ"),
            {ok, init_auth(Identity), RespHeaders};
        {first_step, RespHeaders} ->
            ?count_auth("scram_sha", "succ"),
            {unfinished, RespHeaders};
        auth_failure ->
            ?count_auth("scram_sha", "failure"),
            {error, auth_failure}
    end;
authenticate({Username, Password}) ->
    case ns_config_auth:authenticate(Username, Password) of
        {ok, Id} ->
            ?count_auth("local", "succ"),
            {ok, init_auth(Id), []};
        {error, auth_failure}->
            authenticate_external(Username, Password);
        {error, Reason} ->
            ?count_auth("local", "failure"),
            {error, Reason}
    end.

-spec authenticate_external(rbac_user_id(), rbac_password()) ->
          {error, auth_failure} | {ok, #authn_res{}}.
authenticate_external(Username, Password) ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            case is_external_auth_allowed(Username) andalso
                 (saslauthd_auth:authenticate(Username, Password) orelse
                  ldap_auth_cache:authenticate(Username, Password)) of
                true ->
                    ?count_auth("external", "succ"),
                    {ok, init_auth({Username, external}), []};
                false ->
                    ?count_auth("external", "failure"),
                    {error, auth_failure}
            end;
        true ->
            rpc:call(ns_node_disco:ns_server_node(), ?MODULE,
                     authenticate_external, [Username, Password])
    end.

is_external_auth_allowed("@" ++ _) -> false;
is_external_auth_allowed(Username) ->
    ns_config_auth:get_user(admin) /= Username.

-spec uilogin(mochiweb_request(), list()) -> mochiweb_response().
uilogin(Req, Params) ->
    CertAuth = proplists:get_value("use_cert_for_auth",
                                   mochiweb_request:parse_qs(Req)) =:= "1",
    {User, AuthnStatus} =
        case CertAuth of
            true ->
                S = mochiweb_request:get(socket, Req),
                case ns_ssl_services_setup:get_user_name_from_client_cert(S) of
                    X when X =:= undefined; X =:= failed ->
                        {invalid_client_cert, {error, auth_failure}};
                    UName ->
                        {UName, authenticate({client_cert_auth, UName})}
                end;
            false ->
                Usr = proplists:get_value("user", Params),
                case can_use_cert_for_auth(Req) of
                    must_use ->
                        %% client cert is mandatory, but user is trying
                        %% to use a password to login
                        {Usr, {error, auth_failure}};
                    _ ->
                        Password = proplists:get_value("password", Params),
                        {Usr, authenticate({Usr, Password})}
                end
        end,

    case AuthnStatus of
        {ok, #authn_res{type = tmp, identity = Identity} = AuthnRes,
         RespHeaders} ->
            AuthnRes2 = AuthnRes#authn_res{type = ui,
                                           session_id = new_session_id(),
                                           identity = Identity},
            RandomName = base64:encode(rand:bytes(6)),
            SessionName = <<"UI - ", RandomName/binary>>,
            Req2 = append_resp_headers(RespHeaders, Req),
            case uilogin_phase2(Req2, simple, SessionName, AuthnRes2) of
                {ok, Headers} ->
                    menelaus_util:reply(Req, 200, Headers);
                {error, internal} ->
                    ns_server_stats:notify_counter(
                      <<"rest_request_access_forbidden">>),
                    menelaus_util:reply_json(
                      Req,
                      {[{message, <<"Forbidden. Internal user">>}]},
                      403);
                {error, {access_denied, UIPermission}} ->
                    ns_server_stats:notify_counter(
                      <<"rest_request_access_forbidden">>),
                    menelaus_util:reply_json(
                      Req,
                      menelaus_web_rbac:forbidden_response([UIPermission]),
                      403)
            end;
        {error, auth_failure} ->
            ns_audit:login_failure(
              maybe_store_rejected_user(User, Req)),
            menelaus_util:reply(Req, 400);
        {error, temporary_failure} ->
            ns_audit:login_failure(
              maybe_store_rejected_user(User, Req)),
            Msg = <<"Temporary error occurred. Please try again later.">>,
            menelaus_util:reply_json(Req, Msg, 503)
    end.

uilogin_phase2(Req, UISessionType, UISessionName,
               #authn_res{identity = Identity} = AuthnRes) ->
    UIPermission = {[ui], read},
    case is_internal_identity(Identity) of
        false ->
            case check_permission(AuthnRes, UIPermission) of
                allowed ->
                    Token = menelaus_ui_auth:start_ui_session(UISessionType,
                                                              UISessionName,
                                                              AuthnRes),
                    CookieHeader = generate_auth_cookie(Req, Token),
                    ns_audit:login_success(store_authn_res(AuthnRes, Req)),
                    {ok, [CookieHeader]};
                AuthzRes when AuthzRes == forbidden; AuthzRes == auth_failure ->
                    ns_audit:login_failure(store_authn_res(AuthnRes, Req)),
                    {error, {access_denied, UIPermission}}
            end;
        true ->
            {error, internal}
    end.

-spec can_use_cert_for_auth(mochiweb_request()) ->
                                   can_use | cannot_use | must_use.
can_use_cert_for_auth(Req) ->
    case mochiweb_request:get(socket, Req) of
        {ssl, SSLSock} ->
            CCAState = ns_ssl_services_setup:client_cert_auth_state(),
            case {ssl:peercert(SSLSock), CCAState} of
                {_, "mandatory"} ->
                    must_use;
                {{ok, _Cert}, "enable"} ->
                    can_use;
                _ ->
                    cannot_use
            end;
        _ ->
            cannot_use
    end.

-spec verify_rest_auth(mochiweb_request(),
                       rbac_permission() | no_check | local) ->
                              {auth_failure | forbidden | allowed
                              | temporary_failure, mochiweb_request()}.
verify_rest_auth(Req, Permission) ->
    Auth = extract_auth(Req),
    case authenticate(Auth) of
        {ok, #authn_res{} = AuthnRes,
         RespHeaders} ->
            Req2 = append_resp_headers(RespHeaders, Req),
            case apply_on_behalf_of_authn_res(AuthnRes, Req2) of
                error ->
                    Req3 = maybe_store_rejected_user(
                             get_rejected_user(Auth), Req2),
                    {auth_failure, Req3};
                AuthnRes2 ->
                    {check_permission(AuthnRes2, Permission),
                     store_authn_res(AuthnRes2, Req2)}
            end;
        {error, auth_failure} ->
            Req2 = maybe_store_rejected_user(get_rejected_user(Auth), Req),
            {auth_failure, Req2};
        {error, temporary_failure} ->
            {temporary_failure, Req};
        {unfinished, RespHeaders} ->
            %% When mochiweb decides if it needs to close the connection
            %% it checks if body is "received" (and many other things)
            %% If body is not received it will close the connection
            %% but we don't want it to happen in this case
            %% because it is kind of "graceful" 401
            mochiweb_request:recv_body(Req),
            Req2 = append_resp_headers(RespHeaders, Req),
            {auth_failure, Req2}
    end.

%% Specify authentication context for SAML (and later JWT) in on-behalf-of
%% extras. {User, Domain} aren't sufficient to determine the full set of
%% privileges available to the user.
-spec on_behalf_context(#authn_res{}) -> {string(), boolean()}.
on_behalf_context(#authn_res{session_id = Id}) when is_binary(Id) ->
            {"context:ui=" ++ binary_to_list(Id), true};
on_behalf_context(_) -> {"", false}.

-spec get_authn_res_from_on_behalf_of(User :: rbac_user_id(),
                                      Domain :: rbac_identity_type(),
                                      Context :: string() | undefined) ->
          #authn_res{}.
get_authn_res_from_on_behalf_of(User, Domain, Context) ->
    AuthnRes0 = #authn_res{identity = {User, Domain}},
    case Context of
        undefined -> AuthnRes0;
        "ui=" ++ Id ->
            UiAuthnRes = menelaus_ui_auth:get_authn_res_from_ui_session(Id),
            case UiAuthnRes of
                undefined -> AuthnRes0;
                #authn_res{identity = {User0, Domain0}}
                  when User0 =:= User, Domain0 =:= Domain -> UiAuthnRes;
                _ -> AuthnRes0
            end
    end.

-spec apply_on_behalf_of_authn_res(#authn_res{}, mochiweb_request()) ->
          error | #authn_res{}.
apply_on_behalf_of_authn_res(AuthnRes, Req) ->
    case extract_on_behalf_of_authn_res(Req) of
        error ->
            error;
        undefined ->
            AuthnRes;
        {User, Domain, Context} ->
            %% The permission is formed the way that it is currently granted
            %% to full admins only. We might consider to reformulate it
            %% like {[onbehalf], impersonate} or, such in the upcoming
            %% major release when we will be able to change roles
            %%
            %% Supporting on-behalf for user roles other than full admin
            %% is out of scope now, though it can be easily achived by checking
            %% each permission twice, against the authenticated user and against
            %% the impersonated one
            case menelaus_roles:is_allowed(
                   {[admin, security, admin], impersonate}, AuthnRes) of
                true ->
                    get_authn_res_from_on_behalf_of(User, Domain, Context);
                false ->
                    error
            end
    end.

-spec acting_on_behalf(mochiweb_request()) -> boolean().
acting_on_behalf(Req) ->
    get_authenticated_identity(Req) =/= get_identity(Req).

-spec extract_on_behalf_of_authn_res(mochiweb_request()) ->
          error | undefined |
          {rbac_user_id(), rbac_identity_type(), string() | undefined}.
extract_on_behalf_of_authn_res(Req) ->
    case read_on_behalf_of_header(Req) of
        Header when is_list(Header) ->
            case parse_on_behalf_of_header(Header) of
                {User, Domain} ->
                    try list_to_existing_atom(Domain) of
                        ExistingDomain ->
                            case parse_on_behalf_of_extras(Req) of
                                error -> error;
                                Context when is_list(Context) ->
                                    {User, ExistingDomain, Context};
                                undefined ->
                                    {User, ExistingDomain, undefined}
                            end
                    catch
                        error:badarg ->
                            ?log_debug("Invalid domain in cb-on-behalf-of: ~s",
                                       [ns_config_log:tag_user_name(Header)]),
                            error
                    end;
                _ ->
                    ?log_debug("Invalid format of cb-on-behalf-of: ~s",
                               [ns_config_log:tag_user_name(Header)]),
                    error
            end;
        undefined ->
            case read_on_behalf_of_extras(Req) of
                undefined -> undefined;
                Hdr ->
                    ?log_debug("Unexpected cb-on-behalf-extras: ~s",
                               [ns_config_log:tag_user_name(Hdr)]),
                    undefined
            end
    end.

read_on_behalf_of_header(Req) ->
    mochiweb_request:get_header_value("cb-on-behalf-of", Req).

read_on_behalf_of_extras(Req) ->
    mochiweb_request:get_header_value("cb-on-behalf-extras", Req).

parse_on_behalf_of_header(Header) ->
    case (catch base64:decode_to_string(Header)) of
        UserDomainStr when is_list(UserDomainStr) ->
            case string:chr(UserDomainStr, $:) of
                0 ->
                    error;
                I ->
                    {string:substr(UserDomainStr, 1, I - 1),
                     string:substr(UserDomainStr, I + 1)}
            end;
        _ ->
            error
    end.

parse_on_behalf_of_extras(Req) ->
    case read_on_behalf_of_extras(Req) of
        undefined -> undefined;
        Extras when is_list(Extras) ->
            Status =
                case (catch base64:decode_to_string(Extras)) of
                    ContextStr when is_list(ContextStr) ->
                        case ContextStr of
                            "context:" ++ X -> X;
                            _ -> error
                        end;
                    _ -> error
                end,
            case Status of
                error ->
                    ?log_debug("Invalid context in cb-on-behalf-extras:~s",
                               [ns_config_log:tag_user_name(Extras)]),
                    error;
                S -> S
            end;
        _ -> error
    end.

-spec extract_identity_from_cert(binary()) ->
          tuple() | auth_failure | temporary_failure.
extract_identity_from_cert(CertDer) ->
    case ns_ssl_services_setup:get_user_name_from_client_cert(CertDer) of
        undefined ->
            auth_failure;
        failed ->
            auth_failure;
        UName ->
            case authenticate({client_cert_auth, UName}) of
                {ok, #authn_res{identity = Identity}, _} ->
                    Identity;
                {error, Type} ->
                    Type
            end
    end.

-spec check_permission(#authn_res{}, rbac_permission() | no_check | local) ->
                              auth_failure | forbidden | allowed.
check_permission(_AuthnRes, no_check) ->
    allowed;
check_permission(#authn_res{identity = {"@" ++ _, local_token}}, local) ->
    allowed;
check_permission(_, local) ->
    forbidden;
check_permission(#authn_res{identity = Identity},
                 no_check_disallow_anonymous) ->
    case Identity of
        {"", anonymous} ->
            auth_failure;
        _ ->
            allowed
    end;
check_permission(#authn_res{identity = Identity} = AuthnRes, Permission) ->
    Roles = menelaus_roles:get_compiled_roles(AuthnRes),
    case Roles of
        [] ->
            %% this can happen in case of expired token, or if LDAP
            %% server authenticates the user that has no roles assigned
            auth_failure;
        _ ->
            case menelaus_roles:is_allowed(Permission, Roles) of
                true ->
                    allowed;
                false ->
                    ?log_debug("Access denied.~nIdentity: ~p~nRoles: ~p~n"
                               "Permission: ~p~n",
                               [ns_config_log:tag_user_data(Identity),
                               Roles, Permission]),
                    case Identity of
                        {"", anonymous} ->
                            %% we do allow some api's for anonymous
                            %% under some circumstances, but we want to return 401 in case
                            %% if autorization for requests with no auth fails
                            auth_failure;
                        _ ->
                            forbidden
                    end
            end
    end.
