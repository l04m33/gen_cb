-module(gen_cb).

-export([
    start/3,
    start/4,
    start_link/3,
    start_link/4,
    call/4,
    call/5]).

-export([
    behaviour_info/1]).

-export([
    init_it/6]).

-include("gen_cb.hrl").

%%% -----------------------------------------------------------------
%%% behaviour_info
%%% -----------------------------------------------------------------
behaviour_info(callbacks) ->
    [
        {init,          1},
        {handle_call,   3},
        {handle_info,   2}
        %{terminate,     2},
        %{code_change,   3}
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
%%% The calling interface
%%% -----------------------------------------------------------------
call(Dest, Request, LocalCB, RemoteCB) ->
    call(Dest, Request, LocalCB, RemoteCB, infinity).

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
                call_remote_cb(CB, From, Rep, MsgRef)
            end,

            Res = try
                Mod:handle_call(Request, Replier, State)
            catch ErrType : ErrName ->
                Error = {{ErrType, ErrName}, erlang:get_stacktrace()},
                exit(Error)
            end,

            case Res of
                {reply, Reply, NState} ->
                    call_remote_cb(CB, From, Reply, MsgRef),
                    loop(Parent, NState, Mod, infinity);
                {reply, Reply, NState, NTimeout} ->
                    call_remote_cb(CB, From, Reply, MsgRef),
                    loop(Parent, NState, Mod, NTimeout);
                {stop, Reason, Reply, _NState} ->
                    call_remote_cb(CB, From, Reply, MsgRef),
                    exit(Reason);
                Other ->
                    handle_common_reply(Other, Parent, Mod, State)
            end;

        OtherRequest ->
            Res = try
                Mod:handle_info(OtherRequest, State)
            catch ErrType : ErrName ->
                Error = {{ErrType, ErrName}, erlang:get_stacktrace()},
                exit(Error)
            end,

            handle_common_reply(Res, Parent, Mod, State)
    end.


handle_common_reply(Res, Parent, Mod, _State) ->
    case Res of
        {noreply, NState} ->
            loop(Parent, NState, Mod, infinity);
        {noreply, NState, NTimeout} ->
            loop(Parent, NState, Mod, NTimeout);
        {stop, Reason, _NState} ->
            exit(Reason);
        Other ->
            ResError = {bad_return_value, Other},
            exit(ResError)
    end.


call_remote_cb(CB, From, Reply, MsgRef) ->
    CBEvent = #cb_event{
        reply_to  = From,
        cb_arg    = Reply,
        msg_ref   = MsgRef,
        sent_from = self()
    },

    case CB of
        {F, Context} when is_function(F, 1) -> 
            F(CBEvent#cb_event{context = Context});
        F when is_function(F, 1) ->
            F(CBEvent);
        none ->
            skip;
        _ ->
            error(invalid_callback)
    end,
    ok.

