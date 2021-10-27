# vim: set et nosta sw=4 ts=4 ft=nim : 
#
# Copyright (c) 2016-2021, Mahlon E. Smith <mahlon@martini.nu>
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#
#     * Neither the name of Mahlon E. Smith nor the names of his
#       contributors may be used to endorse or promote products derived
#       from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE REGENTS AND CONTRIBUTORS BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Overview
## ============
##
## This is a pure-nim client library for interacting with Stomp 1.2
## compliant messaging brokers.
##
## https://stomp.github.io/stomp-specification-1.2.html
##
## Stomp is a simple protocol for message passing between clients, using a central
## broker.  It is a subset of other more elaborate protocols (like AMQP), supporting
## only the most used features of common brokers.
##
## Because this library is pure-nim, there are no external dependencies.  If you
## can compile a nim binary, you can participate in advanced messaging between processes.
##
## A list of broker support for Stomp can be found here:
## https://stomp.github.io/implementations.html.
##
## This library has been tested with recent versions of RabbitMQ.  If it
## works for you with another broker, please let the author know.
##

import
    std/nativesockets,
    std/net,
    std/os,
    std/strutils,
    std/times,
    std/uri

const
    VERSION = "0.1.3" ## The current program version.
    NULL    = "\x00"  ## The NULL character.
    CR      = "\r"    ## The carriage return character.
    CRLF    = "\r\n"  ## Carriage return + Line feed (EOL).


# Exceptions
#
type
    StompError* = object of ValueError ## A generic Stomp error state.

    StompClient* = ref object of RootObj ## An object that represents a connection to a Stomp compatible server.
        socket:         Socket ## The socket object attached to this client.
        connected*:     bool ## Is the client currently connected?
        uri*:           Uri ## The URI used to instantiate this client.
        username:       string ## The Stomp server user, if any.
        password:       string ## The Stomp server password, if any.
        host:           string ## The host or IP address to connect to.
        port:           Port ## Optional, if Stomp is on a non-default port.
        vhost:          string ## Parsed from the URI path, a Stomp "virtual host".
        timeout*:       int ## Global socket timeout.
        last_msgtime*:  Time ## Timestamp of last seen server message.
        options:        tuple[ heartbeat: int ] ## Any supported client options, derived from the URI query string.
        subscriptions*: seq[ string ] ## Registered client subscriptions. Array position is the ID.
        transactions*:  seq[ string ] ## Any currently open transactions.
        serverinfo:     seq[ tuple[name: string, value: string] ] ## Server metadata, populated upon a successful connection.

        connected_callback*:        proc ( client: StompClient, response: StompResponse ): void
        error_callback*:            proc ( client: StompClient, response: StompResponse ): void
        heartbeat_callback*:        proc ( client: StompClient, response: StompResponse ): void
        message_callback*:          proc ( client: StompClient, response: StompResponse ): void
        missed_heartbeat_callback*: proc ( client: StompClient ): void
        receipt_callback*:          proc ( client: StompClient, response: StompResponse ): void

    StompResponse* = ref object of RootObj ## A parsed packet from a Stomp server.
        headers:  seq[ tuple[name: string, value: string] ] ## Any headers in the response.  Access with the `[]` proc.
        frame*:   string ## The Stomp frame type.
        payload*: string ## The message body, if any.


# convenience
proc printf( formatstr: cstring ) {.header: "<stdio.h>", varargs.}


proc encode( str: string ): string =
    ## Encode value value strings per the "Value Encoding" section
    ## of the Stomp 1.2 spec.
    result = str
    result = result.
        replace( "\r", "\\r" ).
        replace( "\n", "\\n" ).
        replace( "\\", "\\\\" ).
        replace( ":", "\\c" )


#-------------------------------------------------------------------
# R E S P O N S E
#-------------------------------------------------------------------

proc is_eol( s: string ): bool =
    ## Convenience method, returns **true** if string is a Stomp EOF.
    return s == CR or s == CRLF


