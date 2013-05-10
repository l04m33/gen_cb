%%% -----------------------------------------------------------------
%%% Copyright 2013 Kay Z.
%%% 
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%% 
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%% 
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% -----------------------------------------------------------------

-module(gen_cb).

-export([
    start/3,
    start/4,
    start_link/3,
    start_link/4,
    call/4,
    call/5]).

-export([
    reply_cb/1,
    receive_cb/1]).

-export([
    behaviour_info/1]).

-export([
    system_continue/3,
    system_terminate/4,
    system_code_change/4]).

-export([
    init_it/6,
    loop/4]).

-include("gen_cb.hrl").

%%% -----------------------------------------------------------------
%%% behaviour_info
%%% -----------------------------------------------------------------
behaviour_info(callbacks) ->
    [
        {init,          1},
        {handle_call,   3},
        {handle_info,   2},
        {terminate,     2},
        {code_change,   3}
    ].

%%% -----------------------------------------------------------------
%%% Starters
%%% -----------------------------------------------------------------
start(Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Mod, Args, Options).

start(Name, Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Name, Mod, Args, Options).

start_link(Mod, Args, Options) ->
    gen:start(?MODULE, link, Mod, Args, Options).

start_link(Name, Mod, Args, Options) ->
    gen:start(?MODULE, link, Name, Mod, Args, Options).


init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name, Mod, Args, _Options) ->
    erlang:put('$initial_call', {Mod, init, 1}),

    Res = try 
        Mod:init(Args)
    catch ErrType : ErrName ->
        {{ErrType, ErrName}, erlang:get_stacktrace()}
    end,

    case Res of
        {ok, State} ->
            proc_lib:init_ack(Starter, {ok, self()}),
            loop(Parent, State, Mod, infinity);
        {ok, State, Timeout} ->
            proc_lib:init_ack(Starter, {ok, self()}),
            loop(Parent, State, Mod, Timeout);
        {stop, Reason} ->
            unregister_name(Name),
            proc_lib:init_ack(Starter, {error, Reason}),
            exit(Reason);
        ignore ->
            unregister_name(Name),
            proc_lib:init_ack(Starter, ignore),
            exit(normal);
        {{_ErrT, _ErrN}, _StackTrace} = Reason ->
            unregister_name(Name),
            proc_lib:init_ack(Starter, {error, Reason}),
            exit(Reason);
        Else ->
            Error = {bad_return_value, Else},
            proc_lib:init_ack(Starter, {error, Error}),
            exit(Error)
    end.


unregister_name({local, Name}) ->
    _ = (catch unregister(Name));
unregister_name({global, Name}) ->
    _ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
    _ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
    Pid.


