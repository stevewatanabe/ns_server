%% @author Couchbase <info@couchbase.com>
%% @copyright 2009-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%
%% Monitor and maintain the vbucket layout of each bucket.
%%
-module(ns_janitor).

-include("cut.hrl").
-include("ns_common.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([cleanup/2,
         cleanup_buckets/2,
         cleanup_apply_config/4,
         check_server_list/2]).

-record(janitor_params,
        {bucket_config :: list(),
         bucket_servers :: [node()],
         vbucket_states :: dict:dict() | undefined}).

-spec cleanup(Bucket::bucket_name(), Options::list()) ->
                     ok |
                     {error, wait_for_memcached_failed, [node()]} |
                     {error, marking_as_warmed_failed, [node()]} |
                     {error, unsafe_nodes, [node()]} |
                     {error, {config_sync_failed,
                              pull | push, Details :: any()}} |
                     {error, {bad_vbuckets, [vbucket_id()]}} |
                     {error, {corrupted_server_list, [node()], [node()]}}.
cleanup(Bucket, Options) ->
    [{Bucket, Res}] = cleanup_buckets([{Bucket, []}], Options),
    Res.

maybe_get_membase_config(not_present) ->
    ok;
maybe_get_membase_config({ok, BucketConfig}) ->
    case ns_bucket:bucket_type(BucketConfig) of
        membase ->
            {ok, BucketConfig};
        _ ->
            ok
    end.

cleanup_buckets(BucketsAndParams, Options) ->
    %% We always want to check for unsafe nodes, as we want to honor the
    %% auto-reprovisioning settings for ephemeral buckets. That is, we do not
    %% want to simply activate any bucket on a restarted node and lose the data
    %% instead of promoting the replicas.
    JanitorOptions = Options ++ auto_reprovision:get_cleanup_options(),
    Buckets = [Bucket || {Bucket, _} <- BucketsAndParams],
    BucketsFetchers =
        [ns_bucket:fetch_snapshot(Bucket, _, [props]) || Bucket <- Buckets],
    SnapShot =
        chronicle_compat:get_snapshot(
          [ns_cluster_membership:fetch_snapshot(_) | BucketsFetchers]),
    {Completed, BucketsAndCfg} =
        misc:partitionmap(
          fun ({Bucket, BucketOpts}) ->
                  CfgRes = ns_bucket:get_bucket(Bucket, SnapShot),
                  case maybe_get_membase_config(CfgRes) of
                      ok ->
                          {left, {Bucket, ok}};
                      {ok, BucketConfig} ->
                          {right, {Bucket, {BucketConfig, BucketOpts}}}
                  end
          end, BucketsAndParams),

    run_buckets_cleanup_activity(
      BucketsAndCfg, SnapShot, JanitorOptions) ++ Completed.

run_buckets_cleanup_activity([], _Snapshot, _Options) ->
    [];
run_buckets_cleanup_activity(BucketsAndCfg, SnapShot, Options) ->
    Buckets = [Bucket || {Bucket, _} <- BucketsAndCfg],
    {ok, Rv} =
        leader_activities:run_activity(
          {ns_janitor, Buckets, cleanup}, majority,
          fun () ->
                  ConfigPhaseRes =
                      [{Bucket,
                        cleanup_with_membase_bucket_check_hibernation(
                          Bucket, Options ++ BktOpts, BktConfig, SnapShot)} ||
                          {Bucket, {BktConfig, BktOpts}} <- BucketsAndCfg],

                  {Completed, Remaining} =
                      misc:partitionmap(
                        fun({Bucket, {ok, BktConfig}}) ->
                                case ns_bucket:get_servers(BktConfig) of
                                    [] ->
                                        {left, {Bucket, {error, no_servers}}};
                                    Servers ->
                                        {right, {Bucket,
                                                 #janitor_params{
                                                    bucket_servers = Servers,
                                                    bucket_config = BktConfig
                                                   }}}
                                end;
                           ({Bucket, Response}) ->
                                {left, {Bucket, Response}}
                        end, ConfigPhaseRes),

                  {ok, cleanup_with_membase_buckets_vbucket_map(
                         Remaining, Options) ++ Completed}
          end,
          [quiet]),

    Rv.

repeat_bucket_config_cleanup(Bucket, Options) ->
    SnapShot =
        chronicle_compat:get_snapshot(
          [ns_bucket:fetch_snapshot(Bucket, _, [props]),
           ns_cluster_membership:fetch_snapshot(_)]),
    CfgRes = ns_bucket:get_bucket(Bucket, SnapShot),
    case maybe_get_membase_config(CfgRes) of
        ok ->
            ok;
        {ok, BucketConfig} ->
            cleanup_with_membase_bucket_check_hibernation(
              Bucket, Options, BucketConfig, SnapShot)
    end.

cleanup_with_membase_bucket_check_servers(Bucket, Options, BucketConfig,
                                          Snapshot) ->
    case check_server_list(Bucket, BucketConfig, Snapshot, Options) of
        ok ->
            cleanup_with_membase_bucket_check_map(Bucket,
                                                  Options, BucketConfig);
        {update_servers, NewServers} ->
            update_servers(Bucket, NewServers, Options),
            repeat_bucket_config_cleanup(Bucket, Options);
        {error, _} = Error ->
            Error
    end.

update_servers(Bucket, Servers, Options) ->
    ?log_debug("janitor decided to update "
               "servers list for bucket ~p to ~p", [Bucket, Servers]),

    ns_bucket:set_servers(Bucket, Servers),
    push_config(Options).

unpause_bucket(Bucket, Nodes, Options) ->
    case proplists:get_value(unpause_checked_hint, Options, false) of
        true ->
            ok;
        false ->
            hibernation_utils:unpause_bucket(Bucket, Nodes)
    end.

handle_hibernation_cleanup(Bucket, Options, BucketConfig, State = pausing) ->
    Servers = ns_bucket:get_servers(BucketConfig),
    case unpause_bucket(Bucket, Servers, Options) of
        ok ->
            ns_bucket:clear_hibernation_state(Bucket),
            ?log_debug("Cleared hibernation state"),
            repeat_bucket_config_cleanup(Bucket, Options);
        _ ->
            {error, hibernation_cleanup_failed, State}
    end;
