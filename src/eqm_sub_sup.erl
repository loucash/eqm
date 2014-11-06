-module(eqm_sub_sup).
-behaviour(supervisor).

-export([start_subscriber/4]).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

-spec start_subscriber(eqm_pub:pub(), pid(), pos_integer(), notify | passive) ->
    {ok, eqm_sub:subscriber()}.
start_subscriber(Publisher, Owner, Size, StateName) ->
    {ok, _} = supervisor:start_child(
                  eqm_pub:sub_sup(Publisher), [Publisher, Owner, Size, StateName]),
    receive
        {mail, _, {subscription, Sub}} -> {ok, Sub}
    end.

init([]) ->
    {ok, {{simple_one_for_one, 5, 10},
          [{eqm_sub, {eqm_sub, start_link, []},
            temporary, 5000, worker, [eqm_sub]}]}}.
