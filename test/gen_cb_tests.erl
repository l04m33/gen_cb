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
        {"Termination",     fun test_termination/0},
        {"Async Call",      fun test_async_call/0},
        {"Sync Call",       fun test_sync_call/0}
    ].

test_starting() ->
    %% gen_cb:start(...)
    {ok, PID} = gen_cb:start(?MODULE, [], []),
    ?assert(erlang:is_process_alive(PID) =:= true),
    {links, Links} = erlang:process_info(self(), links),
    ?assert(lists:member(PID, Links) =:= false),
    ok = gen_cb:call(PID, stop, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    wait_for_exit(PID, 500),

    %% gen_cb:start_link(...)
    OldTEFlag = erlang:process_flag(trap_exit, true),
    {ok, PID2} = gen_cb:start_link(?MODULE, [], []),
    ?assert(erlang:is_process_alive(PID2) =:= true),
    {links, Links2} = erlang:process_info(self(), links),
    ?assert(lists:member(PID2, Links2) =:= true),
    ok = gen_cb:call(PID2, stop, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    receive
        {'EXIT', PID2, normal} ->
            void
        after 500 ->
            exit(termination_timed_out)
    end,
    erlang:process_flag(trap_exit, OldTEFlag),
    ok.

test_termination() ->
    %% Normal termination
    {ok, PID} = gen_cb:start(?MODULE, [], []),
    ok = gen_cb:call(PID, {stop, self()}, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    receive
        {PID, {stopped, normal}} ->
            ok
        after 500 ->
            exit(termination_timed_out)
    end,
    wait_for_exit(PID, 500),

    %% Exceptional termination
    {ok, PID2} = gen_cb:start(?MODULE, [], []),
    ErrorLoggers = remove_error_loggers(),
    ok = gen_cb:call(PID2, {crash_stop, self()}, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    receive
        {PID2, {crash_stopped, {{exit, crash_stopped}, _Stacktrace}}} ->
            ok
        after 500 ->
            exit(termination_timed_out)
    end,
    restore_error_logger(ErrorLoggers),
    wait_for_exit(PID2, 500),
    ok.

test_async_call() ->
    {ok, PID} = gen_cb:start(?MODULE, [], []),

    %% Normal async call
    ok = gen_cb:call(PID, {echo, self(), dummy_msg}, none, none),
    receive
        {echo, PID, dummy_msg} ->
            void
        after 500 ->
            exit(async_call_timed_out)
    end,

    ok = gen_cb:call(PID, stop, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    wait_for_exit(PID, 500),

    %% Calling a dead process, nothing should happen
    ok = gen_cb:call(PID, {echo, self(), dummy_msg}, none, none),
    ok.

test_sync_call() ->
    {ok, PID} = gen_cb:start(?MODULE, [], []),

    %% Normal sync call
    dummy_msg = gen_cb:call(PID, {echo, self(), dummy_msg}, 
                            fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    receive
        {echo, PID, dummy_msg} ->
            void
        after 500 ->
            exit(sync_call_timed_out)
    end,

    %% Replying using Replier
    from_replier = gen_cb:call(PID, {use_replier, 500}, 
                               fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),

    %% Timed out request
    ?assertError(timeout, gen_cb:call(PID, no_reply, 
                                      fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1, 500)),

    ok = gen_cb:call(PID, stop, fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1),
    wait_for_exit(PID, 500),

    %% Calling a dead process
    ?assertError(timeout, gen_cb:call(PID, check_alive, 
                                      fun gen_cb:receive_cb/1, fun gen_cb:reply_cb/1, 500)),
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
    {noreply, {Replier, from_replier}, Delay};
handle_call({echo, From, Msg}, _Replier, State) ->
    From ! {echo, self(), Msg},
    {reply, Msg, State};
handle_call(no_reply, _Replier, State) ->
    {noreply, State};
handle_call(stop, _Replier, State) ->
    {stop, normal, ok, State};
handle_call({stop, Stopper}, _Replier, _State) ->
    {stop, normal, ok, {stopped, Stopper}};
handle_call({crash_stop, Stopper}, _Replier, _State) ->
    {reply, ok, {crash_stopped, Stopper}, 0}.


handle_info(timeout, {crash_stopped, Stopper}) when is_pid(Stopper) ->
    exit(crash_stopped),
    {noreply, []};
handle_info(timeout, {Replier, Reply}) when is_function(Replier) ->
    Replier(Reply),
    {noreply, []};
handle_info(_, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    %% TODO
    {ok, State}.

terminate(Reason, {crash_stopped, Stopper}) when is_pid(Stopper) ->
    Stopper ! {self(), {crash_stopped, Reason}},
    ok;
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

remove_error_loggers() ->
    L = gen_event:which_handlers(error_logger),
    [error_logger:delete_report_handler(H) || H <- L],
    L.

restore_error_logger(L) ->
    [error_logger:add_report_handler(H) || H <- L],
    ok.