handle_hibernation_cleanup(Bucket, _Options, _BucketConfig, State = resuming) ->
    %% A bucket in "resuming" hibernation state during janitor cleanup is an
    %% inactive bucket with no server list or map. It does not exist in
    %% memcached so cleanup of it mostly involves a delete from the config.

    case ns_bucket:delete_bucket(Bucket) of
        {ok, _} ->
            ns_janitor_server:delete_bucket_request(Bucket);
        _ ->
            {error, hibernation_cleanup_failed, State}
    end.

cleanup_with_membase_bucket_check_hibernation(Bucket, Options, BucketConfig,
                                              Snapshot) ->
    case ns_bucket:get_hibernation_state(BucketConfig) of
        undefined ->
            cleanup_with_membase_bucket_check_servers(Bucket, Options,
                                                      BucketConfig, Snapshot);
        State ->
            handle_hibernation_cleanup(Bucket, Options, BucketConfig, State)
    end.

cleanup_with_membase_bucket_check_map(Bucket, Options, BucketConfig) ->
    case proplists:get_value(map, BucketConfig, []) of
        [] ->
            Servers = ns_bucket:get_servers(BucketConfig),
            true = (Servers =/= []),

            ?log_info("janitor decided to generate initial vbucket map"),
            {Map, MapOpts} =
                ns_rebalancer:generate_initial_map(Bucket, BucketConfig),
            set_initial_map(Map, Servers, MapOpts, Bucket, BucketConfig,
                            Options),

            repeat_bucket_config_cleanup(Bucket, Options);
        _ ->
            {ok, BucketConfig}
    end.

set_initial_map(Map, Servers, MapOpts, Bucket, BucketConfig, Options) ->
    case ns_rebalancer:unbalanced(Map, BucketConfig) of
        false ->
            ns_bucket:store_last_balanced_vbmap(Bucket, Map, MapOpts);
        true ->
            ok
    end,

    ok = ns_bucket:set_initial_map(Bucket, Map, Servers, MapOpts),

    push_config(Options).

cleanup_with_membase_buckets_vbucket_map([], _Options) ->
    [];
