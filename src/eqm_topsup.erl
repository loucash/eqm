-module(eqm_topsup).

-behaviour(supervisor).

-export([start_dispatch/1, stop_dispatch/1]).
-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_dispatch(atom()) ->
    {ok, eqm_pub:pub()} | {error, already_started}.
start_dispatch(Name) ->
    case supervisor:start_child(?MODULE, [Name, self()]) of
        {ok, _} ->
            receive
                {pub, Pub} ->
                    {ok, Pub}
            end;
        {error, {already_started, _}} ->
            {error, already_started}
    end.

-spec stop_dispatch(atom()) -> ok.
stop_dispatch(Name) ->
    case whereis(Name) of
        Pid when is_pid(Pid) ->
            supervisor:terminate_child(?MODULE, Pid);
        _ -> ok
    end.

init([]) ->
    {ok, {{simple_one_for_one, 1, 60},
          [{eqm_sup, {eqm_sup, start_link, []},
            temporary, 5000, supervisor, [eqm_sup]}]}}.