proc parse_headers( response: StompResponse, c: StompClient ): int =
    ## Parse response headers from a stream.
    ## Returns the content length of the response body, or 0.
    result = 0
    var line = ""

    c.socket.readline( line, c.timeout )
    while not line.is_eol:
        if defined( debug ): printf " <-- %s\n", cstring(line)
        var header = line.split( ":" )
        if header.len < 2: break
        response.headers.add( (header[0], header[1]) )
        if cmpIgnoreCase( header[0], "content-length" ) == 0: result = header[1].parse_int
        c.socket.readline( line, c.timeout )


proc parse_payload( response: StompResponse, c: StompClient, bodylength = 0 ): void =
    ## Parse message payload from a stream.
    let bufsize = 8192
    var
        buf  = ""
        data = ""


    # If we already know the length of the body, just perform a buffered read.
    #
    if bodylength > 0:
        var
            readtotal = 0
            readamt   = 0
            remaining = 0

        while readtotal != bodylength:
            remaining = bodylength - readtotal

            if remaining < bufsize:
                readamt = remaining
            else:
                readamt = bufsize

            buf = newString( readamt )
            readtotal = readtotal + c.socket.recv( buf, readamt, c.timeout )
            data = data & buf

        # Eat the NULL terminator.
        discard c.socket.recv( buf, 1, c.timeout )

    # Inefficient path.
    #
    else:
        while buf != NULL:
            discard c.socket.recv( buf, 1, c.timeout )
            data = data & buf

    response.payload = data


proc newStompResponse( c: StompClient ): StompResponse =
    ## Initialize a response object, which parses and contains
    ## the Stomp headers and any additional important data from
    ## the broker socket.
    new( result )
    result.headers = @[]

    # Get the frame type, record last seen server activity time.
    #
    var line = ""
    c.socket.readline( line, c.timeout )
    c.last_msgtime = get_time()

    # Heartbeat packets (empties.)
    #
    # This could -also- parse optional EOLs from the prior
    # message (after the NULL separator), but since it is a no-op,
    # this seems harmless.
    #
    if line.is_eol:
        result.frame = "HEARTBEAT"
        return result

    # All other types.
    #
    result.frame = line
    if defined( debug ):
        printf " <-- %s\n", cstring(line)

    # Parse headers and body.
    #
    var length = result.parse_headers( c )
    if result.frame == "MESSAGE" or result.frame == "ERROR":
        result.parse_payload( c, length )

    # If the response -could- have a body, the NULL has already
    # been removed from the stream while we checked for one.
    #
    if result.payload.len > 0:
        if result.payload == NULL: # We checked for a body, but there was none.
            result.payload = ""
            if defined( debug ): printf " <--\n <-- ^@\n\n"
        else:
            if defined( debug ): printf " <--\n <-- (payload)^@\n\n"

    # Otherwise, pop off the NULL terminator now.
    #
    else:
        discard c.socket.recv( line, 1, c.timeout )
        if defined( debug ): printf " <--\n <-- ^@\n\n"


proc `$`*( r: StompResponse ): string =
    ## Represent a Stomp response as a string.
    result = r.frame & ": " & $r.headers


proc `[]`*( response: StompResponse, key: string ): string =
    ## Get a specific header from a Stomp response.
    for header in response.headers:
        if cmpIgnoreCase( key, header.name ) == 0:
            return header.value
    return ""


#-------------------------------------------------------------------
# C A L L B A C K S
#-------------------------------------------------------------------

proc default_error_callback( c: StompClient, response: StompResponse ) =
    ## Something bad happened.  Disconnect from the server, build an error message,
    ## and raise an exception.
    c.socket.close
    c.connected = false

    var detail = response.payload
    var msg    = response[ "message" ]
    if $detail[ ^1 ] == "\n": detail = detail[ 0 .. ^2 ] # chomp

    if detail.len > 0: msg = msg & " (" & detail & ")"
    raise newException( StompError, "ERROR: " & msg )