cleanup_with_membase_buckets_vbucket_map(ConfigPhaseRes, Options) ->
    Timeout = proplists:get_value(query_states_timeout, Options),
    Opts = [{timeout, Timeout} || Timeout =/= undefined],
    QueryPhaseFun =
        fun({Bucket, #janitor_params{bucket_servers = Servers} = JParams}) ->
                case janitor_agent:query_vbuckets(Bucket, Servers, [], Opts) of
                    {States, []} ->
                        {Bucket,
                         JParams#janitor_params{vbucket_states = States}};
                    {_States, Zombies} ->
                        ?log_info("Bucket ~p not yet ready on ~p",
                                  [Bucket, Zombies]),
                        {Bucket, {error, wait_for_memcached_failed, Zombies}}
                end
        end,

    QueryRes = misc:parallel_map(QueryPhaseFun, ConfigPhaseRes, infinity),

    {Remaining, CurrErrors} =
        lists:partition(
          fun({_Bucket, #janitor_params{}}) ->
                  true;
             (_) ->
                  false
          end, QueryRes),

    CurrErrors ++ cleanup_buckets_with_states(Remaining, Options).

cleanup_buckets_with_states([], _Options) ->
    [];
cleanup_buckets_with_states(Params, Options) ->
    {ApplyConfigResults, CurrErrors} =
        misc:partitionmap(
          fun({Bucket, #janitor_params{bucket_config = NewBucketConfig,
                                       bucket_servers = Servers}}) ->
                  {left, {Bucket, cleanup_apply_config(Bucket, Servers,
                                                       NewBucketConfig,
                                                       Options)}};
             ({Bucket, Error}) ->
                  {right, {Bucket, Error}}
          end, apply_config_prep(Params, Options)),

    ApplyConfigResults ++ CurrErrors.

check_unsafe_nodes(BucketConfig, States, Options) ->
    %% Find all the unsafe nodes (nodes on which memcached restarted within
    %% the auto-failover timeout) using the vbucket states. If atleast one
    %% unsafe node is found then we won't bring the bucket online until we
    %% we reprovision it. Reprovisioning is initiated by the orchestrator at
    %% the end of every janitor run.
    UnsafeNodes = find_unsafe_nodes_with_vbucket_states(
                    BucketConfig, States,
                    should_check_for_unsafe_nodes(BucketConfig, Options)),

    case UnsafeNodes =/= [] of
        true ->
            {error, unsafe_nodes, UnsafeNodes};
        false ->
            ok
    end.

maybe_fixup_vbucket_map(Bucket, BucketConfig, States, Options) ->
    case do_maybe_fixup_vbucket_map(Bucket, BucketConfig, States) of
        not_needed ->
            %% We decided not to update the bucket config. It still may be
            %% the case that some nodes have extra vbuckets. Before
            %% deleting those, we need to push the config, so all nodes
            %% are on the same page.
            PushRequired =
                requires_config_sync(push, Bucket, BucketConfig,
                                     States, Options),
            {ok, BucketConfig, PushRequired};
        {ok, FixedBucketConfig} ->
            %% We decided to fix the bucket config. In this case we push
            %% the config no matter what, i.e. even if durability
            %% awareness is disabled.
            {ok, FixedBucketConfig, true};
        FixupError ->
            FixupError
    end.

check_prep_param({Bucket, #janitor_params{bucket_config = BucketConfig,
                                          vbucket_states = States}} = Param,
                 Options) ->
    case check_unsafe_nodes(BucketConfig, States, Options) of
        ok ->
            Param;
        Error ->
            {Bucket, Error}
    end.

apply_config_prep(Params, Options) ->
    try
        maybe_pull_config(Params, Options),

        {Results, RequireConfigPush} =
            lists:mapfoldl(
              fun({Bucket,
                   #janitor_params{vbucket_states = States} = JParam}, Acc) ->
                      {ok, CurrBucketConfig} = ns_bucket:get_bucket(Bucket),
                      case maybe_fixup_vbucket_map(Bucket, CurrBucketConfig,
                                                   States, Options) of
                          {ok, NewConfig, RequirePush} ->
                              Param = {Bucket, JParam#janitor_params{
                                                 bucket_config = NewConfig}},
                              {check_prep_param(Param, Options),
                               Acc orelse RequirePush};
                          Error ->
                              {{Bucket, Error}, Acc}
                      end
              end, false, Params),

        maybe_config_sync(RequireConfigPush, push, Options),
        Results
    catch
        throw:Error ->
            [{Bucket, Error} || {Bucket, _} <- Params]
    end.

do_maybe_fixup_vbucket_map(Bucket, BucketConfig, States) ->
    {NewBucketConfig, IgnoredVBuckets} = compute_vbucket_map_fixup(Bucket,
                                                                   BucketConfig,
                                                                   States),
    case IgnoredVBuckets of
        [] ->
            case NewBucketConfig =:= BucketConfig of
                true ->
                    not_needed;
                false ->
                    fixup_vbucket_map(Bucket, BucketConfig,
                                      NewBucketConfig, States),
                    {ok, NewBucketConfig}
            end;
        _ when is_list(IgnoredVBuckets) ->
            {error, {bad_vbuckets, IgnoredVBuckets}}
    end.

fixup_vbucket_map(Bucket, BucketConfig, NewBucketConfig, States) ->
    ?log_info("Janitor is going to change "
              "bucket config for bucket ~p", [Bucket]),
    ?log_info("VBucket states:~n~p", [dict:to_list(States)]),
    ?log_info("Old bucket config:~n~p", [BucketConfig]),

    ok = ns_bucket:set_bucket_config(Bucket, NewBucketConfig).

cleanup_apply_config(Bucket, Servers, BucketConfig, Options) ->
    {ok, Result} =
        leader_activities:run_activity(
          {ns_janitor, Bucket, apply_config}, {all, Servers},
          fun () ->
                  {ok, cleanup_apply_config_body(Bucket, Servers,
                                                 BucketConfig, Options)}
          end,
          [quiet]),

    Result.

config_sync_nodes(Options) ->
    case proplists:get_value(sync_nodes, Options) of
        undefined ->
            ns_cluster_membership:get_nodes_with_status(_ =/= inactiveFailed);
        Nodes when is_list(Nodes) ->
            Nodes
    end.

check_states_match(Bucket, BucketConfig, States) ->
    {_, Map} = lists:keyfind(map, 1, BucketConfig),
    case map_matches_states_exactly(Map, States) of
        true ->
            false;
        {false, Mismatch} ->
            ?log_debug("Found states mismatch in bucket ~p:~n~p",
                       [Bucket, Mismatch]),
            true
    end.

requires_config_sync(Type, Bucket, BucketConfig, States, Options) ->
    Flag = config_sync_type_to_flag(Type),
    case proplists:get_value(Flag, Options, true)
        andalso cluster_compat_mode:preserve_durable_mutations() of
        true ->
            check_states_match(Bucket, BucketConfig, States);
        false ->
            false
    end.

maybe_config_sync(false, _Type, _Options) ->
    ok;
maybe_config_sync(true, Type, Options) ->
    config_sync(Type, Options).

maybe_pull_config(Params, Options) when is_list(Params) ->
    SyncRequired =
        lists:any(
          fun({Bucket, #janitor_params{bucket_config = BucketConfig,
                                       vbucket_states = States}}) ->
                  requires_config_sync(
                    pull, Bucket, BucketConfig, States, Options)
          end, Params),

    maybe_config_sync(SyncRequired, pull, Options).

config_sync_type_to_flag(pull) ->
    pull_config;
config_sync_type_to_flag(push) ->
    push_config.

config_sync(Type, Options) ->
    Nodes = config_sync_nodes(Options),
    Timeout = ?get_timeout({config_sync, Type}, 10000),

    ?log_debug("Going to ~s config to/from nodes:~n~p", [Type, Nodes]),
    try do_config_sync(chronicle_compat:backend(), Type, Nodes, Timeout) of
        ok ->
            ok;
        Error ->
            throw({error, {config_sync_failed, Type, Error}})
    catch
        T:E:Stack ->
            throw({error, {config_sync_failed, Type, {T, E, Stack}}})
    end.

push_config(Options) ->
    config_sync(push, Options).

do_config_sync(chronicle, pull, _Nodes, Timeout) ->
    chronicle_compat:pull(Timeout);
do_config_sync(chronicle, push, _Nodes, _Timeout) ->
    ok; %% don't need to push buckets since we do quorum write
do_config_sync(ns_config, pull, Nodes, Timeout) ->
    ns_config_rep:pull_remotes(Nodes, Timeout);
do_config_sync(ns_config, push, Nodes, Timeout) ->
    %% Explicitly push buckets to other nodes even if didn't modify them. This
    %% is needed because ensure_conig_seen_by_nodes() only makes sure that any
    %% outstanding local mutations are pushed out. But it's possible that we
    %% didn't have any local modifications to buckets, we still want to make
    %% sure that all nodes have received all updates.
    ns_config_rep:push_keys([buckets]),
    ns_config_rep:ensure_config_seen_by_nodes(Nodes, Timeout).

cleanup_apply_config_body(Bucket, Servers, BucketConfig, Options) ->
    ok = janitor_agent:apply_new_bucket_config(
           Bucket, Servers, BucketConfig,
           proplists:get_value(apply_config_timeout, Options,
                               undefined_timeout)),

    maybe_reset_rebalance_status(Options),

    case janitor_agent:mark_bucket_warmed(Bucket, Servers) of
        ok ->
            ok;
        {errors, BadReplies} ->
            ?log_error("Failed to mark bucket `~p` as warmed up."
                       "~nBadReplies:~n~p", [Bucket, BadReplies]),
            {error, marking_as_warmed_failed, [N || {N, _} <- BadReplies]}
    end.

should_check_for_unsafe_nodes(BCfg, Options) ->
    proplists:get_bool(check_for_unsafe_nodes, Options) andalso
        ns_bucket:storage_mode(BCfg) =:= ephemeral.

find_unsafe_nodes_with_vbucket_states(_BucketConfig, _States, false) ->
    [];
find_unsafe_nodes_with_vbucket_states(BucketConfig, States, true) ->
    Map = proplists:get_value(map, BucketConfig, []),
    true = (Map =/= []),
    EnumeratedChains = misc:enumerate(Map, 0),

    lists:foldl(
      fun ({VB, [Master | _ ] = Chain}, UnsafeNodesAcc) ->
              case lists:member(Master, UnsafeNodesAcc) of
                  true ->
                      UnsafeNodesAcc;
                  false ->
                      case data_loss_possible(VB, Chain, States) of
                          {true, Node} ->
                              [Node | UnsafeNodesAcc];
                          false ->
                              UnsafeNodesAcc
                      end
              end
      end, [], EnumeratedChains).

%% Condition that indicates possibility of data loss:
%% A vBucket is "missing" on a node where it is supposed to be active as per the
%% vBucket map, it is not active elsewhere in the cluster, and the vBucket is in
%% replica state on some other node[s]. If such a vBucket is brought online on
%% the node supposed to be its current master, then it will come up empty and
%% when the replication streams are establised the replicas will also lose their
%% data.
data_loss_possible(VBucket, Chain, States) ->
    NodeStates = janitor_agent:fetch_vbucket_states(VBucket, States),
    [Master | Replicas] = Chain,
    case janitor_agent:find_vbucket_state(Master, NodeStates) of
        missing ->
            %% Replicas might be in wrong states due to interrupted rebalance
            %% (since this code is executed with a fixed up vbucket map, but
            %% before the state changes are actually applied to the system),
            %% so we check for any existing vbuckets among expected replicas.
            ExistingReplicas =
                [N || N <- Replicas,
                      N =/= undefined,
                      janitor_agent:find_vbucket_state(N, NodeStates) =/=
                          missing],

            case ExistingReplicas of
                [] ->
                    false;
                _ ->
                    ?log_info("vBucket ~p missing on master ~p while "
                              "replicas ~p are active. Can lead to "
                              "dataloss.",
                              [VBucket, Master, ExistingReplicas]),
                    {true, Master}
            end;
        _ ->
            false
    end.

maybe_reset_rebalance_status(Options) ->
    case proplists:get_bool(consider_resetting_rebalance_status, Options) of
        true ->
            %% We can't run janitor when rebalance is running. This usually
            %% means previous rebalance was stopped/terminated but we haven't
            %% recorded the status as such.
            Running = case rebalance:status() of
                          running ->
                              true;
                          _ ->
                              false
                      end,
            Msg = <<"Rebalance stopped by janitor.">>,
            rebalance:reset_status(
              fun () ->
                      ale:info(?USER_LOGGER,
                               "Resetting rebalance status "
                               "since it's not really running"),
                      {none, Msg}
              end),

            %% We do not wish to call record_rebalance_report inside the
            %% transaction above, as this involves writing to file and hence can
            %% stall the transaction.
            %% Since this is mainly for the UI, we are ok with the report not
            %% being strongly consistent with the status.
            Running andalso
                ns_rebalance_report_manager:record_rebalance_report(
                  ejson:encode({[{completionMessage, Msg}]}),
                  [node()]);
        false ->
            ok
    end.

%% !!! only purely functional code below (with notable exception of logging) !!!
%% lets try to keep as much as possible logic below this line
check_server_list(Bucket, BucketConfig) ->
    check_server_list(Bucket, BucketConfig, ns_config:latest(), []).

check_server_list(Bucket, BucketConfig, Snapshot, Options) ->
    Servers = ns_bucket:get_servers(BucketConfig),
    ActiveKVNodes = ns_cluster_membership:service_active_nodes(Snapshot, kv) --
                        proplists:get_value(failover_nodes, Options, []),
    do_check_server_list(Bucket, BucketConfig, Servers, ActiveKVNodes).

do_check_server_list(_Bucket, BucketConfig, [], ActiveKVNodes) ->
    DesiredServers = case ns_bucket:get_desired_servers(BucketConfig) of
                         undefined ->
                             ActiveKVNodes;
                         Servers ->
                             Servers
                     end,
    {update_servers, DesiredServers};
do_check_server_list(Bucket, _, Servers, ActiveKVNodes) when is_list(Servers) ->
    %% We don't expect for buckets to refer to servers that are not active. We
    %% can't guarantee this though due to weaknesses of ns_config. The best we
    %% can do if we detect a mismatch is to complain and have a human
    %% intervene.
    UnexpectedServers = Servers -- ActiveKVNodes,
    case UnexpectedServers of
        [] ->
            ok;
        _ ->
            ?log_error("Found a corrupt server list in bucket ~p.~n"
                       "Server list: ~p~n"
                       "Active KV nodes: ~p~n"
                       "Unexpected servers: ~p",
                       [Bucket, Servers, ActiveKVNodes, UnexpectedServers]),
            {error, {corrupted_server_list, Servers, ActiveKVNodes}}
    end.

compute_vbucket_map_fixup(Bucket, BucketConfig, States) ->
    Map = proplists:get_value(map, BucketConfig, []),
    true = ([] =/= Map),
    FFMap = proplists:get_value(fastForwardMap, BucketConfig),

    EnumeratedChains = mb_map:enumerate_chains(Map, FFMap),
    MapUpdates = [sanify_chain(Bucket, States, Chain, FutureChain, VBucket)
                  || {VBucket, Chain, FutureChain} <- EnumeratedChains],

    MapLen = length(Map),
    IgnoredVBuckets = [VBucket || {VBucket, ignore} <-
                                      lists:zip(lists:seq(0, MapLen - 1),
                                                MapUpdates)],
    NewMap = [case NewChain of
                  ignore -> OldChain;
                  _ -> NewChain
              end || {NewChain, OldChain} <- lists:zip(MapUpdates, Map)],
    NewBucketConfig = case NewMap =:= Map of
                          true ->
                              BucketConfig;
                          false ->
                              ?log_debug("Janitor decided to update vbucket map"),
                              lists:keyreplace(map, 1, BucketConfig,
                                               {map, NewMap})
                      end,
    {NewBucketConfig, IgnoredVBuckets}.

%% this will decide what vbucket map chain is right for this vbucket
sanify_chain(_Bucket, _States,
             [CurrentMaster | _] = CurrentChain,
             _FutureChain, _VBucket) when CurrentMaster =:= undefined ->
    %% We can get here on a hard-failover case.
    CurrentChain;
sanify_chain(Bucket, States,
             [CurrentMaster | _] = CurrentChain,
             FutureChain, VBucket) ->
    NodeStates = janitor_agent:fetch_vbucket_states(VBucket, States),
    Actives = [N || {N, active, _} <- NodeStates],

    case Actives of
        %% No Actives.
        [] ->
            CurrentMasterState =
                janitor_agent:find_vbucket_state(CurrentMaster, NodeStates),
            ?log_info("Setting vbucket ~p in ~p on ~p from ~p to active.",
                      [VBucket, Bucket, CurrentMaster, CurrentMasterState], [{chars_limit, -1}]),
            %% Let's activate according to vbucket map.
            CurrentChain;

        %% One Active.
        [ActiveNode] ->
            sanify_chain_one_active(Bucket, VBucket, ActiveNode,
                                    NodeStates, CurrentChain, FutureChain);

        %% Multiple Actives.
        _ ->
            ?log_error("Extra active nodes ~p for vbucket ~p in ~p. "
                       "This should never happen!", [Actives, Bucket, VBucket]),
            case lists:member(CurrentMaster, Actives) of
                false ->
                    ignore;
                true ->
                    %% Pick CurrentChain if CurrentMaster is active.
                    CurrentChain
            end
    end.

fill_missing_replicas(Chain, ExpectedLength) when ExpectedLength > length(Chain) ->
    Chain ++ lists:duplicate(ExpectedLength - length(Chain), undefined);
fill_missing_replicas(Chain, _) ->
    Chain.

derive_chain(Bucket, VBucket, ActiveNode, Chain) ->
    DerivedChain = case misc:position(ActiveNode, Chain) of
                       false ->
                           %% It's an extra node
                           ?log_error(
                              "Master for vbucket ~p in ~p is not "
                              "active, but ~p is, so making that the "
                              "master.",
                              [VBucket, Bucket, ActiveNode]),
                           [ActiveNode];
                       Pos ->
                           ?log_error(
                              "Master for vbucket ~p in ~p "
                              "is not active, but ~p is (one of "
                              "replicas). So making that master.",
                              [VBucket, Bucket, ActiveNode]),
                           [ActiveNode | lists:nthtail(Pos, Chain)]
                   end,
    %% Fill missing replicas, so we don't lose durability constraints.
    fill_missing_replicas(DerivedChain, length(Chain)).

sanify_chain_one_active(_Bucket, _VBucket, ActiveNode, _States,
                        [CurrentMaster | _CurrentReplicas] = CurrentChain,
                        _FutureChain)
  when ActiveNode =:= CurrentMaster ->
    CurrentChain;
sanify_chain_one_active(Bucket, VBucket, ActiveNode, States,
                        [CurrentMaster | _CurrentReplicas] = CurrentChain,
                        [FutureMaster | FutureReplicas] = FutureChain)
  when ActiveNode =:= FutureMaster ->
    %% we check expected replicas to be replicas. One other allowed
    %% possibility is if old master is replica in ff chain. In which
    %% case depending on where rebalance was stopped it may be dead (if
    %% stopped right after takeover) or replica (if stopped after
    %% post-move vbucket states are set).
    PickFutureChain = lists:all(
                        fun (undefined) ->
                                true;
                            (N) ->
                                case janitor_agent:find_vbucket_state(N,
                                                                      States) of
                                    replica ->
                                        true;
                                    dead when N =:= CurrentMaster ->
                                        %% old master might be dead or
                                        %% replica. Replica is tested
                                        %% above
                                        true;
                                    _ ->
                                        false
                                end
                        end, FutureReplicas),
    case PickFutureChain of
        true ->
            FutureChain;
        false ->
            derive_chain(Bucket, VBucket, ActiveNode, CurrentChain)
    end;
sanify_chain_one_active(Bucket, VBucket, ActiveNode, _States,
                        CurrentChain, _FutureChain) ->
    %% One active node, but it's not the master and it's not fast-forward map
    %% master, so we'll just update vbucket map. Note behavior below with losing
    %% replicas makes little sense as of now. Especially with star replication.
    %% But we can adjust it later.
    derive_chain(Bucket, VBucket, ActiveNode, CurrentChain).

map_matches_states_exactly(Map, States) ->
    Mismatch =
        lists:filtermap(
          fun ({VBucket, Chain}) ->
                  NodeStates =
                      janitor_agent:fetch_vbucket_states(VBucket, States),

                  case chain_matches_states_exactly(Chain, NodeStates) of
                      true ->
                          false;
                      false ->
                          {true, {VBucket, Chain, NodeStates}}
                  end
          end, misc:enumerate(Map, 0)),

    case Mismatch of
        [] ->
            true;
        _ ->
            {false, Mismatch}
    end.

chain_matches_states_exactly(Chain0, NodeStates) ->
    Chain = [N || N <- Chain0, N =/= undefined],

    case length(Chain) =:= length(NodeStates) of
        true ->
            lists:all(
              fun ({Pos, Node}) ->
                      ExpectedState =
                          case Pos of
                              1 ->
                                  active;
                              _ ->
                                  replica
                          end,

                      ActualState =
                          janitor_agent:find_vbucket_state(Node, NodeStates),

                      ActualState =:= ExpectedState
              end, misc:enumerate(Chain));
        false ->
            %% Some extra nodes have the vbucket.
            false
    end.

-ifdef(TEST).
sanify_chain_t(States, CurrentChain, FutureChain) ->
    sanify_chain("B",
                 dict:from_list(
                   [{0, [{N, S, []} || {N, S} <- States]}]),
                 CurrentChain, FutureChain, 0).

sanify_basic_test() ->
    %% normal case when everything matches vb map
    [a, b] = sanify_chain_t([{a, active}, {b, replica}], [a, b], []),

    %% yes, the code will keep both masters as long as expected master
    %% is there. Possibly something to fix in future
    [a, b] = sanify_chain_t([{a, active}, {b, active}], [a, b], []),

    %% main chain doesn't match but fast-forward chain does
    [b, c] = sanify_chain_t([{a, dead}, {b, active}, {c, replica}],
                            [a, b], [b, c]),

    %% main chain doesn't match but ff chain does. And old master is already
    %% deleted
    [b, c] = sanify_chain_t([{b, active}, {c, replica}], [a, b], [b, c]),

    %% lets make sure we touch all paths just in case
    %% this runs "there are >1 unexpected master" case
    ignore = sanify_chain_t([{a, active}, {b, active}], [c, a, b], []),

    %% this runs "master is one of replicas" case
    [b, undefined] = sanify_chain_t([{b, active}, {c, replica}], [a, b], []),

    %% and this runs "master is some non-chain member node" case
    [c, undefined] = sanify_chain_t([{c, active}], [a, b], []),

    %% lets also test rebalance stopped prior to complete takeover
    [a, b] = sanify_chain_t([{a, dead}, {b, replica}, {c, pending},
                             {d, replica}], [a, b], [c, d]),
    ok.

sanify_doesnt_lose_replicas_on_stopped_rebalance_test() ->
    %% simulates the following: We've completed move that switches
    %% replica and active but rebalance was stopped before we updated
    %% vbmap. We have code in sanify to detect this condition using
    %% fast-forward map and is supposed to recover perfectly from this
    %% condition.
    [a, b] = sanify_chain_t([{a, active}, {b, dead}], [b, a], [a, b]),

    %% rebalance can be stopped after updating vbucket states but
    %% before vbucket map update
    [a, b] = sanify_chain_t([{a, active}, {b, replica}], [b, a], [a, b]),
    %% same stuff but prior to takeover
    [a, b] = sanify_chain_t([{a, dead}, {b, pending}], [a, b], [b, a]),

    %% lets test more usual case too
    [c, d] = sanify_chain_t([{a, dead}, {b, replica}, {c, active},
                             {d, replica}], [a, b], [c, d]),

    %% but without FF map we're (too) conservative (should be fixable
    %% someday)
    [c, undefined] = sanify_chain_t([{a, dead}, {b, replica}, {c, active},
                                     {d, replica}], [a, b], []).

sanify_addition_of_replicas_test() ->
    [a, b] = sanify_chain_t([{a, active}, {b, replica}], [a, b], [a, b, c]),
    [a, b] = sanify_chain_t([{a, active}, {b, replica}, {c, replica}],
                            [a, b], [a, b, c]),

    %% replica addition with possible move.
    [a, b] = sanify_chain_t([{a, dead}, {b, replica}, {c, pending}],
                            [a, b], [c, a, b]),
    [c, d, a] = sanify_chain_t([{a, dead}, {b, replica}, {c, active},
                                {d, replica}], [a, b], [c, d, a]),
    [c, d, a] = sanify_chain_t([{a, replica}, {b, replica}, {c, active},
                                {d, replica}], [a, b], [c, d, a]).

chain_matches_states_exactly_test() ->
    ?assert(chain_matches_states_exactly([a, b],
                                         [{a, active, []},
                                          {b, replica, []}])),

    ?assertNot(chain_matches_states_exactly([a, b],
                                            [{a, active, []},
                                             {b, pending, []}])),

    ?assertNot(chain_matches_states_exactly([a, undefined],
                                            [{a, active, []},
                                             {b, replica, []}])),

    ?assertNot(chain_matches_states_exactly([b, a],
                                            [{a, active, []},
                                             {b, replica, []}])),

    ?assertNot(chain_matches_states_exactly([undefined, undefined],
                                            [{a, active, []},
                                             {b, replica, []}])),

    ?assert(chain_matches_states_exactly([undefined, undefined], [])).

map_matches_states_exactly_test() ->
    Map = [[a, b],
           [a, b],
           [c, undefined],
           [undefined, undefined]],
    GoodStates = dict:from_list(
                   [{0, [{a, active, []}, {b, replica, []}]},
                    {1, [{a, active, []}, {b, replica, []}]},
                    {2, [{c, active, []}]},
                    {3, []}]),

    ?assert(map_matches_states_exactly(Map, GoodStates)),

    BadStates1 = dict:from_list(
                   [{0, [{a, active, []}, {b, replica, []}]},
                    {1, [{a, replica, []}, {b, replica, []}]},
                    {2, [{c, active, []}]},
                    {3, []}]),
    BadStates2 = dict:from_list(
                   [{0, [{a, active, []}, {b, replica, []}, {c, active, []}]},
                    {1, [{a, active, []}, {b, replica, []}]},
                    {2, [{c, active, []}]},
                    {3, []}]),
    BadStates3 = dict:from_list(
                   [{0, [{a, active, []}, {b, replica, []}]},
                    {1, [{a, active, []}, {b, replica, []}]},
                    {2, [{c, active, []}]},
                    {3, [{c, replica}]}]),
    BadStates4 = dict:from_list(
                   [{0, [{a, active, []}, {b, replica, []}]},
                    {1, [{a, active, []}, {b, replica, []}]},
                    {2, []},
                    {3, []}]),
    BadStates5 = dict:from_list(
                   [{0, [{a, active, []}, {b, replica, []}]},
                    {1, [{a, active, []}]},
                    {2, [{c, active, []}]},
                    {3, []}]),


    lists:foreach(
      fun (States) ->
              ?assertMatch({false, _}, map_matches_states_exactly(Map, States))
      end, [BadStates1, BadStates2, BadStates3, BadStates4, BadStates5]).

apply_config_prep_test_() ->
    {foreach,
     fun load_apply_config_prep_common_modules/0,
     fun (_) ->
             meck:unload()
     end,
     [{"Apply Config Prep Test",
       fun apply_config_prep_test_body/0},
      {"Apply Config Prep Errors Test",
       fun  apply_config_prep_test_errors_body/0},
      {"Cleanup Bucket With Map Test",
       fun  cleanup_buckets_with_map_test_body/0}]
    }.

load_apply_config_prep_common_modules() ->
    meck:new([ns_config, chronicle_compat, cluster_compat_mode, ns_bucket,
              leader_activities], [passthrough]),
    meck:expect(ns_config, get_timeout,
                fun (_, Default) ->
                        Default
                end),
    meck:expect(cluster_compat_mode, preserve_durable_mutations,
                fun () ->
                        true
                end),
    meck:expect(chronicle_compat, pull,
                fun (_) ->
                        ok
                end),
    meck:expect(chronicle_compat, backend,
                fun () ->
                        chronicle
                end).

get_apply_config_prep_params() ->
    Map1 = [[a,b], [a,b], [b,a], [b,c]],
    Map2 = [[b,a], [a,b], [b,a], [b,c]],
    BucketConfig1 = [{map, Map1}, {servers, [a,b,c]}],
    BucketConfig2 = [{map, Map2}, {servers, [a,b,c]}],
    States = [{0,[{a,active,[]},{b,replica,[]}]},
              {3,[{b,active,[]},{c,replica,[]}]},
              {2,[{b,active,[]},{a,replica,[]}]},
              {1,[{a,active,[]},{b,replica,[]}]}],

    Param1 = {"B1", #janitor_params{bucket_servers = [a,b,c],
                                    bucket_config = BucketConfig1,
                                    vbucket_states = dict:from_list(States)}},
    Param2 = {"B2", #janitor_params{bucket_servers = [a,b,c],
                                    bucket_config = BucketConfig2,
                                    vbucket_states = dict:from_list(States)}},

    [Param1, Param2].

