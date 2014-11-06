%%%-------------------------------------------------------------------
%% @copyright Lukasz Biedrycki
%% @author Lukasz Biedrycki <lukasz.biedrycki@gmail.com>
%% @doc A Subscriber is a component that accepts a sequenced stream of elements
%% provided by a Publisher and pass them to an owner.
%% At any given time a Subscriber might be subscribed to at most one Publisher.
%% @end
%%%-------------------------------------------------------------------
-module(eqm_sub).
-behaviour(gen_fsm).

%% API
-export([start_link/4]).
-export([cancel/1,
         notify/1,
         active/1,
         info/1,
         stop/1,
         resize/2]).

%% subscriber() accessors
-export([pid/1, ref/1]).

%% API for publisher
-export([subscription/2,
         cancelled/1,
         post/2]).

%% Fsm states
-export([wait/2,
         notify/2,
         passive/2,
         active/2,
         cancel_wait/2]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-record(buf, {max       :: non_neg_integer(),
              size = 0  :: non_neg_integer(),
              data      :: queue()}).
-type buffer()  :: #buf{}.

-record(state, {
          publisher         :: eqm_pub:pub(),
          publisher_mon     :: reference(),
          owner             :: pid(),
          owner_mon         :: reference(),
          subscription      :: eqm_pub:subscription(),
          buf               :: buffer(),
          start_state       :: notify | passive
         }).
-type state()   :: #state{}.

-record(subscriber, {
          pid   :: pid(),
          ref   :: reference()
         }).
-opaque subscriber()   :: #subscriber{}.
-export_type([subscriber/0]).

%%%===================================================================
%%% API
%%%===================================================================
%% @doc Starts new subscriber process which subscribes at start to publisher.
%% The initial state is wait, process is waiting for subscription from publisher.
start_link(Publisher, Owner, Size, StateName) ->
    gen_fsm:start_link(?MODULE, [Publisher, Owner, Size, StateName], []).

%% @doc Cancel subscription, returns all messages from buffer and stops
%% subscriber.
-spec cancel(subscriber()) -> ok.
cancel(Sub) ->
    gen_fsm:send_event(pid(Sub), cancel).

%% @doc Forces the buffer into its notify state, where it will send a single
%% message alerting the Owner of new messages before going back to the passive
%% state.
-spec notify(subscriber()) -> ok.
notify(Sub) ->
    gen_fsm:send_event(pid(Sub), notify).

%% @doc Forces the buffer into an active state where it will
%% send the data it has accumulated.
-spec active(subscriber()) -> ok.
active(Sub) ->
    gen_fsm:send_event(pid(Sub), active).

%% @doc Allows to take a given buffer, and make it larger or smaller.
-spec resize(subscriber(), pos_integer()) -> ok.
resize(Sub, Size) when Size >= 0 ->
    gen_fsm:sync_send_all_state_event(pid(Sub), {resize, Size}).

%% @doc Returns info about buffer, size and number of messages
-spec info(subscriber()) -> {ok, {non_neg_integer(), non_neg_integer()}}.
info(Sub) ->
    gen_fsm:sync_send_all_state_event(pid(Sub), info).

%% @doc Stops subscriber and drops messages from buffer
-spec stop(subscriber()) -> ok.
stop(Sub) ->
    gen_fsm:send_event(pid(Sub), stop).

%%%===================================================================
%%% sub - accessors
%%%===================================================================
-spec ref(subscriber()) -> reference().
ref(#subscriber{ref=Ref}) ->
    Ref.

-spec pid(subscriber()) -> pid().
pid(#subscriber{pid=Pid}) ->
    Pid.

%% @private
-spec new_subscriber(reference(), pid()) -> subscriber().
new_subscriber(Ref, Pid) ->
    #subscriber{ref=Ref, pid=Pid}.

%%%===================================================================
%%% Internal API for publisher
%%%===================================================================
%% @doc Publisher calls this function after successful subscription.
-spec subscription(pid(), eqm_pub:subscription()) -> ok.
subscription(Sub, Subscription) ->
    gen_fsm:send_event(Sub, {subscription, Subscription}).

%% @doc Publisher calls this function to send new message.
-spec post(pid(), any()) -> ok.
post(Sub, Msg) ->
    gen_fsm:send_event(Sub, {post, Msg}).

%% @doc Publisher calls this function to confirm that subscription is
%% cancelled.
-spec cancelled(pid()) -> ok.
cancelled(Sub) ->
    gen_fsm:send_event(Sub, cancelled).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%% @private
init([Publisher, Owner, Size, StateName]) ->
    PubRef = monitor(process, eqm_pub:pid(Publisher)),
    OwnerRef = monitor(process, Owner),
    ok = eqm_pub:subscribe(Publisher, self(), Size),
    {ok, wait, #state{owner=Owner, owner_mon=OwnerRef,
                      publisher=Publisher, publisher_mon=PubRef,
                      buf=buf_new(Size), start_state=StateName}}.

%% @private
wait({subscription, Subscription}, #state{start_state=StateName}=State) ->
    send_subscribed(StateName, State#state{subscription=Subscription});
wait(stop, State) ->
    {stop, normal, State};
wait(_Msg, State) ->
    % unexpected
    {next_state, wait, State}.

%% @private
notify(active, #state{buf=Buf}=State) ->
    case buf_size(Buf) of
        0 -> {next_state, active, State};
        N when N > 0 -> send(State)
    end;
notify(notify, State) ->
    {next_state, notify, State};
notify({post, Msg}, #state{buf=Buf}=State) ->
    send_notification(State#state{buf=buf_insert(Msg, Buf)});
notify(cancel, #state{subscription=Subscription}=State) ->
    ok = eqm_pub:cancel(Subscription),
    {next_state, cancel_wait, State};
notify(stop, #state{subscription=Subscription}=State) ->
    ok = eqm_pub:cancel(Subscription),
    {stop, normal, State};
notify(_Msg, State) ->
    % unexpected
    {next_state, notify, State}.

%% @private
passive(notify, #state{buf=Buf}=State) ->
    case buf_size(Buf) of
        0 -> {next_state, notify, State};
        N when N > 0 -> send_notification(State)
    end;
passive(active, #state{buf=Buf}=State) ->
    case buf_size(Buf) of
        0 -> {next_state, active, State};
        N when N > 0 -> send(State)
    end;
passive({post, Msg}, #state{buf=Buf}=State) ->
    {next_state, passive, State#state{buf=buf_insert(Msg, Buf)}};
passive(cancel, #state{subscription=Subscription}=State) ->
    ok = eqm_pub:cancel(Subscription),
    {next_state, cancel_wait, State};
passive(stop, #state{subscription=Subscription}=State) ->
    ok = eqm_pub:cancel(Subscription),
    {stop, normal, State};
passive(_Msg, State) ->
    % unexpected
    {next_state, passive, State}.

%% @private
active(active, State) ->
    {next_state, active, State};
active(notify, State) ->
    {next_state, notify, State};
active({post, Msg}, #state{buf=Buf}=State) ->
    send(State#state{buf=buf_insert(Msg, Buf)});
active(cancel, #state{subscription=Subscription}=State) ->
    ok = eqm_pub:cancel(Subscription),
    {next_state, cancel_wait, State};
active(stop, #state{subscription=Subscription}=State) ->
    ok = eqm_pub:cancel(Subscription),
    {stop, normal, State};
active(_Msg, State) ->
    % unexpected
    {next_state, active, State}.

%% @private
cancel_wait(cancelled, State) ->
    send_cancelled(State);
cancel_wait({post, Msg}, #state{buf=Buf}=State) ->
    {next_state, cancel_wait, State#state{buf=buf_insert(Msg, Buf)}};
cancel_wait(stop, State) ->
    % unexpected
    {stop, normal, State};
cancel_wait(_Msg, State) ->
    % unexpected
    {next_state, cancel_wait, State}.

%% @private
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%% @private
handle_sync_event({resize, NewSize}, _From, StateName, #state{buf=#buf{max=OldSize}=Buf}=State) ->
    {reply, ok, StateName, request(NewSize-OldSize, State#state{buf=buf_resize(NewSize, Buf)})};
handle_sync_event(info, _From, StateName, #state{buf=#buf{max=Max, size=Size}}=State) ->
    Info = [{max,Max},
            {size,Size}],
    Reply = {ok, Info},
    {reply, Reply, StateName, State};
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%% @private
handle_info({'DOWN', Ref, process, _Pid, Reason}, _StateName,
            #state{publisher_mon=Ref}=State) ->
    send_error(Reason, State);
handle_info({'DOWN', Ref, process, _Pid, Reason}, _StateName,
            #state{owner_mon=Ref}=State) ->
    {stop, Reason, State};
handle_info(_Info, StateName, State) ->
    % unexpected
    {next_state, StateName, State}.

%% @private
terminate(_Reason, _StateName, _State) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%% @private
-spec request(integer(), state()) -> state().
request(N, #state{subscription=Subscription}=State) ->
    ok = eqm_pub:request(Subscription, N),
    State.

%% @private
-spec buf_new(non_neg_integer()) -> buffer().
buf_new(Size) ->
    #buf{max=Size, data=queue:new()}.

%% @private
-spec buf_size(buffer()) -> non_neg_integer().
buf_size(#buf{size=Size}) ->
    Size.

%% @private
-spec buf_resize(non_neg_integer(), buffer()) -> buffer().
buf_resize(Size, Buf) ->
    Buf#buf{max=Size}.

%% @private
-spec buf_insert(any(), buffer()) -> buffer().
buf_insert(Msg, #buf{data=Q, size=Size}=Buf) ->
    Buf#buf{data=queue:in(Msg, Q), size=Size+1}.

%% @private
-spec send(state()) -> {next_state, atom(), state()}.
send(#state{buf=#buf{data=Q, size=Size, max=Max}, owner=Owner}=State) ->
    Msgs = queue:to_list(Q),
    Owner ! {mail, self(), Msgs, Size},
    {next_state, passive, request(Size, State#state{buf=buf_new(Max)})}.

%% @private
-spec send_notification(state()) -> {next_state, atom(), state()}.
send_notification(State) ->
    send_notification(passive, State).

%% @private
-spec send_notification(atom(), state()) -> {next_state, atom(), state()}.
send_notification(NextState, #state{owner=Owner}=State) ->
    Owner ! {mail, self(), new_data},
    {next_state, NextState, State}.

%% @private
-spec send_cancelled(state()) -> {stop, normal, state()}.
send_cancelled(#state{buf=#buf{data=Q, size=Size}, owner=Owner}=State) ->
    Msgs = queue:to_list(Q),
    Owner ! {mail, self(), Msgs, Size, last},
    {stop, normal, State}.

%% @private
-spec send_subscribed(atom(), state()) -> {next_state, atom(), state()}.
send_subscribed(StateName, #state{owner=Owner, owner_mon=Ref}=State) ->
    Owner ! {mail, self(), {subscription, new_subscriber(Ref, self())}},
    {next_state, StateName, State}.

%% @private
-spec send_error(any(), state()) -> {stop, any(), state()}.
send_error(Reason, #state{owner=Owner}=State) ->
    Owner ! {mail, self(), {error, Reason}},
    {stop, Reason, State}.