proc default_missed_heartbeat_callback( c: StompClient ) =
    ## Timeout while connected to the broker.
    c.socket.close
    c.connected = false
    raise newException( StompError, "Heartbeat timeout.  Last activity: " & $c.last_msgtime )



#-------------------------------------------------------------------
# C L I E N T
#-------------------------------------------------------------------

proc newStompClient*( s: Socket, uri: string ): StompClient =
    ## Create a new Stomp client object from a preexisting **socket**,
    ## and a stomp **URI** string.
    ##
    ## .. code-block:: nim
    ##
    ##    var socket = newSocket()
    ##    var stomp  = newStompClient( socket, "stomp://test:test@example.com/vhost" )
    ##
    ## or if connecting with SSL, when compiled with -d:ssl:
    ##
    ## .. code-block:: nim
    ##
    ##    var socket = newSocket()
    ##    let sslContext = newContext( verifyMode = CVerifyNone )
    ##    sslContext.wrapSocket(socket)
    ##    var stomp = newStompClient( socket, "stomp+ssl://test:test@example.com/vhost" )
    ##

    let
        uri   = parse_uri( uri )
        vhost = if uri.path.len > 1: uri.path.strip( chars = {'/'}, trailing = false ) else: uri.path

    new( result )
    result.socket        = s
    result.connected     = false
    result.uri           = uri
    result.username      = uri.username
    result.password      = uri.password
    result.host          = uri.hostname
    result.vhost         = vhost
    result.timeout       = 500
    result.subscriptions = @[]
    result.transactions  = @[]

    # Parse any supported options in the query string.
    #
    for pairs in result.uri.query.split( '&' ):
        let opt = pairs.split( '=' )
        try:
            case opt[0]:
                of "heartbeat":
                    result.options.heartbeat = opt[1].parse_int
                else:
                    discard
        except IndexDefect, ValueError:
            discard

    # Set default STOMP port if otherwise unset.
    #
    if not result.uri.scheme.contains( "stomp" ):
        raise newException( StompError, "Unknown scheme: " & result.uri.scheme  )
    var port: int
    if result.uri.port == "":
        if result.uri.scheme.contains( "+ssl" ):
            port = 61614
        else:
            port = 61613
    else:
        port = result.uri.port.parse_int

    result.port = Port( port )

    # Decode URI encoded slashes for vhosts.
    result.vhost = result.vhost.
        replace( "%2f", "/" ).
        replace( "%2F", "/" ).
        replace( "//", "/" )


proc socksend( c: StompClient, data: string ): void =
    ## Send data on the connected socket with optional debug output.
    c.socket.send( data )
    if defined( debug ): printf " --> %s", data


proc finmsg( c: StompClient ): void =
    ## Send data on the connected socket with optional debug output.
    c.socket.send( CRLF & NULL & CRLF )
    if defined( debug ): printf " --> \n --> ^@\n\n"


proc `[]`*( c: StompClient, key: string ): string =
    ## Get a specific value from the server metadata, set during the initial connection.
    if not c.connected: return ""
    for header in c.serverinfo:
        if cmpIgnoreCase( key, header.name ) == 0:
            return header.value
    return ""


proc `$`*( c: StompClient ): string =
    ## Represent the stomp client as a string, after masking the password.
    let uri = ( $c.uri ).replace( ":" & c.uri.password & "@", "@" )
    result = "(NimStomp v" & VERSION & ( if c.connected: " connected" else: " not connected" ) & " to " & uri
    if not ( c[ "server" ] == "" ): result.add( " --> " & c["server"] )
    result.add( ")" )


