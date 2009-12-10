% Copyright (c) 2009, NorthScale, Inc
% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
%
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions
% are met:
%
% * Redistributions of source code must retain the above copyright
% notice, this list of conditions and the following disclaimer.
% * Redistributions in binary form must reproduce the above copyright
% notice, this list of conditions and the following disclaimer in the
% documentation and/or other materials provided with the distribution.
% * Neither the name of Powerset, Inc nor the names of its
% contributors may be used to endorse or promote products derived from
% this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
% COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
%
% Original Author: Cliff Moon

-module(partition).

%% API

-export([partition_range/1, create_partitions/3, map_partitions/2,
         diff/2, within/4, within/5, node_hash/3,
         sizes/2]).

-define(power_2(N), (2 bsl (N-1))).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).
-include("test/partition_test.erl").
-endif.

%% API

partition_range(Q) -> ?power_2(32-Q).

create_partitions(Q, Node, Nodes) ->
  P = lists:map(fun(P) -> {Node, P} end,
                lists:seq(1, ?power_2(32), partition_range(Q))),
  map_partitions(P, Nodes).

map_partitions(Partitions, Nodes) ->
  {_, Parts} = lists:unzip(Partitions),
  % CHashMap is [{hash(node), node}*].
  CHashMap = hash_map(Nodes),
  % ?debugFmt("chashmap ~p", [CHashMap]),
  do_map(CHashMap, Parts).

diff(From, To) when length(From) =/= length(To) ->
  throw("Cannot diff partition maps with different length");

diff(From, To) ->
  diff(From , To, []).

%%====================================================================

diff([], [], Results) ->
  lists:reverse(Results);

diff([{Node,Part}|PartsA], [{Node,Part}|PartsB], Results) ->
  diff(PartsA, PartsB, Results);

diff([{NodeA,Part}|PartsA], [{NodeB,Part}|PartsB], Results) ->
  diff(PartsA, PartsB, [{NodeA,NodeB,Part}|Results]).

hash_map(List) -> hash_map(List, []).

hash_map([], Acc) -> lists:keysort(1, Acc);
hash_map([Item | List], Acc) ->
  hash_map(List, hash_map(500, Item, [{misc:hash(Item), Item} | Acc])).

hash_map(0, _Item, Acc) -> Acc;
hash_map(N, Item, [{Seed, Item} | Acc]) ->
  hash_map(N - 1, Item,
           [{misc:hash(Item, Seed), Item}, {Seed, Item} | Acc]).

do_map([{Hash, Node} | CHashMap], Parts) ->
  do_map({Hash, Node}, [{Hash, Node} | CHashMap], Parts, []).

do_map({_Hash, Node}, [], Parts, Mapped) ->
  lists:keysort(2, lists:map(fun(Part) -> {Node, Part} end,
                             Parts) ++ Mapped);

do_map(_, _, [], Mapped) ->
  lists:keysort(2, Mapped);

do_map(First, CHashMap, [Part | Parts], Mapped) ->
  % ?debugFmt("do_map ~p, CHashMap, [~p|~p], ~p",
  %           [First, Part, Parts, Mapped]),
  case CHashMap of
    [{Hash, Node} | _Rest] when Part =< Hash ->
      do_map(First, CHashMap, Parts, [{Node, Part} | Mapped]);
    [_ | Rest] ->
      do_map(First, Rest, [Part | Parts], Mapped)
  end.

sizes(Nodes, Partitions) ->
  lists:reverse(lists:keysort(2,
    lists:map(fun(Node) ->
      Count = lists:foldl(
        fun ({Matched,_}, Acc) when Matched == Node -> Acc+1;
            (_, Acc) -> Acc
        end, 0, Partitions),
      {Node, Count}
    end, Nodes))).

within(N, NodeA, NodeB, Nodes) ->
  within(N, NodeA, NodeB, Nodes, nil).

within(_, _, _, [], _) -> false;

within(N, NodeA, NodeB, [Head|Nodes], nil) ->
  case Head of
    NodeA -> within(N-1, NodeB, nil, Nodes, NodeA);
    NodeB -> within(N-1, NodeA, nil, Nodes, NodeB);
    _ -> within(N-1, NodeA, NodeB, Nodes, nil)
  end;

within(0, _, _, _, _) -> false;

within(N, Last, nil, [Head|Nodes], First) ->
  case Head of
    Last -> {true, First};
    _ -> within(N-1, Last, nil, Nodes, First)
  end.

node_hash(Name, Nodes, Max) ->
  C = Max / length(Nodes),
  misc:ceiling(C * misc:position(Name, Nodes)).

