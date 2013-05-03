What's `gen_cb`?
================

It's a simple server behaviour for Erlang. It smells like `gen_server`, but
has more flexibility and less coupling with other code. The caller can decide 
whether to call the server synchronously or asynchonously, in runtime.

Usage
=====

See `src/tester.erl` for basic usage.

