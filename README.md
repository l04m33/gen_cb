What's `gen_cb`?
================

It's a simple server behaviour for Erlang. It smells like `gen_server`, but
has more flexibility and less coupling with other code. The caller can decide 
whether to call the server synchronously or asynchonously, in runtime.

Usage
=====

See `src/tester.erl` for basic usage. It should be simple enough once you 
know `gen_server` :).

Limitations
===========

Passing around functions between nodes are somewhat dangerous, unless one 
can assure that the same code for the functions exists on all nodes, in the
same version. Thus using `gen_cb` in a distributed environment is discouraged.

TODO
====

1. Add tests.
2. Handle code change & hibernation.

