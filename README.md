# README #

## Overview ##

This is a pure-nim client library for interacting with Stomp
compliant messaging brokers.

https://stomp.github.io/

Stomp is a simple protocol for message passing between clients, using a central
broker.  It is a subset of other more elaborate protocols (like AMQP), supporting
only the most used features of common brokers.

Because this library is pure-nim, there are no external dependencies.  If you
can compile a nim binary, you can participate in advanced messaging between processes.

A list of broker support for Stomp can be found here:
https://stomp.github.io/implementations.html.

This library has been tested with recent versions of RabbitMQ.  If it
works for you with another broker, please let the author know.

### Installation ###

The easiest way to install this module is via the nimble package manager, 
by simply running 'nimble install stomp'.

Alternatively, you can fetch the 'stomp.nim' file yourself, and put it
in a place of your choosing.


### Protocol support ###

This library supports (almost) the entirety of the Stomp 1.2 spec,
with the exception of client to server heartbeat.  Server to client
heartbeat is fully supported, which should normally be sufficient to
keep firewall state tables open and sockets alive.


### Callbacks ###

Because a client can receive frames at any time, most of the behavior
of this module is implemented via callback procs.

By default, most every event is a no-op.  You can override various
behaviors with the following callbacks:

* **connected_callback**:  Called when the Stomp library makes a successful
 connection to the broker.

* **error_callback**: Called if there was a **ERROR** frame in the stream. By default,
 this raises a **StompError** exception with the error message.

* **heartbeat_callback**: Called when a server heartbeat is received.

* **message_callback**: Called when a **MESSAGE** frame is received.

* **missed_heartbeat_callback**: Called when the Stomp socket is idle longer than
 the specified heartbeat time -- usually an indication of a problem.  The default behavior
 raises a **StompError** exception.

* **receipt_callback**: Called when a **RECEIPT** frame is received.


### Custom headers ###

Depending on the broker, you may be able to add addtional features to outgoing messages
by adding specific headers.  You can also add "x-headers" that are carried between messages.

Another use is to issue "receipts" on sends or subscriptions, to ensure the broker has
processed your request.  Here's an example of how to perform receipt processing:

```
#!nimrod
proc accept_receipt( c: StompClient, r: StompResponse ) =
   var receipt = r[ "receipt-id" ]
   # ... match this receipt up to the request that generated it

var client = newStompClient( socket, "..." )

client.receipt_callback = accept_receipt
client.connect

var headers = seq[ tuple[name:string, value:string] ]
headers.add( ("x-breakfast", "tequila") )
headers.add( ("receipt", "special-identifier") )

client.send( "/destination", "message!", "text/plain", headers )
```


### Transactions ###

This library has full support for transactions.  Once entering a
transaction, any messages or acknowledgments attached to it must be
committed before the broker will release them.

With one open transaction, messages are automatically attached to it.
If you have multiple open transactions, you'll need to add which one
you want a message to be part of via the custom headers.

```
#!nimrod
# Single transaction
#
client.begin( "trans-1" )
client.send( "/destination", "hi" ) # Part of "trans-1"
client.send( "/destination", "yo" ) # Part of "trans-1"
client.send( "/destination", "whaddup" ) # Part of "trans-1"
client.commit # or client.abort

# Multiple simultaneous transactions
#
client.begin( "trans-1" )
client.begin( "trans-2" )
client.begin( "trans-3" )

var headers = seq[ tuple[name:string, value:string] ]
headers.add( ("transaction", "trans-1") )
client.send( "/destination", "hi", nil, headers ) # Part of "trans-1"

headers = @[]
headers.add( ("transaction", "trans-2") )
client.send( "/destination", "hi", nil, headers ) # Part of "trans-2"
client.ack( "some-ack-id", "trans-2" ) # Part of "trans-2"

headers = @[]
headers.add( ("transaction", "trans-3") )
client.send( "/destination", "hi", nil, headers ) # Part of "trans-3"
client.ack( "some-ack-id", "trans-3" ) # Part of "trans-3"

client.abort( "trans-1" )  # anything "trans-1" never happened
client.commit( "trans-2" ) # "trans-2" messages and acks are released
client.abort( "trans-3" )  # anything "trans-3" never happened
```

### Example ###

This is a complete client that does the following:

* Connect to an AMQP server at **mq.example.com** via SSL as the **test** user,
  in the **/example** vhost.
* Request heartbeats every **5** seconds.
* Subscribe to a topic exchange **events** with the key of **user.create**, requiring message
  acknowledgement.
* Accept incoming messages, parsing the JSON payloads.
* If parsing was successful, ACK the message and emit a new message to the exchange
  with JSON results to the **user.created** key -- presumably to be picked up by another
  process elsewhere.

```
#!nimrod
# (This should be compiled with -d:ssl)

import
   std/[net,json],
   stomp

let
   socket = newSocket()
   sslContext = newContext( verifyMode = CVerifyNone )

sslContext.wrapSocket( socket )
var client = newStompClient( socket, "stomp+ssl://test:test@mq.example.com/%2Fexample?heartbeat=5" )

# Announce when we're connected.
proc connected( c: StompClient, r: StompResponse ) =
   echo "Connected to a ", c["server"], " server."

# Echo to screen when we see a heartbeat.
proc heartbeat( c: StompClient, r: StompResponse ) =
   echo "Heartbeat at: ",  c.last_msgtime

# Parse JSON, perform work, send success message.
proc message( c: StompClient, r: StompResponse ) =
   let id = r[ "ack" ]

   if r[ "content-type" ] != "application/json":
	   echo "I expect JSON payloads."
	   c.nack( id )
	   return

   try:
	   var json = r.payload.parse_json

	   # ... do the heavy lifting with the parsed data.
	   # ... and assuming is was successful, ack and emit!
	   
	   c.ack( id )

	   var message = %*{ "user": json["user"].getStr, "otherstuff": true }
	   c.send( "/exchange/events/user.created", $message, "application/json" )

   except JsonParsingError:
	   echo "Couldn't parse JSON! ", r.payload
	   c.nack( id )

# Attach callbacks
client.connected_callback = connected
client.message_callback = message
client.heartbeat_callback = heartbeat

# Open a session with the broker
client.connect

# Subscribe to a topic key, requiring acknowledgements.
client.subscribe( "/exchange/events/user.create", "client-individual" )

# Enter message loop.
client.wait_for_messages
```

