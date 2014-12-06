EQM - supply and demand equilibrium.
==
This application implements supply-demand channels between producer and
subscribers.

Erlang processes mailboxes are unbounded. This means that they will keep
accepting messages until the machine runs out of memory.
There are many ways to solve this problem, you can
introduce rate limit on the producers,
use bounded mailbox processes like [pobox](https://github.com/ferd/pobox) and
shed load,
or you can slow down the api responses to reflect system capabilities.

This library protects consumers of the messages from being overloaded and
moves the responsibility of how to deal with overflow to the edge of your
system (producers). In other words, `eqm` offers bounded message queue on
the subscriber side with a knowledge about available capacity on publisher side.

It uses upstream demand channel. It means, that message producers know
about consumers capabilities and they can't push more messages than
consumers are able to process.

The current code has extensive test cases (89% coverage), but it has not been used in production systems yet.
If you use `eqm` in production, I would very much like to hear about it.
Especially if you encountered any problems while doing so.

## The Principles

- Data items flow downstream.
- Demand flows upstream.
- Data items flow only when there is a demand.
  - Receipient is in control of incoming data rate.
  - Data in flight is bounded by signaled demand.

    ```
    +-----------+   demand   +------------+
    |           |  ---<----  |            |
    | Publisher |            | Subscriber |
    |           |  ===>====  |            |
    +-----------+    data    +------------+
    ```

## How to build it
`make deps compile`

## How to run tests
`make tests`

## Tutorial

To use eqm, you must first start the eqm application:

```erlang
1> application:start(eqm).
ok
```

Next, you need to start publisher:

```erlang
2> {ok, Publisher} = eqm:start_publisher(eqm_test).
{ok,{pub,28693,32790,<0.52.0>,<0.51.0>,eqm_test}}
```

Publisher, without subscribers (or with full subscribers buffers) will return
an error:

```erlang
3> eqm_pub:post(Publisher, message).
{error,no_capacity}
```

There are two available contexts when posting a message:

* `sync` - a default one. Post message synchronously. This is the safe way where
each call is factored through the `gen_server`.
* `async_dirty` - A fast call path, which circumvents the single gen_server process.
It is much faster, but it might introduce races and subscribers limit might be a bit strained.
In other words, with `Context = async_dirty` the calls are not linearizible.

To post message with explicit Context defined:

```erlang
4> eqm_pub:post(Publisher, message, sync).
{error,no_capacity}
5> eqm_pub:post(Publisher, message, async_dirty).
{error,no_capacity}
```

While creating a subscriber, you need to define size of the buffer:

```erlang
6> {ok, Subscriber} = eqm:start_subscriber(Publisher, 100).
{ok,{subscriber,<0.57.0>,#Ref<0.0.0.829>}}
```

At this moment publisher should know that it can send 100 messages to
subscriber:

```erlang
7> eqm_pub:capacity(Publisher).
{ok,100}
```

And posting a message should be successful this time:

```erlang
8> eqm_pub:post(Publisher, message).
ok
```

Subscriber is a `gen_fsm` which implements states very similar to [pobox](https://github.com/ferd/pobox).
When starting a subscriber first state is `notify`, so subscribers owner
process will receive a message about new post and switch state to `passive`

```erlang
9> flush().
Shell got {mail,<0.57.0>,new_data}
ok
```

At this point you can either switch back to `notify` and wait for next new
message notification:

```erlang
10> eqm_sub:notify(Subscriber).
ok
11> eqm_pub:post(Publisher, message2).
ok
12> flush().
Shell got {mail,<0.57.0>,new_data}
ok
```

Or you can ask subscriber process for messages:

```erlang
13> eqm_sub:active(Subscriber).
ok
14> flush().
Shell got {mail,<0.57.0>,[message,message2],2}
ok
```

[Pobox](https://github.com/ferd/pobox) has an excellent documentation about
those states.

Resizing subscribers buffer is also possible:

```erlang
15> eqm_pub:capacity(Publisher).
{ok,100}
16> eqm_sub:resize(Subscriber, 50).
ok
17> eqm_pub:capacity(Publisher).
{ok,50}
```

There are two ways to stop a subscriber. First, you can just stop subscriber
and lose all the messages in buffer:

```erlang
18> eqm:stop_subscriber(Subscriber).
ok
```

Or you can cancel subscription and receive all the messages from the buffer before
subscriber stops:

```erlang
19> {ok, NewSubscriber} = eqm:start_subscriber(Publisher, 100).
{ok,{subscriber,<0.71.0>,#Ref<0.0.0.983>}}
20> eqm_pub:post(Publisher, message3).
ok
21> eqm_sub:cancel(NewSubscriber).
ok
22> flush().
Shell got {mail,<0.71.0>,new_data}
Shell got {mail,<0.71.0>,[message3],1,last}
```

In case of any questions don't hesitate to ping me.

## Speed
On Q4 2013 Macbook Pro, OSX 10.9.5 with a processor `2,8 GHz Intel Core
i7` (2 cores) I get results:

* `sync`
   * without subscribers (or with full subscribers buffers) ~280k mps
   * with subscribers ~150k mps
* `async_dirty`
   * without subscribers (or with full subscribers buffers) ~630k mps
   * with subscribers ~580k mps

I tested speed of eqm using a stress test: `stress/stress.erl`. You can run it
by your self:

```
$  make stress
==> proper (compile)
make[1]: 'include/compile_flags.hrl' is up to date.
==> eqm (compile)
Compiled src/eqm_pub.erl
Erlang R16B02 (erts-5.10.3) [source] [64-bit] [smp:4:4] [async-threads:10] [kernel-poll:false]

Eshell V5.10.3  (abort with ^G)
(eqm@local-2)1> stress:run().
```

## Contributing

If you see something missing or incorrect, do not hesitate to create an issue
or pull request. Thank you!

## Roadmap
- request more items from producer after reaching some threshold
- rethink supervision trees (maybe there is not need for separated supervision
  subtree for each producer)
- try to speed up synchronous dispatch in producer
- add folsom statistics
- when activating subscriber process pass function and state like in [pobox](https://github.com/ferd/pobox)

## Changelog

- 1.0.0: Initial Release

## Authors

- Lukasz Biedrycki / @loucash: current implementation
