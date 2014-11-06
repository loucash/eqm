-module(eqm_sup).
-behaviour(supervisor).

-export([start_sub_sup/1]).
-export([start_link/2]).
-export([init/1]).

-spec start_link(atom(), pid()) -> {ok, pid()}.
start_link(Name, Caller) ->
    supervisor:start_link({local, Name}, ?MODULE, [Name, Caller]).

-spec start_sub_sup(pid()) -> {ok, pid()}.
start_sub_sup(Sup) ->
    supervisor:start_child(
      Sup,
      {eqm_sub_sup, {eqm_sub_sup, start_link, []},
       permanent, 5000, supervisor, [eqm_sub_sup]}).

init([Name, Caller]) ->
    {ok, {{one_for_all, 1, 60},
          [{eqm_pub, {eqm_pub, start_link, [self(), Name, Caller]},
           permanent, infinity, worker, [eqm_pub]}]}}.
