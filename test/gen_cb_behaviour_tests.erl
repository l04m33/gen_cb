-module(gen_cb_behaviour_tests).

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_cb).
-export([
    init/1,
    handle_call/3,
    handle_info/2,
    code_change/3,
    terminate/2]).

behaviour_test_() ->
    [
        {"Starting",        fun test_starting/0},
        {"Termination",     fun test_termination/0}
    ].

test_starting() ->
    {ok, PID} = gen_cb:start(?MODULE, [], []),
    ?assert(erlang:is_process_alive(PID) =:= true),
    {links, Links} = erlang:process_info(self(), links),
    ?assert(lists:member(PID, Links) =:= false),
    ok = gen_cb:call(PID, stop, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    wait_for_exit(PID, 500),
    ok.

test_termination() ->
    {ok, PID} = gen_cb:start(?MODULE, [], []),
    ok = gen_cb:call(PID, {stop, self()}, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    receive
        {PID, {stopped, normal}} ->
            ok
    after 500 ->
        exit(termination_timed_out)
    end,
    wait_for_exit(PID, 500),
    ok.


%%% -----------------------------------------------------------------
%%% gen_cb behaviour callbacks
%%% -----------------------------------------------------------------
init([]) ->
    erlang:process_flag(trap_exit, true),
    {ok, []}.

handle_call(check_alive, _Replier, State) ->
    {reply, ok, State};
handle_call({use_replier, Delay}, Replier, _State) ->
    {noreply, {Replier, ok}, Delay};
handle_call(stop, _Replier, State) ->
    {stop, normal, ok, State};
handle_call({stop, Stopper}, _Replier, _State) ->
    {stop, normal, ok, {stopped, Stopper}}.


handle_info(timeout, {Replier, Reply}) when is_function(Replier) ->
    Replier(Reply),
    {noreply, []};
handle_info(_, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    %% TODO
    {ok, State}.

terminate(Reason, {stopped, Stopper}) when is_pid(Stopper) ->
    Stopper ! {self(), {stopped, Reason}},
    ok;
terminate(_Reason, _State) ->
    ok.


wait_for_exit(PID, N) ->
    case erlang:is_process_alive(PID) of
        true ->
            receive
                after 100 -> ok
            end,
            wait_for_exit(PID, N - 1);
        _ ->
            ok
    end.