proc connect*( c: StompClient ): void =
    ## Establish a connection to the Stomp server.
    if c.connected: return

    var headers: seq[ tuple[name: string, value: string] ] = @[]
    headers.add( ("accept-version", "1.2") )

    # Stomp 1.2 requires the Host: header.  Use the path as a vhost if
    # supplied, otherwise use the hostname of the server.
    #
    if c.vhost != "":
        headers.add( ("host", c.vhost) )
    else:
        headers.add( ("host", c.host) )

    if c.username != "": headers.add( ("login", c.username) )
    if c.password != "": headers.add( ("passcode", c.password) )
    if c.options.heartbeat > 0:
        let heartbeat = c.options.heartbeat * 1000
        headers.add( ("heart-beat", "0," & $heartbeat) )

    # Connect the socket and send the headers off.
    #
    c.socket.connect( c.host, c.port )
    c.socksend( "CONNECT" & CRLF )
    for header in headers:
        c.socksend( header.name & ":" & header.value & CRLF )
    c.finmsg

    # Retreive and copy server metadata to client object.
    #
    var response = newStompResponse( c )
    c.serverinfo = response.headers

    if response.frame != "CONNECTED":
        if not isNil( c.error_callback ):
            c.error_callback( c, response )
        else:
            c.default_error_callback( response )
    else:
        c.connected = true
        if not isNil( c.connected_callback ):
            c.connected_callback( c, response )


proc disconnect*( c: StompClient ): void =
    ## Break down the connection to the Stomp server nicely.
    if not c.connected: return
    c.socksend( "DISCONNECT" & CRLF )
    c.finmsg

    c.socket.close
    c.connected = false


proc add_txn( c: StompClient ): void =
    ## Add a transaction header if there is only a single open txn.
    if c.transactions.len != 1: return
    c.socksend( "transaction:" & c.transactions[0] & CRLF )


proc send*( c: StompClient,
            destination: string,
            message:     string = "",
            contenttype: string = "",
            headers:     seq[ tuple[name: string, value: string] ] = @[] ): void =
    ## Send a **message** to **destination**.
    ##
    ## A Content-Length header is automatically and always included.
    ## A **contenttype** is optional, but strongly recommended.
    ##
    ## Additionally, a transaction ID is automatically added if there is only
    ## one transaction active.  If you need to attach this message to a particular
    ## transaction ID, you'll need to add it yourself with the user defined
    ## **headers**.

    if not c.connected: raise newException( StompError, "Client is not connected." )
    c.socksend( "SEND" & CRLF )
    c.socksend( "destination:" & destination.encode & CRLF )
    c.socksend( "content-length:" & $message.len & CRLF )
    if not ( contenttype == "" ): c.socksend( "content-type:" & contenttype & CRLF )

    # Add custom headers.  Add transaction header if one isn't manually
    # present (and a transaction is open.)
    #
    var txn_seen = false
    for header in headers:
        if header.name == "transaction": txn_seen = true
        c.socksend( header.name & ":" & header.value.encode & CRLF )
    if not txn_seen: c.add_txn

    if message == "":
        c.finmsg
    else:
        c.socket.send( CRLF & message & NULL )
        if defined( debug ): printf " -->\n --> (payload)^@\n\n"


proc subscribe*( c: StompClient,
            destination: string,
            ack        = "auto",
            id:        string = "",
            headers:   seq[ tuple[name: string, value: string] ] = @[] ): void =
    ## Subscribe to messages at **destination**.
    ##
    ## Setting **ack** to "client" or "client-individual" enables client ACK/NACK mode.
    ## In this mode, incoming messages aren't considered processed by
    ## the server unless they receive ACK.  By default, the server
    ## considers the message processed if a client simply accepts it.
    ##
    ## You may optionally add any additional **headers** the server may support.

    if not c.connected: raise newException( StompError, "Client is not connected." )
    c.socksend( "SUBSCRIBE" & CRLF )
    c.socksend( "destination:" & destination.encode & CRLF )

    if id == "":
        c.socksend( "id:" & $c.subscriptions.len & CRLF )
    else:
        c.socksend( "id:" & id & CRLF )

    if ack == "client" or ack == "client-individual":
        c.socksend( "ack:" & ack & CRLF )
    else:
        if ack != "auto": raise newException( StompError, "Unknown ack type: " & ack )

    for header in headers:
        c.socksend( header.name & ":" & header.value.encode & CRLF )
    c.finmsg
    c.subscriptions.add( destination )