%%% -----------------------------------------------------------------
%%% Default callbacks
%%% -----------------------------------------------------------------
reply_cb(CBEvent) ->
    ReplyTo = CBEvent#cb_event.reply_to,
    ReplyMsg = {'$gen_cb_reply', CBEvent#cb_event.cb_arg, 
                CBEvent#cb_event.msg_ref, CBEvent#cb_event.sent_from},
    erlang:send(ReplyTo, ReplyMsg),
    ok.

receive_cb(CBEvent) ->
    MsgRef = CBEvent#cb_event.msg_ref,
    Timeout = CBEvent#cb_event.timeout,
    receive
        {'$gen_cb_reply', Reply, MsgRef, _SentFrom} ->
            Reply
    after Timeout ->
        error(timeout)
    end.


%%% -----------------------------------------------------------------
%%% The calling interface
%%% -----------------------------------------------------------------
call(Dest, Request, LocalCB, RemoteCB) ->
    call(Dest, Request, LocalCB, RemoteCB, 5000).

call(Dest, Request, LocalCB, RemoteCB, Timeout) ->
    {Msg, Ref} = to_cb_msg(Request, RemoteCB),
    send_msg(Dest, Msg),
    call_local_cb(LocalCB, Ref, Timeout).


call_local_cb(CB, MsgRef, Timeout) ->
    CBEvent = #cb_event{
        msg_ref = MsgRef, 
        timeout = Timeout
    },

    case CB of
        {F, Context} when is_function(F, 1) -> 
            F(CBEvent#cb_event{context = Context});
        F when is_function(F, 1) ->
            F(CBEvent);
        none ->
            ok;
        _ ->
            error(invalid_callback)
    end.


to_cb_msg(Request, RemoteCB) ->
    MsgRef = make_ref(),
    {{'$gen_cb', self(), MsgRef, Request, RemoteCB}, MsgRef}.


send_msg({global, Name}, Msg) ->
    global:send(Name, Msg),
    ok;
send_msg({via, Mod, Name}, Msg) ->
    Mod:send(Name, Msg),
    ok;
send_msg({Name, Node} = Dest, Msg) when is_atom(Name), is_atom(Node) ->
    erlang:send(Dest, Msg),
    ok;
send_msg(Dest, Msg) when is_atom(Dest) ->
    erlang:send(Dest, Msg),
    ok;
send_msg(Dest, Msg) when is_pid(Dest) ->
    erlang:send(Dest, Msg),
    ok.


%%% -----------------------------------------------------------------
%%% The main loop
%%% -----------------------------------------------------------------
loop(Parent, State, Mod, hibernate) ->
    proc_lib:hibernate(?MODULE, loop, [Parent, State, Mod, infinity]);

loop(Parent, State, Mod, Timeout) ->
    Msg = receive
        Input ->
            Input
    after Timeout ->
        timeout
    end,

    case Msg of
        {'$gen_cb', From, MsgRef, Request, CB} ->
            Replier = fun(Rep) ->
                call_remote_cb(CB, From, Rep, MsgRef, Request, Mod, State)
            end,

            Res = try
                Mod:handle_call(Request, Replier, State)
            catch ErrType : ErrName ->
                Error = {{ErrType, ErrName}, erlang:get_stacktrace()},
                call_terminate(Error, Request, Mod, State)
            end,

            case Res of
                {reply, Reply, NState} ->
                    call_remote_cb(CB, From, Reply, MsgRef, Request, Mod, NState),
                    loop(Parent, NState, Mod, infinity);
                {reply, Reply, NState, NTimeout} ->
                    call_remote_cb(CB, From, Reply, MsgRef, Request, Mod, NState),
                    loop(Parent, NState, Mod, NTimeout);
                {stop, Reason, Reply, NState} ->
                    call_remote_cb(CB, From, Reply, MsgRef, Request, Mod, NState),
                    call_terminate(Reason, Request, Mod, NState);
                Other ->
                    handle_common_reply(Other, Request, Parent, Mod, State)
            end;

        {system, From, SysReq} ->
            sys:handle_system_msg(SysReq, From, Parent, ?MODULE, [], [State, Mod, Timeout]);

        {'EXIT', Parent, Reason} = ExitMsg ->
            call_terminate(Reason, ExitMsg, Mod, State);

        OtherRequest ->
            Res = try
                Mod:handle_info(OtherRequest, State)
            catch ErrType : ErrName ->
                Error = {{ErrType, ErrName}, erlang:get_stacktrace()},
                call_terminate(Error, OtherRequest, Mod, State)
            end,

            handle_common_reply(Res, OtherRequest, Parent, Mod, State)
    end.


handle_common_reply(Res, Msg, Parent, Mod, State) ->
    case Res of
        {noreply, NState} ->
            loop(Parent, NState, Mod, infinity);
        {noreply, NState, NTimeout} ->
            loop(Parent, NState, Mod, NTimeout);
        {stop, Reason, NState} ->
            call_terminate(Reason, Msg, Mod, NState);
        Other ->
            ResError = {bad_return_value, Other},
            call_terminate(ResError, Msg, Mod, State)
    end.


call_remote_cb(CB, From, Reply, MsgRef, Msg, Mod, State) ->
    CBEvent = #cb_event{
        reply_to  = From,
        cb_arg    = Reply,
        msg_ref   = MsgRef,
        sent_from = self()
    },

    case CB of
        {F, Context} when is_function(F, 1) -> 
            try
                F(CBEvent#cb_event{context = Context})
            catch ErrType : ErrName ->
                Error = {{ErrType, ErrName}, erlang:get_stacktrace()},
                call_terminate(Error, Msg, Mod, State)
            end;
        F when is_function(F, 1) ->
            try
                F(CBEvent)
            catch ErrType : ErrName ->
                Error = {{ErrType, ErrName}, erlang:get_stacktrace()},
                call_terminate(Error, Msg, Mod, State)
            end;
        none ->
            skip;
        Other ->
            call_terminate({invalid_callback, Other}, Msg, Mod, State)
    end,
    ok.


%%% -----------------------------------------------------------------
%%% Termination
%%% -----------------------------------------------------------------
call_terminate(Reason, Msg, Mod, State) ->
    _Res = try
        Mod:terminate(Reason, State)
    catch ErrType : ErrName ->
        Error = {{ErrType, ErrName}, erlang:get_stacktrace()},
        error_logger:format("** Generic callback server ~p terminating ~n"
                            "** Last message in was ~p~n"
                            "** When Server state == ~p~n"
                            "** Reason for termination == ~n** ~p~n",
                            [self(), Msg, State, Error]),
        exit(Error)
    end,

    case Reason of
        normal ->
            exit(normal);
        shutdown ->
            exit(shutdown);
        {shutdown, _} = Shutdown ->
            exit(Shutdown);
        _ ->
            error_logger:format("** Generic callback server ~p terminating ~n"
                                "** Last message in was ~p~n"
                                "** When Server state == ~p~n"
                                "** Reason for termination == ~n** ~p~n",
                                [self(), Msg, State, Reason]),
            exit(Reason)
    end.


%%% -----------------------------------------------------------------
%%% System callbacks
%%% -----------------------------------------------------------------
system_continue(Parent, _DebugOpt, [State, Mod, Timeout]) ->
    loop(Parent, State, Mod, Timeout).

system_terminate(Reason, _Parent, _DebugOpt, [State, Mod, _Timeout]) ->
    call_terminate(Reason, [], Mod, State).

system_code_change([State, Mod, Timeout], _Module, OldVsn, Extra) ->
    case catch Mod:code_change(OldVsn, State, Extra) of
        {ok, NewState} -> 
            {ok, [NewState, Mod, Timeout]};
        Else -> 
            Else
    end.

