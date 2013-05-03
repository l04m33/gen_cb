-module(tester).
-behaviour(gen_cb).

-export([
    init/1,
    handle_call/3,
    handle_info/2,
    terminate/2]).

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

