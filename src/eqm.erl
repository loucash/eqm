-module(eqm).
-behaviour(application).

-export([start/0,stop/0]).
-export([start/2,stop/1]).

-export([start_publisher/1,
         stop_publisher/1,
         publisher_info/1]).

-export([start_subscriber/2,
         start_subscriber/3,
         stop_subscriber/1]).

-type pub()         :: eqm_pub:pub().
-type subscriber()  :: eqm_sub:subscriber().
-export_type([pub/0, subscriber/0]).

%%%===================================================================
%%% Application API
%%%===================================================================
%% @doc Starts an application
-spec start() -> ok | {error, any()}.
start() ->
    application:start(?MODULE).

%% @doc Stops an application
-spec stop() -> ok | {error, any()}.
stop() ->
    application:stop(?MODULE).

%% @doc Starts publisher in its own supervision tree.
-spec start_publisher(atom()) -> {ok, pub()} | {error, already_started}.
start_publisher(Name) when is_atom(Name) ->
    eqm_topsup:start_dispatch(Name).

%% @doc Stops publisher
-spec stop_publisher(atom()) -> ok.
stop_publisher(Name) when is_atom(Name) ->
    eqm_topsup:stop_dispatch(Name).

%% @doc Retrieve publisher info. Synchronous call, expensive, do not overuse.
-spec publisher_info(atom()) -> {ok, pub()}.
publisher_info(Name) when is_atom(Name) ->
    eqm_pub:get_info(Name).

%% @doc Starts subscriber which subscribes to publisher.
-spec start_subscriber(pub(), pos_integer()) -> {ok, subscriber()}.
start_subscriber(Publisher, Size) ->
    start_subscriber(Publisher, Size, notify).

%% @doc Starts subscriber which subscribes to publisher.
-spec start_subscriber(pub(), pos_integer(), notify | passive) -> {ok, subscriber()}.
start_subscriber(Publisher, Size, StateName) ->
    eqm_sub_sup:start_subscriber(Publisher, self(), Size, StateName).

%% @doc Stops subscriber
-spec stop_subscriber(subscriber()) -> ok.
stop_subscriber(Sub) ->
    eqm_sub:stop(Sub).

start(_StartType, _StartArgs) ->
    eqm_topsup:start_link().

stop(_State) ->
    ok.
