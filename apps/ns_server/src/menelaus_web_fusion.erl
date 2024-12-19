%% @author Couchbase <info@couchbase.com>
%% @copyright 2025-Present Couchbase, Inc.
%%
%% Use of this software is governed by the Business Source License included in
%% the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
%% file, in accordance with the Business Source License, use of this software
%% will be governed by the Apache License, Version 2.0, included in the file
%% licenses/APL2.txt.
%%

%% @doc implementation of fusion REST API's

-module(menelaus_web_fusion).

-include_lib("ns_common/include/cut.hrl").

-export([handle_prepare_rebalance/1,
         handle_upload_mounted_volumes/1]).

handle_prepare_rebalance(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_morpheus(),
    NodeValidator =
        fun (String) ->
                try {value, list_to_existing_atom(String)}
                catch error:badarg -> {error, "Unknown node"} end
        end,
    validator:handle(
      fun (Params) ->
              KeepNodes = proplists:get_value(keepNodes, Params),
              Options = [{local_addr, menelaus_util:local_addr(Req)}],
              case ns_orchestrator:prepare_fusion_rebalance(
                     KeepNodes, Options) of
                  {ok, AccelerationPlan} ->
                      menelaus_util:reply_json(Req, AccelerationPlan, 200);
                  {unknown_nodes, Nodes} ->
                      validator:report_errors_for_one(
                        Req,
                        [{keepNodes,
                          io_lib:format("Unknown nodes ~p", [Nodes])}], 400);
                  Other ->
                      menelaus_util:reply_text(
                        Req, io_lib:format("Unknown error ~p", [Other]), 500)
              end
      end, Req, form,
      [validator:required(keepNodes, _),
       validator:token_list(keepNodes, ",", NodeValidator, _),
       validator:unsupported(_)]).

validate_guest_volumes(Name, State) ->
    validator:json_array(Name,
                         [validator:required(name, _),
                          validator:string(name, _),
                          validator:required(guestVolumePaths, _),
                          validator:string_array(
                            guestVolumePaths, fun (_) -> ok end,
                            false, _),
                          validator:unsupported(_)],
                         State).

handle_upload_mounted_volumes(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_morpheus(),
    validator:handle(
      fun (Params) ->
              PlanUUID = proplists:get_value(planUUID, Params),
              validator:handle(
                fun (Props) ->
                        Nodes = [{proplists:get_value(name, P),
                                  proplists:get_value(guestVolumePaths, P)} ||
                                    {P} <- proplists:get_value(nodes, Props)],
                        case ns_orchestrator:fusion_upload_mounted_volumes(
                               PlanUUID, Nodes) of
                            not_found ->
                                menelaus_util:reply_text(Req, "Not Found", 404);
                            id_mismatch ->
                                validator:report_errors_for_one(
                                  Req,
                                  [{planUUID, "Doesn't match stored plan id"}],
                                  400);
                            {need_nodes, N} ->
                                validator:report_errors_for_one(
                                  Req,
                                  [{nodes,
                                    io_lib:format("Absent nodes ~p", [N])}],
                                  400);
                            {extra_nodes, N} ->
                                validator:report_errors_for_one(
                                  Req,
                                  [{nodes,
                                    io_lib:format("Unneeded nodes ~p", [N])}],
                                  400);
                            ok ->
                                menelaus_util:reply_json(Req, [], 200)
                        end
                end, Req, json,
                [validator:required(nodes, _),
                 validate_guest_volumes(nodes, _),
                 validator:unsupported(_)])
      end, Req, qs,
      [validator:string(planUUID, _),
       validator:required(planUUID, _),
       validator:unsupported(_)]).
