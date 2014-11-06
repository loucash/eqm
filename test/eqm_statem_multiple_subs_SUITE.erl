-module(eqm_statem_multiple_subs_SUITE).

-behaviour(proper_statem).

-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").

-export([test/0, sample/0]).
-export([initial_state/0, command/1, precondition/2, postcondition/3,
         next_state/3]).
-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([t_prop_server_works_fine/1]).
-export([start_subscriber/2]).

-record(state, {
          publisher   = {var, pub}    :: {var, pub},
          capacity    = 0             :: non_neg_integer(),
          subscribers = []            :: list(),
          buffers     = dict:new()    :: dict()
         }).

-define(APP, eqm).
-define(PUB, eqm_pub).
-define(SUB, eqm_sub).
-define(PUB_NAME, test_pub).

%%--------------------------------------------------------------------
%%% Statem callbacks
%%--------------------------------------------------------------------
all() ->
    [t_prop_server_works_fine].

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config) ->
    application:start(eqm),
    Config.

end_per_suite(_Config) ->
    ok.

t_prop_server_works_fine(_Config) ->
    true = proper:quickcheck(prop_server_works_fine()),
    ok.

test() ->
    proper:quickcheck(?MODULE:prop_server_works_fine()).

sample() ->
    proper_gen:pick(commands(?MODULE)).

prop_server_works_fine() ->
    ?FORALL(Cmds, commands(?MODULE),
            ?TRAPEXIT(
               begin
                   {ok, Publisher} = ?APP:start_publisher(?PUB_NAME),
                   {History,State,Result} = run_commands(?MODULE, Cmds,
                                                         [{pub, Publisher}]),
                   ?APP:stop_publisher(?PUB_NAME),
                   ?WHENFAIL(io:format("History: ~w\nState: ~w\nResult: ~w\n",
                                       [History,State,Result]),
                             aggregate(command_names(Cmds), Result =:= ok))
               end)).

start_subscriber(Publisher, BufferSize) ->
    {ok, Sub} = ?APP:start_subscriber(Publisher, BufferSize),
    Sub.

initial_state() ->
    #state{}.

command(#state{subscribers=Subs}) ->
    oneof([{call,?PUB,capacity,[{var,pub}]},
           {call,?PUB,post,[{var,pub},message()]},
           {call,?APP,publisher_info,[?PUB_NAME]},
           {call,?MODULE,start_subscriber, [{var,pub}, buffer_size()]}] ++
          [{call,?SUB,resize,[oneof(Subs),buffer_size()]} || Subs =/= []]).

precondition(_S, _Call) -> true.

next_state(#state{subscribers=Subs, buffers=Bufs, capacity=C}=S, Sub, {call,_,start_subscriber,[_,N]}) ->
    S#state{subscribers=[Sub|Subs], buffers=dict:store(Sub,N,Bufs), capacity=C+N};
next_state(#state{capacity=C, buffers=Bufs}=S, _R, {call,_,resize,[Sub,NewN]}) ->
    {ok, OldN} = dict:find(Sub,Bufs),
    S#state{capacity=C+NewN-OldN, buffers=dict:store(Sub,NewN,Bufs)};
next_state(#state{capacity=0}=S, _R, {call,_,post,[_,_]}) ->
    S;
next_state(#state{capacity=C}=S, _R, {call,_,post,[_,_]}) ->
    S#state{capacity=C-1};
next_state(S, _Res, _Call) -> S.

postcondition(_S, {call,_,start_subscriber,[_,_]}, _Res) ->
    true;
postcondition(_S, {call,_,resize,[_,_]}, _Res) ->
    true;
postcondition(#state{capacity=C1}, {call,_,capacity,[_]}, {ok, C2}) ->
    C1 =:= C2;
postcondition(#state{publisher=Pub}, {call,_,publisher_info,[_]}, Res) ->
    Res =:= {ok, Pub};
postcondition(#state{capacity=0}, {call,_,post,[_,_]}, Res) ->
    {error, no_capacity} =:= Res;
postcondition(#state{}, {call,_,post,[_,_]}, Res) ->
    ok =:= Res.

message() ->
    proper_types:binary().

buffer_size() ->
    integer(1, 20).