proc unsubscribe*( c: StompClient,
            destination: string,
            headers:     seq[ tuple[name: string, value: string] ] = @[] ): void =
    ## Unsubscribe from messages at **destination**.
    ## You may optionally add any additional **headers** the server may support.

    if not c.connected: raise newException( StompError, "Client is not connected." )
    var
        sub_id: int
        i = 0

    # Find the ID of the subscription.
    #
    for sub in c.subscriptions:
        if sub == destination:
            sub_id = i
            break
        i = i + 1

    c.socksend( "UNSUBSCRIBE" & CRLF )
    c.socksend( "id:" & $sub_id & CRLF )
    for header in headers:
        c.socksend( header.name & ":" & header.value.encode & CRLF )
    c.finmsg
    c.subscriptions[ sub_id ] = ""


proc begin*( c: StompClient, txn: string ): void =
    ## Begin a new transaction on the broker, using **txn** as the identifier.
    c.socksend( "BEGIN" & CRLF )
    c.socksend( "transaction:" & txn & CRLF )
    c.finmsg
    c.transactions.add( txn )


proc commit*( c: StompClient, txn: string = "" ): void =
    ## Finish a specific transaction **txn**, or the most current if unspecified.
    var transaction = txn
    if transaction == "" and c.transactions.len > 0: transaction = c.transactions.pop
    if transaction == "": return

    c.socksend( "COMMIT" & CRLF )
    c.socksend( "transaction:" & transaction & CRLF )
    c.finmsg

    # Remove the transaction from the queue.
    #
    var new_transactions: seq[ string ] = @[]
    for txn in c.transactions:
        if txn != transaction: new_transactions.add( txn )
    c.transactions = new_transactions


proc abort*( c: StompClient, txn: string = "" ): void =
    ## Cancel a specific transaction **txn**, or the most current if unspecified.
    var transaction = txn
    if transaction == "" and c.transactions.len > 0: transaction = c.transactions.pop
    if transaction == "": return

    c.socksend( "ABORT" & CRLF )
    c.socksend( "transaction:" & transaction & CRLF )
    c.finmsg

    # Remove the transaction from the queue.
    #
    var new_transactions: seq[ string ] = @[]
    for txn in c.transactions:
        if txn != transaction: new_transactions.add( txn )
    c.transactions = new_transactions


proc ack*( c: StompClient, id: string, transaction: string = "" ): void =
    ## Acknowledge message **id**.  Optionally, attach this acknowledgement
    ## to a specific **transaction** -- if there's only one active, it is
    ## added automatically.
    c.socksend( "ACK" & CRLF )
    c.socksend( "id:" & id & CRLF )
    if not ( transaction == "" ):
        c.socksend( "transaction:" & transaction & CRLF )
    else:
        c.add_txn
    c.finmsg


proc nack*( c: StompClient, id: string, transaction: string = "" ): void =
    ## Reject message **id**.  Optionally, attach this rejection to a
    ## specific **transaction** -- if there's only one active, it is
    ## added automatically.
    ##
    ## Subscribe to a queue with ACK mode enabled, and reject the message
    ## on error:
    ##
    ## .. code-block:: nim
    ##    
    ##  stomp.subscribe( "/queue/test", "client-individual" )
    ##  FIXME: attach procs
    ##  stomp.wait_for_messages
    ##
    c.socksend( "NACK" & CRLF )
    c.socksend( "id:" & id & CRLF )
    if not ( transaction == "" ):
        c.socksend( "transaction:" & transaction & CRLF )
    else:
        c.add_txn
    c.finmsg


