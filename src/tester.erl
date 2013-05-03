-module(tester).
-behaviour(gen_cb).

-include("gen_cb.hrl").

-export([
    start/0,
    start_link/0,
    do_sync_call/1,
    send_async_msg/1,
    get_fixed_reply/1]).

-export([
    init/1,
    handle_call/3,
    handle_info/2,
    terminate/2]).

%%% -----------------------------------------------------------------
%%% APIs
%%% -----------------------------------------------------------------
start() ->
    gen_cb:start({local, ?MODULE}, ?MODULE, [dummy_arg], []).

start_link() ->
    gen_cb:start_link({local, ?MODULE}, ?MODULE, [dummy_arg], []).


do_sync_call(Msg) ->
    gen_cb:call(?MODULE, Msg, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1).

send_async_msg(Msg) ->
    gen_cb:call(?MODULE, Msg, none, none).

get_fixed_reply(Msg) ->
    gen_cb:call(?MODULE, Msg, fun gen_cb:receive_cb/1, fun fix_reply/1).


%%% -----------------------------------------------------------------
%%% Callbacks
%%% -----------------------------------------------------------------
init(Args) ->
    erlang:process_flag(trap_exit, true),
    io:format("init, Args = ~w~n", [Args]),
    {ok, Args}.


handle_call({use_replier, Rep}, Replier, State) ->
    io:format("use_replier, Rep = ~w, Replier = ~w, State = ~w~n",
              [Rep, Replier, State]),
    erlang:spawn(fun() -> Replier(Rep) end),
    {noreply, State};

handle_call(Msg, Replier, State) ->
    io:format("handle_call, Msg = ~w, Replier = ~w, State = ~w~n",
              [Msg, Replier, State]),
    {reply, State, State}.


handle_info(Msg, State) ->
    io:format("handle_info, Msg = ~w, State = ~w~n",
              [Msg, State]),
    {noreply, State}.


terminate(Reason, State) ->
    io:format("terminate, Reason = ~w, State = ~w~n",
              [Reason, State]),
    ok.


%%% -----------------------------------------------------------------
%%% Privates
%%% -----------------------------------------------------------------
fix_reply(CBEvent) ->
    Reply = CBEvent#cb_event.cb_arg,
    NCBEvent = CBEvent#cb_event{cb_arg = lists:duplicate(2, Reply)},
    gen_cb:reply_cb(NCBEvent).