apply_config_prep_test_body() ->
    [Param1, Param2] = get_apply_config_prep_params(),
    {_, #janitor_params{bucket_config = BucketConfig1}} = Param1,
    {_, JParams2} = Param2,
    Param2Expected = {"B2", JParams2#janitor_params{bucket_config =
                                                        BucketConfig1}},
    {"B2", #janitor_params{bucket_config = BucketConfig2}} = Param2,

    Options = [{sync_nodes, [a,b,c]},
               {pull_config, true},
               {push_config, true}],

    meck:expect(chronicle_compat, backend,
                fun () ->
                        chronicle
                end),
    meck:expect(chronicle_compat, pull,
                fun (_) ->
                        self() ! chronicle_pull_called,
                        ok
                end
               ),
    meck:expect(ns_bucket, get_bucket,
                fun (_) ->
                        {ok, BucketConfig1}
                end),

    %% Param1 has map that matches states, Param2 has map that doesn't map
    %% states. Any call to ns_bucket:get_bucket will provide map for both
    %% params where states match. The expectation are that Param2 gets updated
    %% with the new config in that case.
    ?assertEqual([Param1, Param2Expected], apply_config_prep([Param1, Param2],
                                                             Options)),

    %% Also we verify that chronicle pull got called because param2 had a
    %% states mismatch with config
    receive
        chronicle_pull_called ->
            ok
    after
        1000 ->
            ?assert(false)
    end,

    0 = ?flush(_),

    %% Expectation is no chronicle pull gets called if states always match
    %% config
    meck:expect(chronicle_compat, pull,
                fun (_) ->
                        ?assert(false),
                        ok
                end
               ),
    ?assertEqual([Param1, Param1], apply_config_prep([Param1, Param1],
                                                     Options)),

    %% Test with ns_config backend
    meck:expect(chronicle_compat, backend,
                fun () ->
                        ns_config
                end),
    meck:expect(ns_config_rep, pull_remotes,
                fun (_,_) ->
                        ok
                end),

    %% Expectation is that no ns_config push happens in the next
    %% apply_config_prep call because vbucket states will match the config
    %% provided by ns_bucket:get_bucket()
    meck:expect(ns_config_rep, push_keys,
                fun (_) ->
                        ?assert(false)
                end),
    meck:expect(ns_config_rep, ensure_config_seen_by_nodes,
                fun (_,_) ->
                        ?assert(false)
                end),
    ?assertEqual([Param1, Param2Expected], apply_config_prep([Param1, Param2],
                                                             Options)),

    %% We now create a scenario where call for "B2" always returns a config
    %% that does NOT match the current vbucket States, in which case ns_config
    %% backend must require a config push, and we verify as such
    meck:expect(ns_bucket, get_bucket,
                fun ("B1") ->
                        {ok, BucketConfig1};
                    ("B2") ->
                        {ok, BucketConfig2}
                end),
    meck:expect(ns_config_rep, push_keys,
                fun (_) ->
                        self() ! ns_config_push_called
                end),
    meck:expect(ns_config_rep, ensure_config_seen_by_nodes,
                fun (_,_) ->
                        ok
                end),
    meck:expect(ns_bucket, set_bucket_config,
                fun (_, _) ->
                        ok
                end),

    %% We expect the Param2 resulting bucket config to be updated by
    %% the janitor because we forced it to not match the vbucket states
    ExpectedMap = {map,[[a,undefined],[a, b],[b,a],[b,c]]},
    Param2ExpectedB =
        {"B2", JParams2#janitor_params{bucket_config =
                                           [ExpectedMap,
                                            {servers, [a,b,c]}]}},
    ?assertEqual([Param1, Param2ExpectedB], apply_config_prep([Param1, Param2],
                                                              Options)),

    receive
        ns_config_push_called ->
            ok
    after
        1000 ->
            ?assert(false)
    end,
    0 = ?flush(_),
    ok.

