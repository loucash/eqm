-module(stress).
-export([run/0]).
-compile(inline).

-define(EQM, eqm_publisher).
-define(COUNT, 3*1000*1000).
-define(MSG, msg).
-define(TIMEOUT, 60*1000).
-define(PUBLISHERS, 2).
-define(SUBSCRIBERS, 2).
-define(SUBSCRIBER_BUFFER_SIZE, 100000).

setup() ->
    application:ensure_all_started(eqm),
    ok.

run() ->
    setup(),
    run_without_subscribers(sync),
    run_with_subscribers(sync),
    run_without_subscribers(async_dirty),
    run_with_subscribers(async_dirty),
    ok.

run_without_subscribers(Context) ->
    {ok, Pub} = eqm:start_publisher(?EQM),
    {Ts, ok} = timer:tc(fun() -> run(Pub, Context, ?PUBLISHERS) end),
    io:format("~p, without subscribers, test took: ~pms~n", [Context, Ts]),
    eqm:stop_publisher(?EQM),
    ok.

run_with_subscribers(Context) ->
    {ok, Pub} = eqm:start_publisher(?EQM),
    _ = [spawn_link(fun() -> subscriber(Pub) end) || _ <- lists:seq(1, ?SUBSCRIBERS)],
    timer:sleep(300),   % let subscribers subscribe
    {Ts, ok} = timer:tc(fun() -> run(Pub, Context, ?PUBLISHERS) end),
    io:format("~p, with subscribers, test took: ~pms~n", [Context, Ts]),
    eqm:stop_publisher(?EQM),
    ok.

subscriber(Pub) ->
    {ok, Sub} = eqm:start_subscriber(Pub, ?SUBSCRIBER_BUFFER_SIZE),
    loop_subscriber(Sub).

loop_subscriber(Sub) ->
    eqm_sub:active(Sub),
    receive
        {mail, _, _Msgs, _Count} ->
            loop_subscriber(Sub)
    end.

run(Pub, Context, PubCount) ->
    Mgr = self(),
    Pids = [spawn_link(fun() -> loop(Mgr, Pub, Context, ?COUNT) end) || _ <- lists:seq(1, PubCount)],
    collect(Pids).

loop(Mgr, _Pub, _Context, 0) ->
    Mgr ! {ok, self()};
loop(Mgr, Pub, Context, N) ->
    eqm_pub:post(Pub, ?MSG, Context),
    loop(Mgr, Pub, Context, N-1).

collect([]) -> ok;
collect([Pid|Pids]) ->
    receive
        {ok, Pid} ->
            collect(Pids)
    after ?TIMEOUT ->
        {error, timeout}
    end.