proc wait_for_messages*( c: StompClient, loop=true ) =
    ## Enter a blocking select loop, dispatching to the appropriate proc
    ## for the received message type.   Return after a single message
    ## is received if **loop** is set to **false**.

    if not c.connected: raise newException( StompError, "Client is not connected." )

    while true:
        var
            timeout: int
            fds = @[ c.socket.get_fd ]

        # Check for missed heartbeats, with an additional second
        # of wiggle-room.
        #
        if c.options.heartbeat > 0:
             timeout = ( c.options.heartbeat + 1 ) * 1000
        else:
            timeout = -1

        if select_read( fds, timeout ) == 0: # timeout, only happens if heartbeating missed
            if not isNil( c.missed_heartbeat_callback ):
                c.missed_heartbeat_callback( c )
            else:
                c.default_missed_heartbeat_callback
            if loop: continue else: break

        let response = newStompResponse( c )
        case response.frame:

            of "HEARTBEAT":
                if not isNil( c.heartbeat_callback ):
                    c.heartbeat_callback( c, response )
                continue

            of "RECEIPT":
                if not isNil( c.receipt_callback ):
                    c.receipt_callback( c, response )

            of "MESSAGE":
                if not isNil( c.message_callback ):
                    c.message_callback( c, response )

            of "ERROR":
                if not isNil( c.error_callback ):
                    c.error_callback( c, response )
                else:
                    c.default_error_callback( response )

            else:
                if defined( debug ):
                    echo "Strange broker frame: " & response.repr

        if not loop: break



#-------------------------------------------------------------------
# T E S T S
#-------------------------------------------------------------------