apply_config_prep_test_errors_body() ->
    [Param1, Param2] = get_apply_config_prep_params(),
    {_, #janitor_params{bucket_config = BucketConfig1}} = Param1,

    Options = [{sync_nodes, [a,b,c]},
               {pull_config, true},
               {push_config, true},
               {check_for_unsafe_nodes, true}],

    meck:expect(chronicle_compat, backend,
                fun () ->
                        chronicle
                end),
    meck:expect(chronicle_compat, pull,
                fun (_) ->
                        throw({config_pull_faled})
                end
               ),
    meck:expect(ns_bucket, get_bucket,
                fun (_) ->
                        {ok, BucketConfig1}
                end),

    [{"B1", {error, {config_sync_failed, pull, _}}},
     {"B2", {error, {config_sync_failed, pull, _}}}] =
        apply_config_prep([Param1, Param2], Options),

    meck:expect(chronicle_compat, pull,
                fun (_) ->
                        ok
                end
               ),
    meck:expect(ns_bucket, storage_mode,
                fun (_) ->
                        ephemeral
                end
               ),

    States = [{0,[{a,missing,[]},{b,replica,[]}]},
              {3,[{b,active,[]},{c,replica,[]}]},
              {2,[{b,active,[]},{a,replica,[]}]},
              {1,[{a,active,[]},{b,replica,[]}]}],
    {Bkt, JParam2} = Param2,
    Param2Updt =
        {Bkt,
         JParam2#janitor_params{vbucket_states = dict:from_list(States)}},

    ?assertEqual([Param1, {"B2", {error,unsafe_nodes,[a]}}],
                 apply_config_prep([Param1, Param2Updt], Options)),

    ok.

cleanup_buckets_with_map_test_body() ->
    [Param1, Param2] = get_apply_config_prep_params(),
    {B1, #janitor_params{vbucket_states = States,
                         bucket_config = BucketConfig1} =  JParam1} = Param1,
    {B2, JParam2} = Param2,
    InputParam1 = {B1, JParam1#janitor_params{vbucket_states = undefined}},
    InputParam2 = {B2, JParam2#janitor_params{vbucket_states = undefined}},

    Options = [{sync_nodes, [a,b,c]},
               {pull_config, true},
               {push_config, true}],

    meck:expect(leader_activities, run_activity,
                fun (_, _, _, _) ->
                        {ok, ok}
                end
               ),
    meck:expect(janitor_agent, query_vbuckets,
                fun (_, _, _, _) ->
                        {States, []}
                end
               ),
    meck:expect(ns_bucket, get_bucket,
                fun (_) ->
                        {ok, BucketConfig1}
                end),

    ?assertEqual([{B1, ok}, {B2, ok}],
                 cleanup_with_membase_buckets_vbucket_map(
                   [InputParam1, InputParam2], Options)),
    ?assertEqual([],
                 cleanup_with_membase_buckets_vbucket_map(
                   [], Options)),
    ?assertEqual([{B2, ok}],
                 cleanup_with_membase_buckets_vbucket_map(
                   [InputParam2], Options)),

    %% Test single error in caller, and successes in called
    meck:expect(janitor_agent, query_vbuckets,
                fun ("B2", _, _, _) ->
                        {States, {error, zombie_error_stub}};
                    (_, _, _, _) ->
                        {States, []}
                end
               ),
    Res = cleanup_with_membase_buckets_vbucket_map(
            [InputParam1, InputParam2, {"B3", JParam2}], Options),
    ?assertEqual(
       [{"B2",{error,wait_for_memcached_failed,{error,zombie_error_stub}}},
        {"B1",ok}, {"B3", ok}], Res),

    %% Single error in caller, remaining errors in called
    meck:expect(chronicle_compat, pull,
                fun (_) ->
                        fail
                end),
    Res2 = cleanup_with_membase_buckets_vbucket_map(
             [InputParam1, InputParam2, {"B3", JParam2}], Options),
    ?assertEqual(
       [{"B2",{error,wait_for_memcached_failed,{error,zombie_error_stub}}},
        {"B1",{error,{config_sync_failed,pull,fail}}},
        {"B3",{error,{config_sync_failed,pull,fail}}}], Res2),

    %% All errors in caller, no calls will be made further from caller
    meck:expect(janitor_agent, query_vbuckets,
                fun (_, _, _, _) ->
                        {States, {error, zombie_error_stub}}
                end
               ),
    Res3 = cleanup_with_membase_buckets_vbucket_map(
             [InputParam1, InputParam2, {"B3", JParam2}], Options),
    ?assertEqual(
       [{"B1",{error,wait_for_memcached_failed,{error,zombie_error_stub}}},
        {"B2",{error,wait_for_memcached_failed,{error,zombie_error_stub}}},
        {"B3", {error,wait_for_memcached_failed,{error,zombie_error_stub}}}],
       Res3),

    ok.

data_loss_possible_t(Chain, States) ->
    data_loss_possible(0, Chain,
                       dict:from_list([{0, [{N, S, []} || {N, S} <- States]}])).

data_loss_possible_test() ->
    ?assertEqual({true, a}, data_loss_possible_t([a, b], [{b, replica}])),

    %% No copies left, so no data loss.
    ?assertNot(data_loss_possible_t([a, b], [])),

    %% Normal case, all copies are where we expect them to be.
    ?assertNot(data_loss_possible_t([a, b], [{a, active}, {b, replica}])),

    %% For some reason our vbucket is a bad state, but the data is there, so
    %% data loss is possible.
    ?assertEqual({true, a}, data_loss_possible_t([a, b], [{b, dead}])),

    %% Vbuckets that exists on nodes not in the vbucket chain don't matter.
    ?assertNot(data_loss_possible_t([a, b], [{c, replica}])).

check_server_list_test() ->
    ?assertEqual({update_servers, [a, b, c]},
                 do_check_server_list("bucket", [], [], [a, b, c])),
    ?assertEqual(ok, do_check_server_list("bucket", [], [a, b], [a, b, c])),
    ?assertEqual(ok, do_check_server_list("bucket", [], [a, b], [a, c, b])),
    ?assertMatch({error, _}, do_check_server_list("bucket", [], [a, b, c],
                                                  [a, b])).
-endif.
