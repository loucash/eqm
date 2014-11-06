-module(eqm_statem_single_sub_SUITE).

-behaviour(proper_fsm).

-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").

-export([test/0, sample/0]).
-export([initial_state/0,
         initial_state_data/0,
         precondition/4,
         postcondition/5,
         next_state_data/5,
         weight/3]).
-export([starting/1,
         notify/1,
         passive/1,
         active/1]).
-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([t_prop_server_works_fine/1]).
-export([start_subscriber/2]).

-record(state, {
          publisher = {var, pub}    :: {var, pub},
          pub_capacity = 0          :: non_neg_integer(),

          subscriber                :: eqm_sub:sub(),
          sub_max = 0               :: non_neg_integer(),
          sub_q                     :: queue()
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
    eqm:start(),
    Config.

end_per_suite(_Config) ->
    eqm:stop(),
    ok.

t_prop_server_works_fine(_Config) ->
    true = proper:quickcheck(prop_server_works_fine(), 500),
    ok.

test() ->
    proper:quickcheck(?MODULE:prop_server_works_fine()).

sample() ->
    proper_gen:pick(commands(?MODULE)).

prop_server_works_fine() ->
    ?FORALL(Cmds, proper_fsm:commands(?MODULE),
        ?TRAPEXIT(
            begin
                {ok, Publisher} = ?APP:start_publisher(?PUB_NAME),
                {History,State,Result} = proper_fsm:run_commands(?MODULE, Cmds,
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
    starting.

initial_state_data() ->
    #state{}.

common_commands() ->
    [{history, {call,?APP,publisher_info,[?PUB_NAME]}}].

starting(_S) ->
    [{notify, {call,?MODULE,start_subscriber, [{var,pub}, demand()]}}]
    ++ common_commands().

notify(#state{subscriber=Sub, publisher=Pub}) ->
    [{history,  {call,?SUB,info,[Sub]}},
     {history,  {call,?SUB,notify,[Sub]}},
     {history,  {call,?SUB,resize,[Sub,demand()]}},
     {starting, {call,?SUB,stop,[Sub]}},
     {starting, {call,?APP,stop_subscriber,[Sub]}},
     {starting, {call,?SUB,cancel,[Sub]}},
     {active,   {call,?SUB,active,[Sub]}},
     {passive,  {call,?SUB,active,[Sub]}},
     {passive,  {call,?PUB,post,[Pub, message()]}}]
    ++ common_commands().

passive(#state{subscriber=Sub, publisher=Pub}) ->
    [{history, {call,?SUB,info,[Sub]}},
     {notify,  {call,?SUB,notify,[Sub]}},
     {history, {call,?SUB,notify,[Sub]}},
     {active,  {call,?SUB,active,[Sub]}},
     {history, {call,?SUB,active,[Sub]}},
     {starting, {call,?SUB,stop,[Sub]}},
     {starting, {call,?APP,stop_subscriber,[Sub]}},
     {starting, {call,?SUB,cancel,[Sub]}},
     {history, {call,?PUB,post,[Pub,message()]}}]
    ++ common_commands().

active(#state{subscriber=Sub, publisher=Pub}) ->
    [{history, {call,?SUB,info,[Sub]}},
     {history, {call,?SUB,active,[Sub]}},
     {starting, {call,?SUB,stop,[Sub]}},
     {starting, {call,?APP,stop_subscriber,[Sub]}},
     {starting, {call,?SUB,cancel,[Sub]}},
     {notify,  {call,?SUB,notify,[Sub]}},
     {passive,  {call,?PUB,post,[Pub, message()]}}]
    ++ common_commands().

precondition(notify, active, #state{sub_q=Q}, {call,_,active,[_]}) ->
    case queue:len(Q) of
        0 -> true;
        _ -> false
    end;
precondition(notify, passive, #state{sub_q=Q}, {call,_,active,[_]}) ->
    case queue:len(Q) of
        0 -> false;
        _ -> true
    end;
precondition(passive, notify, #state{sub_q=Q}, {call,_,notify,[_]}) ->
    case queue:len(Q) of
        0 -> true;
        _ -> false
    end;
precondition(passive, passive, #state{sub_q=Q}, {call,_,notify,[_]}) ->
    case queue:len(Q) of
        0 -> false;
        _ -> true
    end;
precondition(passive, active, #state{sub_q=Q}, {call,_,active,[_]}) ->
    case queue:len(Q) of
        0 -> true;
        _ -> false
    end;
precondition(passive, passive, #state{sub_q=Q}, {call,_,active,[_]}) ->
    case queue:len(Q) of
        0 -> false;
        _ -> true
    end;
precondition(_From, _To, #state{pub_capacity=0}, {call,_,post,[_,_]}) ->
    false;
precondition(_From, _To, _S, _Call) ->
    true.

next_state_data(starting, notify, _S, Sub, {call,_,start_subscriber,[_,N]}) ->
    #state{subscriber = Sub, pub_capacity=N, sub_max=N, sub_q=queue:new()};
next_state_data(_,_,#state{pub_capacity=C, sub_max=OldSize}=S,_Res,{call,_,resize,[_,NewSize]}) ->
    S#state{pub_capacity=C+(NewSize-OldSize), sub_max=NewSize};
next_state_data(notify,passive,#state{pub_capacity=C, sub_q=Q}=S,_Res,{call,_,post,[_,Msg]}) ->
    S#state{pub_capacity=C-1, sub_q=queue:in(Msg, Q)};
next_state_data(notify,passive,#state{pub_capacity=C, sub_q=Q}=S,_Res,{call,_,active,[_]}) ->
    S#state{pub_capacity=C+queue:len(Q), sub_q=queue:new()};
next_state_data(passive,passive,#state{pub_capacity=C, sub_q=Q}=S,_Res,{call,_,post,[_,Msg]}) ->
    S#state{pub_capacity=C-1, sub_q=queue:in(Msg, Q)};
next_state_data(passive,passive,#state{pub_capacity=C, sub_q=Q}=S,_Res,{call,_,active,[_]}) ->
    S#state{pub_capacity=C+queue:len(Q), sub_q=queue:new()};
next_state_data(active,passive,#state{}=S,_Res,{call,_,post,[_,_]}) ->
    S#state{sub_q=queue:new()};
next_state_data(_From, _To, S, _Res, _Call) -> S.


postcondition(_From, _To, #state{publisher=Pub}, {call,_,publisher_info,[_]}, Res) ->
    Res =:= {ok, Pub};
postcondition(_From, _To, #state{sub_q=Q, sub_max=Size}, {call,_,info,[_]}, {ok, Info}) ->
    Info =:= [{max, Size}, {size, queue:len(Q)}];
postcondition(_From, _To,#state{},{call,_,resize,_},_Res) ->
    true;
postcondition(_From, starting, _S, {call,_,stop,[_]}, _Res) ->
    true;
postcondition(_From, starting, _S, {call,_,stop_subscriber,[_]}, _Res) ->
    true;
postcondition(_From, starting, #state{sub_q=Q}, {call,_,cancel,[_]}, _Res) ->
    ok =:= await_last_msgs(queue:to_list(Q));

postcondition(starting, notify, _S, {call,_,start_subscriber,[_,_]}, _Res) ->
    true;
postcondition(notify, notify, _S, {call,_,notify,[_]}, _Res) ->
    true;
postcondition(notify, passive, S, {call,_,post,[_,_]}, _Res) ->
    ok =:= await_notification(S);
postcondition(notify, active, _S, {call,_,active,[_]}, _Res) ->
    true;
postcondition(notify, passive, #state{sub_q=Q}, {call,_,active,[_]}, _Res) ->
    ok =:= await_msgs(queue:to_list(Q));
postcondition(passive, notify, _S, {call,_,notify,[_]}, _Res) ->
    true;
postcondition(passive, passive, S, {call,_,notify,[_]}, _Res) ->
    ok =:= await_notification(S);
postcondition(passive, active, _S, {call,_,active,[_]}, _Res) ->
    true;
postcondition(passive, passive, #state{sub_q=Q}, {call,_,active,[_]}, _Res) ->
    ok =:= await_msgs(queue:to_list(Q));
postcondition(passive, passive, _S, {call,_,post,[_,_]}, _Res) ->
    true;
postcondition(active, notify, _S, {call,_,notify,[_]}, _Res) ->
    true;
postcondition(active, passive, _S, {call,_,post,[_,Msg]}, _Res) ->
    ok =:= await_msgs([Msg]);
postcondition(active, active, _S, {call,_,active,[_]}, _Res) ->
    true.

weight(_From, _To, {call,_,publisher_info,_}) -> 1;
weight(_From, _To, {call,_,stop,_}) -> 1;
weight(_From, _To, _Call) -> 10.

demand() ->
    proper_types:integer(1, 10).

message() ->
    proper_types:binary().

await_notification(#state{subscriber=Sub}) ->
    SubPid = eqm_sub:pid(Sub),
    receive
        {mail, SubPid, new_data} ->
            ok
    after
        500 ->
            timeout
    end.

await_msgs(Msgs) ->
    Size = length(Msgs),
    receive
        {mail, _, Msgs, Size} ->
            ok
    after
        500 ->
            timeout
    end.

await_last_msgs(Msgs) ->
    Size = length(Msgs),
    receive
        {mail, _, Msgs, Size, last} ->
            ok
    after
        500 ->
            timeout
    end.
