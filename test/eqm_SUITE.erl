-module(eqm_SUITE).

-export([all/0]).
-export([init_per_suite/1,
         end_per_suite/1]).
-export([starting_empty_publisher/1,
         stopping_empty_publisher/1,
         stopping_unexisting_publisher/1,
         starting_subscriber/1,
         receiving_message/1,
         overload/1,
         publisher_killed/1,
         subscriber_killed/1,
         owner_killed/1]).

all() ->
    [starting_empty_publisher,
     stopping_empty_publisher,
     stopping_unexisting_publisher,
     starting_subscriber,
     receiving_message,
     overload,
     publisher_killed,
     subscriber_killed,
     owner_killed
    ].

init_per_suite(Config) ->
    eqm:start(),
    Config.

end_per_suite(_Config) ->
    eqm:stop(),
    ok.

starting_empty_publisher(_Config) ->
    {ok, Publisher} = eqm:start_publisher(starting_empty_publisher),
    {ok, Publisher} = eqm:publisher_info(starting_empty_publisher),
    {ok, 0} = eqm_pub:capacity(Publisher),
    {error, no_capacity} = eqm_pub:post(Publisher, msg),
    ok = eqm:stop_publisher(starting_empty_publisher).

stopping_empty_publisher(_Config) ->
    {ok, _} = eqm:start_publisher(stopping_empty_publisher),
    {error, already_started} = eqm:start_publisher(stopping_empty_publisher),

    ok = eqm:stop_publisher(stopping_empty_publisher),

    {ok, _} = eqm:start_publisher(stopping_empty_publisher),
    ok = eqm:stop_publisher(stopping_empty_publisher),
    ok.

stopping_unexisting_publisher(_Config) ->
    ok = eqm:stop_publisher(stopping_unexisting_publisher).

starting_subscriber(_Config) ->
    {ok, Publisher} = eqm:start_publisher(starting_subscriber),
    {ok, 0}         = eqm_pub:capacity(Publisher),

    {ok, _Subscriber} = eqm:start_subscriber(Publisher, 10),
    {ok, 10} = eqm_pub:capacity(Publisher),

    ok = eqm:stop_publisher(starting_subscriber).

receiving_message(_Config) ->
    {ok, Publisher} = eqm:start_publisher(receiving_message),
    {ok, Subscriber} = eqm:start_subscriber(Publisher, 1),

    ok = eqm_sub:active(Subscriber),
    ok = eqm_pub:post(Publisher, msg),
    ok = receive {mail, _, [msg], 1} -> ok after 200 -> timeout end,

    ok = eqm:stop_publisher(receiving_message).

overload(_Config) ->
    {ok, Publisher} = eqm:start_publisher(overload_test),
    {ok, _Subscriber} = eqm:start_subscriber(Publisher, 1),
    ok = eqm_pub:post(Publisher, msg),
    {error, no_capacity} = eqm_pub:post(Publisher, msg),

    ok = eqm:stop_publisher(overload_test).

publisher_killed(_Config) ->
    {ok, Publisher} = eqm:start_publisher(publisher_killed),
    {ok, _Subscriber} = eqm:start_subscriber(Publisher, 1),
    exit(eqm_pub:pid(Publisher), no_mercy),
    ok = receive {mail, _, {error, no_mercy}} -> ok after 500 -> timeout end,
    ok.

subscriber_killed(_Config) ->
    {ok, Publisher} = eqm:start_publisher(subscriber_killed),
    {ok, Subscriber} = eqm:start_subscriber(Publisher, 1),
    timer:sleep(200),
    {ok, 1} = eqm_pub:capacity(Publisher),
    exit(eqm_sub:pid(Subscriber), no_mercy),
    timer:sleep(200),
    {ok, 0} = eqm_pub:capacity(Publisher),
    ok.

owner_killed(_Config) ->
    {ok, Publisher} = eqm:start_publisher(owner_killed),
    {ok, Subscriber} = eqm:start_subscriber(Publisher, 1),
    timer:sleep(200),
    {ok, 1} = eqm_pub:capacity(Publisher),

    eqm_sub:pid(Subscriber) ! {'DOWN',
                               eqm_sub:ref(Subscriber),
                               process,
                               eqm_sub:pid(Subscriber),
                               no_mercy},
    timer:sleep(200),
    {ok, 0} = eqm_pub:capacity(Publisher),
    ok.
