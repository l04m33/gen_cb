-ifndef(__GEN_CB_HRL__).
-define(__GEN_CB_HRL__, true).

-record(cb_event,
    {
        reply_to  = none,
        cb_arg    = none,
        msg_ref   = none,
        sent_from = none,
        context   = none,
        timeout   = infinity
    }).

-endif.
