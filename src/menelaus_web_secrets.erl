%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%

%% @doc rest api's for secrets

-module(menelaus_web_secrets).

-include("ns_common.hrl").

-export([handle_change_master_password/1]).

handle_change_master_password(Req) ->
    menelaus_util:execute_if_validated(
      fun (Values) ->
              NewPassword = proplists:get_value(newPassword, Values),
              case encryption_service:change_password(NewPassword) of
                  ok ->
                      menelaus_util:reply(Req, 200);
                  {error, Error} ->
                      menelaus_util:reply_global_error(Req, Error)
              end
      end, Req, validate_change_master_password(Req:parse_post())).

validate_change_master_password(Args) ->
    R0 = menelaus_util:validate_has_params({Args, [], []}),
    R1 = menelaus_util:validate_required(newPassword, R0),
    R2 = menelaus_util:validate_any_value(newPassword, R1),
    menelaus_util:validate_unsupported_params(R2).
