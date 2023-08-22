%% @author Couchbase <info@couchbase.com>
%% @copyright 2012-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%

-module(ns_online_config_upgrader).

%% This module implements the online upgrade of a cluster.  "Online" here
%% means "when the cluster comes online"; in other words, when it is formed.
%% This happens after the individual nodes have gone through the node upgrade
%% process (ns_config_default, which updates node-specific settings).
%%
%% The online upgrade updates cluster-wide configuration starting with the
%% lowest possible cluster version (min_supported_compat_version), regardless of
%% a node's version. This is done both when we are upgrading a node running
%% down-rev software and when we are forming a cluster composed of nodes running
%% up-rev code.
%%
%% If we are forming a cluster containing one or mode nodes running up-rev code,
%% a node's configuration may contain entries which are up-rev relative to the
%% cluster version being upgraded. Consequently, the functions used to perform
%% the online upgrade must ensure that they are not adding configuration
%% information which is already present in the node's configuration. If this is
%% not done, we can end up with duplicate information in the configuration.

-include("cut.hrl").
-include("ns_common.hrl").

-export([upgrade_config/2]).

upgrade_config(NewVersion, FinalVersion) ->
    true = (NewVersion =< ?LATEST_VERSION_NUM),
    true = (FinalVersion =< ?LATEST_VERSION_NUM),

    case NewVersion > cluster_compat_mode:get_ns_config_compat_version() of
        true ->
            ok = ns_config:upgrade_config_explicitly(
                   do_upgrade_config(_, NewVersion, FinalVersion));
        false ->
            ?log_warning("ns_config is already upgraded to ~p", [NewVersion]),
            already_upgraded
    end.

do_upgrade_config(Config, VersionNeeded, FinalVersion) ->
    case ns_config:search(Config, cluster_compat_version) of
        {value, VersionNeeded} ->
            [];
        false ->
            upgrade_compat_version(?CURRENT_MIN_SUPPORTED_VERSION);
        {value, undefined} ->
            upgrade_compat_version(?CURRENT_MIN_SUPPORTED_VERSION);
        {value, Ver} ->
            {NewVersion, Upgrade} = upgrade(Ver, Config),

            ?log_info("Performing online config upgrade to ~p", [NewVersion]),
            upgrade_compat_version(NewVersion) ++
                maybe_final_upgrade(NewVersion, FinalVersion) ++ Upgrade
    end.

upgrade_compat_version(NewVersion) ->
    [{set, cluster_compat_version, NewVersion}].

maybe_final_upgrade(?LATEST_VERSION_NUM, ?LATEST_VERSION_NUM) ->
    ns_audit_cfg:upgrade_descriptors() ++ menelaus_users:config_upgrade();
maybe_final_upgrade(FinalVersion, FinalVersion) ->
    menelaus_users:config_upgrade();
maybe_final_upgrade(_, _) ->
    [].

%% Note: upgrade functions must ensure that they do not add entries to the
%% configuration which are already present.

%% MB-58303: TODO Remove this after we move maybe_upgrade_to_chronicle to
%% chronicle init.
upgrade(?CURRENT_MIN_SUPPORTED_VERSION, _) ->
    {?VERSION_70, []};

%% MB-58303: Remove this when chronicle upgrade from 7.0 to 7.1 is taken care of
%% at chronicle init for new min supported version. We must honor upgrades from
%% 7.1 to 7.2 so we can't directly upgrade here to 7.2.
upgrade(?VERSION_70, _) ->
    {?VERSION_71, []};

upgrade(?VERSION_71, Config) ->
    {?VERSION_72,
     menelaus_web_auto_failover:config_upgrade_to_72(Config) ++
        menelaus_web_alerts_srv:config_upgrade_to_72(Config)};

upgrade(?VERSION_72, Config) ->
    {?VERSION_TRINITY,
     menelaus_web_auto_failover:config_upgrade_to_trinity(Config) ++
        menelaus_web_alerts_srv:config_upgrade_to_trinity(Config) ++
        index_settings_manager:config_upgrade_to_trinity(Config) ++
        query_settings_manager:config_upgrade_to_trinity(Config) ++
        analytics_settings_manager:config_upgrade_to_trinity(Config) ++
        mb_master:config_upgrade_to_trinity(Config) ++
        ns_ssl_services_setup:config_upgrade_to_trinity(Config)}.
