%%%-------------------------------------------------------------------
%% @copyright Lukasz Biedrycki
%% @author Lukasz Biedrycki <lukasz.biedrycki@gmail.com>
%% @doc A Publisher is a provider of a potentially unbounded number of
%% sequenced elements, publishing them according to the demand received from
%% its Subscriber(s). A Publisher can serve multiple subscribers subscribed
%% dynamically at various points in time.
%% In the case of multiple subscribers the Publisher should respect
%% the processing rates of all of its subscribers
%% (possibly allowing for a bounded drift between them).
%% @end
%%%-------------------------------------------------------------------
-module(eqm_pub).
-behaviour(gen_server).

-include_lib("stdlib/include/ms_transform.hrl").

%% API
-export([start_link/3]).

-export([capacity/1,
         post/2,
         post/3,
         get_info/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% API for subscribers
-export([subscribe/3,
         cancel/1,
         request/2]).

%% pub - accessors
-export([pid/1,
         sub_sup/1,
         demands/1,
         name/1]).

-record(pub,
        {demands        :: ets:tid(),
         refs           :: ets:tid(),
         sub_sup        :: pid(),
         pid            :: pid(),
         name           :: atom()}).
-opaque pub() :: #pub{}.
-export_type([pub/0]).

-record(subscription,
        {reference  :: reference(),
         publisher  :: pub()}).
-opaque subscription()  :: #subscription{}.
-export_type([subscription/0]).

%%%===================================================================
%%% API
%%%===================================================================
start_link(SupPid, Name, Caller) ->
    gen_server:start_link({local, get_name(Name)},
                          ?MODULE, [SupPid, Name, Caller], []).

%% @doc Get capacity of Publisher.
-spec capacity(pub()) -> {ok, non_neg_integer()}.
capacity(#pub{demands=DTid}) ->
    {ok, get_capacity(DTid)}.

%% @doc Post new message. It is synchronous call as we want to make sure, that
%% there still is capacity.
-spec post(pub(), any()) -> ok | {error, no_capacity}.
post(Pub, Msg) ->
    post(Pub, Msg, sync).

-spec post(pub(), any(), sync | async_dirty) -> ok | {error, no_capacity}.
post(#pub{pid=Pid}, Msg, sync) ->
    gen_server:call(Pid, {post, Msg});

post(#pub{demands=DTid}, Msg, async_dirty) ->
    case get_subscriber(DTid) of
        {error, empty} ->
            {error, no_capacity};
        {ok, Sub} ->
            ok = eqm_sub:post(Sub, Msg),
            ets:update_counter(DTid, {sub, Sub}, -1),
            ok
    end.

%% @doc Given Publisher name, retrieve Publisher handler.
-spec get_info(atom()) -> {ok, pub()}.
get_info(Name) ->
    gen_server:call(get_name(Name), get_info).

%%%===================================================================
%%% pub - accessors
%%%===================================================================
-spec pid(pub()) -> pid().
pid(#pub{pid=Pid}) ->
    Pid.

-spec sub_sup(pub()) -> pid().
sub_sup(#pub{sub_sup=Pid}) ->
    Pid.

-spec demands(pub()) -> ets:tid().
demands(#pub{demands=Tid}) ->
    Tid.

-spec name(pub()) -> atom().
name(#pub{name=Name}) ->
    Name.

%%%===================================================================
%%% API for subscribers
%%%===================================================================
-spec subscribe(pub(), pid(), pos_integer()) -> ok.
subscribe(#pub{pid=Pid}, Sub, N) ->
    gen_server:cast(Pid, {subscribe, Sub, N}).

%% @doc Cancel subscription.
-spec cancel(subscription()) -> ok.
cancel(#subscription{reference=Ref,
                     publisher=#pub{pid=Pid}}) ->
    gen_server:cast(Pid, {cancel, Ref}).

%% @doc Request demand for N messages.
-spec request(subscription(), non_neg_integer()) ->
    ok | {error, not_subscribed}.
request(#subscription{reference=Ref,
                      publisher=#pub{demands=DTid, refs=RTid}}, N) ->
    case ets:lookup(RTid, {ref, Ref}) of
        [] ->
            {error, not_subscribed};
        [{_, SubPid}] ->
            ets:update_counter(DTid, {sub, SubPid}, N),
            ok
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%% @private
init([SupPid, Name, Caller]) ->
    self() ! continue_init,
    {ok, {SupPid, Name, Caller}}.

%% @private
handle_call(get_info, _From, #pub{}=Pub) ->
    {reply, {ok, Pub}, Pub};
handle_call({post, Msg}, _From, Pub) ->
    {reply, post(Pub, Msg, async_dirty), Pub}.

%% @private
handle_cast({subscribe, Sub, N}, Pub) ->
    {ok, Ref} = handle_add_subscriber(Sub, Pub),
    Subscription = new_subscription(Ref, Pub),
    ok = request(Subscription, N),
    ok = eqm_sub:subscription(Sub, Subscription),
    {noreply, Pub};
handle_cast({cancel, Ref}, Pub) ->
    {ok, RemovedSubPid} = handle_remove_subscriber(Ref, Pub),
    ok = eqm_sub:cancelled(RemovedSubPid),
    {noreply, Pub};
handle_cast(_Msg, Pub) ->
    % unexpected
    {noreply, Pub}.

%% @private
handle_info({'DOWN', Ref, process, _Pid, _Reason}, Pub) ->
    handle_remove_subscriber(Ref, Pub),
    {noreply, Pub};
handle_info(continue_init, {SupPid, Name, Caller}) ->
    DTid = ets:new(demands_table, [set, public, {write_concurrency, true}]),
    RTid = ets:new(refs_table, [set, public, {read_concurrency, true}]),
    {ok, SubSup} = eqm_sup:start_sub_sup(SupPid),
    Pub = new_publisher(DTid, RTid, SubSup, Name),
    Caller ! {pub, Pub},
    {noreply, Pub}.

%% @private
terminate(_Reason, _Pub) ->
    ok.

%% @private
code_change(_OldVsn, Pub, _Extra) ->
    {ok, Pub}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec handle_add_subscriber(pid(), pub()) -> {ok, reference()}.
handle_add_subscriber(SubPid, #pub{demands=DTid, refs=RTid}) ->
    case ets:match(RTid, {{ref, '$1'}, SubPid}) of
        [] ->
            Ref = monitor(process, SubPid),
            ets:insert(RTid, {{ref, Ref}, SubPid}),
            ets:insert(DTid, {{sub, SubPid}, 0}),
            {ok, Ref};
        [[Ref]] ->
            {ok, Ref}
    end.

-spec handle_remove_subscriber(reference(), pub()) ->
    {ok, pid()} | {error, not_subscribed}.
handle_remove_subscriber(Ref, #pub{demands=DTid, refs=RTid}) ->
    case ets:lookup(RTid, {ref, Ref}) of
        [] ->
            {error, not_subscribed};
        [{_, SubPid}] ->
            true    = demonitor(Ref),
            ets:delete(RTid, {ref, Ref}),
            ets:delete(DTid, {sub, SubPid}),
            {ok, SubPid}
    end.

-spec get_subscriber(ets:tid()) -> {ok, pid()} | {error, empty}.
get_subscriber(Tid) ->
    Query = ets:fun2ms(fun({{sub, Sub}, N}) when N > 0 -> Sub end),
    case ets:select(Tid, Query, 1) of
        '$end_of_table' -> {error, empty};
        {[Sub], _} -> {ok, Sub}
    end.

-spec get_name(atom()) -> atom().
get_name(Name) ->
    list_to_atom(atom_to_list(Name) ++ "_pub").

-spec get_capacity(ets:tid()) -> non_neg_integer().
get_capacity(Tid) ->
    ets:foldl(fun({{sub, _}, N}, Acc) -> N+Acc end, 0, Tid).

-spec new_publisher(ets:tid(), ets:tid(), pid(), atom()) -> pub().
new_publisher(DTid, RTid, SubSup, Name) ->
    #pub{pid=self(), demands=DTid, refs=RTid, sub_sup=SubSup, name=Name}.

-spec new_subscription(reference(), pub()) -> subscription().
new_subscription(Ref, Publisher) ->
    #subscription{reference=Ref,
                  publisher=Publisher}.