# Functional (rather than unit) tests.  Requires a Stomp compatible broker.
# This was tested against RabbitMQ 3.5.3 and 3.6.0.
# 3.6.0 was -so- much faster.
#
# First start up a message receiver:
#   ./stomp receiver [stomp-uri] [subscription-destination]
#
# then run another process, to publish stuff:
#   ./stomp publisher [stomp-uri] [publish-destination]
#
# An example with an AMQP "direct" exchange, and an exclusive queue:
#   ./stomp publisher stomp://test:test@localhost/%2F?heartbeat=10 /exchange/test
#   ./stomp receiver  stomp://test:test@localhost/%2F?heartbeat=10 /exchange/test
#
# Then just let 'er run.
#
# You can also run a naive benchmark (deliveries/sec):
#
#   ./stomp benchmark stomp://test:test@localhost%2F /exchange/test
#
# It will set messages to require acknowledgement, and nack everything, causing
# a delivery loop for 10 seconds.
#
when isMainModule:
    let expected = 8
    var
        socket   = newSocket()
        messages: seq[ StompResponse ] = @[]

    let usage = """
First start up a message receiver:
  ./stomp receiver [stomp-uri] [subscription-destination]

then run another process, to publish stuff:
  ./stomp publisher [stomp-uri] [publish-destination]

An example with an AMQP "direct" exchange, and an exclusive queue:
  ./stomp publisher stomp://test:test@localhost/%2F?heartbeat=10 /exchange/test
  ./stomp receiver  stomp://test:test@localhost/%2F?heartbeat=10 /exchange/test

Then just let 'er run.

You can also run a naive benchmark (deliveries/sec):

  ./stomp benchmark stomp://test:test@localhost/%2F /exchange/test

It will set messages to require acknowledgement, and nack everything, causing
a delivery loop for 10 seconds.

With older version of RabbitMQ, If your vhost requires slashes, you'll
need to URI escape: /%2Ftest
"""


    if paramCount() != 3: quit usage

    var stomp = newStompClient( socket, paramStr(2) )
    stomp.connect
    echo stomp

    case paramStr(1):

        of "benchmark":
            echo "* Running for 10 seconds.  Compile with -d:debug to see the Stomp conversation."
            var count = 0
            var start = get_time()

            proc incr( c: StompClient, r: StompResponse ) =
                let id = r["ack"]
                count = count + 1
                c.nack( id )

            stomp.message_callback = incr
            stomp.subscribe( paramStr(3), "client" )
            stomp.send( paramStr(3), "hi." )
            while get_time() < start + 10.seconds:
                stomp.wait_for_messages( false )

            printf "* Processed %d messages in 10 seconds.\n", count
            stomp.disconnect


        # Store incoming messages, ensure their contents match our expected behavior.
        #
        of "receiver":
            var heartbeats = 0
            echo "* Waiting on messages from publisher.  Compile with -d:debug to see the Stomp conversation."

            proc receive_message( c: StompClient, r: StompResponse ) =
                messages.add( r )

            proc seen_heartbeat( c: StompClient, r: StompResponse ) =
                heartbeats = heartbeats + 1

            stomp.message_callback   = receive_message
            stomp.receipt_callback   = receive_message
            stomp.heartbeat_callback = seen_heartbeat
            stomp.subscribe( paramStr(3) )

            # Populate the messages sequence with the count of expected messages.
            for i in 1..expected: stomp.wait_for_messages( false )

            # Assertions on the results!
            #
            doAssert( messages.len == expected )
            doAssert( messages[0].payload == "" )

            doAssert( messages[1].payload == "Hello world!" )

            doAssert( messages[2].payload == "Dumb.\n\n" )

            doAssert( messages[3].payload == "Hello again." )
            doAssert( messages[3][ "content-type" ] == "text/plain" )
            doAssert( messages[3][ "Content-Type" ] == "text/plain" )

            doAssert( messages[4][ "x-custom" ] == "yum" )

            doAssert( messages[5][ "receipt" ] == "42" )

            doAssert( messages[6].payload == "transaction!" )
            doAssert( messages[7].payload == "transaction 2" )

            stomp.disconnect

            if heartbeats > 0:
                printf "* Tests passed! %d heartbeats seen.", heartbeats
            else:
                echo "* Tests passed!"


        # Publish a variety of messages with various options.
        # Pause momentarily between sends(), as brokers -might- impose
        # rate limits and/or message dropping.
        #
        of "publisher":
            echo "* Publishing to receiver.  Compile with -d:debug to see the Stomp conversation."

            # Simple, no frills event.
            stomp.send( paramStr(3) )
            sleep 500

            # Event with a body.
            stomp.send( paramStr(3), "Hello world!" )
            sleep 500

            # Event that doesn't contain a content-length.
            # (Note, the broker may elect to add one on your behalf, which is a good thing...
            # but invalidates this test.)
            stomp.socksend( "SEND" & CRLF )
            stomp.socksend( "destination:" & paramStr(3) & CRLF & CRLF )
            stomp.socksend( "Dumb.\n\n" & NULL )
            sleep 500

            # Content-Type
            stomp.send( paramStr(3), "Hello again.", "text/plain" )
            sleep 500

            # Custom headers.
            var headers: seq[ tuple[ name: string, value: string ] ] = @[]
            headers.add( ("x-custom", "yum") )
            stomp.send( paramStr(3), "Hello again.", "text/plain", headers )
            sleep 500

            # Receipt requests.
            proc receive_receipt( c: StompClient, r: StompResponse ) =
                messages.add( r )
            headers = @[]
            headers.add( ("receipt", "42") )
            stomp.send( paramStr(3), "Hello again.", "text/plain", headers )
            stomp.receipt_callback = receive_receipt
            stomp.wait_for_messages( false )
            doAssert( messages[0]["receipt-id"] == "42" )

            # Aborted transaction.
            stomp.begin( "test-abort" )
            for i in 1..3:
                stomp.send( paramStr(3), "Message: " & $i )
            stomp.abort

            # Committed transaction.
            stomp.begin( "test-commit" )
            stomp.send( paramStr(3), "transaction!" )
            stomp.commit

            # Mixed transactions.
            for i in 1..3:
                headers = @[]
                headers.add( ("transaction", "test-" & $i ) )
                stomp.begin( "test-" & $i )
                stomp.send( paramStr(3), "transaction " & $i, "", headers )
                sleep 500
            stomp.abort( "test-1" )
            sleep 500
            stomp.commit( "test-2" )
            sleep 500
            stomp.abort( "test-3" )
            sleep 500

            stomp.disconnect
            echo "* Tests passed!"

        else:
            quit usage

