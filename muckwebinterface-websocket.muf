@edit $www/mwi/websocket
1 99999 d
i
 
(
MuckWeb Interface (MWI) - Websockets
https://github.com/chinthliss/MuckWebInterface-WebSocket
This is the program to host the websocket used by the MWI webpage framework. It is NOT the websocket used by the direct connect client.
The github project contains the full documentation. This program only contains relavant notes from the muck side.
 
Assumes the muck takes time to re-use descrs, in particular that their is sufficient time to see a descr is disconnected before it is re-used.
 
Underlying transmission code attempts to minimize the amount of encoding done by not doing it for every recipient
Approximate transmission route:
[Public send request functions through various SendToX methods]
[Requests broken down into a list of descrs and the message, ending in sendMessageToDescrs]
[Message is encoded appropriately once and sent to each websocket]
 
The connection details stored in connections:
    descr: Descr for connection. The dictionary is also indexed by this.
    pid: PID of client process
    player: Associated player dbref
    account: Associated account - stored so we're not reliant on player for the reference
    channels: String list of channels joined
    connectedAt: Time of connection
    acceptedAt: Time connection handshake completed
    properties: keyValue list if properties set on a connection
    ping: Last performance between ping sent and ping received
    lastPingOut: Systime_precise a pending ping was issued.
    lastPingIn: Systime_precise a pending ping was received
 
Properties on program:
    debugLevel: Present debug level. Only read on load, as it's then cached due to constant use.
    @channels/<channel>/<programDbref>:<program creation date> - Programs to receive messages for a channel.
    @player/<some sort of reference>:<program> - Programs to receive wsConnect/wsDisconnect events based on player connection/disconnects
    disabled:If Y the system will prevent any connections
)
$def _version "1.2.2"
 
$include $lib/kta/strings
$include $lib/kta/misc
$include $lib/kta/proto
$include $lib/kta/json
$include $lib/account
$include $lib/websocketIO
 
$pubdef : (Clear present _defs)
 
$libdef websocketIssueAuthenticationToken
$libdef getConnections
$libdef getCaches
$libdef getDescrs
$libdef getBandwidthCounts
$libdef connectionsFromPlayer
$libdef playerUsingChannel?
$libdef accountUsingChannel?
$libdef playersOnChannel
$libdef playersOnWeb
$libdef setConnectionProperty
$libdef getConnectionProperty
$libdef delConnectionProperty
$libdef sendToDescrs
$libdef sendToDescr
$libdef sendToChannel
$libdef sendToPlayer
$libdef sendToPlayers
$libdef sendToAccount
$libdef sendNotificationToDescr
 
$def allowCrossDomain 1        (Whether to allow cross-domain connections. This should only really be on during testing/development.)
$def heartbeatTime 2           (How frequently the heartbeat event triggers)
$def pingFrequency 5           (How often websocket connections are pinged)
$def maxPingTime 12            (If a ping request isn't responded to in this amount of seconds the connection will be flagged as disconnected)
$def maxAuthTime 30            (How long a request has to authenticate before being dropped)
$def protocolVersion "1" (Only clients that meet such are allowed to connect)
 
$ifdef is_dev
   $def allowCrossDomain 1
$endif
 
(If defined, the program will measure bandwidth, adding a small amoun of overhead to every input or output)
$def trackBandwidth
 
(Log levels:
   Error   - Always output
   Notice  - Always output, core things
   Warning - Things that could be an error but might not be
   Info    - Information above the individual connection level, e.g. player or channel
   Debug   - Inner process information on an individual connection level, often spammy
)
$def debugLevelWarning 1
$def debugLevelInfo 2
$def debugLevelTrivial 3
$def debugLevelAll 4
 
(Rest of the logs are optional depending on if they're turned on and thus behind gates to save processing times)
(For readibility the code between them should be indented)
$def _startLogWarning debugLevel @ debugLevelWarning >= if
$def _stopLogWarning " Warn" getLogPrefix swap strcat logstatus then
 
$def _startLogInfo debugLevel @ debugLevelInfo >= if
$def _stopLogInfo " Info" getLogPrefix swap strcat logstatus then
 
$def _startLogDebug debugLevel @ debugLevelAll >= if
$def _stopLogDebug "Debug" getLogPrefix swap strcat logstatus then
$def _stopLogDebugMultiple foreach nip "Debug" getLogPrefix swap strcat logstatus repeat then
 
svar connections (Main collection of connections, indexed by descr)
svar cacheByChannel ( {channel:[descr..]} )
svar cacheByPlayer ( {playerAsInt:[descr..]} )
svar cacheByAccount ( {accountAsInt:[descr..]} )
svar serverProcess (PID of the server daemon)
svar bandwidthCounts
svar debugLevel (Loaded from disk on initialization but otherwise in memory to stop constant proprefs)
 
: getLogPrefix (s -- s) (Outputs the log prefix for the given type)
    "[MWI-WS " swap 5 right strcat " " strcat pid serverProcess @ over = if pop "" else intostr then 8 right strcat "] " strcat
;
 
: logError (s -- ) (Output definite problems)
    "ERROR" getLogPrefix swap strcat logstatus
;
 
: logNotice (s -- ) (Output important notices)
    "-----" getLogPrefix swap strcat logstatus
;
 
: getConnections ( -- arr) (Return the connection collection)
    connections @
; archcall getConnections
 
: getCaches ( -- arr arr arr ) (Return the caches)
    cacheByChannel @
    cacheByPlayer @
    cacheByAccount @
; archcall getCaches
 
: getDescrs ( -- arr) (Returns descrs the program is using, so other programs know they're reserved)
    { }list
    connections @ foreach pop swap array_appenditem repeat
; PUBLIC getDescrs
 
: getBandwidthCounts ( -- arr)
    bandwidthCounts @
; archcall getBandwidthCounts
 
(Record bandwidth in the relevant bucket.)
: trackBandwidthCounts[ int:bytes str:bucket -- ]
    bandwidthCounts @ bucket @ array_getitem ?dup not if { }dict then
    "%Y/%m/%d %k" systime timefmt (S: thisBucket cacheableName)
    over if
        over over array_getitem dup not if (Remove oldest) (S: thisBucket cacheableName value)
            rot dup array_count 24 > if dup array_first pop array_delitem then rot rot
        then
    else nip { }dict swap 0 then (No entries exist, new bucket AND new value)
    bytes @ + rot rot array_setitem
    bandwidthCounts @ bucket @ array_setitem bandwidthCounts !
;
 
  (Produces a string with the items in ConnectionDetails for logging and debugging)
: connectionDetailsToString[ arr:details -- str:result ]
    details @ not if "[Invalid/Disconnected Connection]" exit then
        "[Descr " details @ "descr" array_getitem intostr strcat
        ", PID:" details @ "pid" array_getitem intostr strcat strcat
        ", Account:" details @ "account" array_getitem ?dup not if "-UNSET-" else intostr then strcat strcat
        ", Player:" details @ "player" array_getitem ?dup not if "-UNSET-" else dup ok? if name else pop "-INVALID-" then then strcat strcat
    "]" strcat
;
 
  (Utility function - ideally call connectionDetailsToString instead.)
: descrToString[ str:who -- str:result ]
    connections @ who @ array_getitem connectionDetailsToString
;
 
: ensureInit
    (Ensures variables are configured and server daemon is running)
    connections @ dictionary? not if
        { }dict connections !
        { }dict cacheByChannel !
        { }dict cacheByPlayer !
        { }dict cacheByAccount !
        { }dict bandwidthCounts !
        "Initialised data structures." logNotice
        prog "debugLevel" getpropval debugLevel !
    then
    serverProcess @ ?dup if ispid? not if
        "Server process has stopped, attempting to restart." logError
        0 serverProcess !
    then then
    serverProcess @ not if
        0 prog "ServerStartup" queue serverProcess ! (Need to set immediately to prevent loops)
    then
;
 
: websocketIssueAuthenticationToken[ aid:account dbref?:character -- str:token ]
    systime_precise intostr "-" "." subst "-" strcat random 1000 % intostr base64encode strcat var! token
    prog "@tokens/" token @ strcat "/issued" strcat systime setprop
    prog "@tokens/" token @ strcat "/account" strcat account @ setprop
    character @ if
        prog "@tokens/" token @ strcat "/character" strcat character @ setprop
    then
    token @
; wizcall websocketIssueAuthenticationToken
 
  (Check to see if a player is using the connection framework)
: connectionsFromPlayer[ dbref:player -- int:connections ]
    player @ player? not if "Invalid Arguments" abort then
    cacheByPlayer @ player @ int array_getitem ?dup if array_count else 0 then
; PUBLIC connectionsFromPlayer
 
  (Check to see if a player is on the given channel)
: playerUsingChannel?[ dbref:player str:channel -- int:bool ]
    cacheByPlayer @ player @ int array_getitem ?dup not if 0 exit then
    cacheByChannel @ channel @ array_getitem ?dup not if pop 0 exit then
    array_intersect array_count
; PUBLIC playerUsingChannel?
 
  (Check to see if an account is on the given channel)
: accountUsingChannel?[ int:account str:channel -- int:bool ]
    cacheByAccount @ account @ array_getitem ?dup not if 0 exit then
    cacheByChannel @ channel @ array_getitem ?dup not if pop 0 exit then
    array_intersect array_count
; PUBLIC accountUsingChannel?
 
  (Returns a list of players on the given channel.)
: playersOnChannel[ str:channel -- list:players ]
    { }list
    cacheByChannel @ channel @ array_getitem ?dup if
        foreach nip
            connections @ swap array_getitem ?dup if
                "player" array_getitem
                dup dbref? not if pop continue then
                dup player? if swap array_appenditem else pop then
            then
        repeat
        1 array_nunion
    then
; PUBLIC playersOnChannel
 
  (Returns a list of accounts on the given channel.)
: accountsOnChannel[ str:channel -- list:accounts ]
    { }list
    cacheByChannel @ channel @ array_getitem ?dup if
        foreach nip
            connections @ swap array_getitem ?dup if
                "account" array_getitem ?dup if swap array_appenditem then
            then
        repeat
        1 array_nunion
    then
; PUBLIC accountsOnChannel
 
  (Returns a list of every player connected)
: playersOnWeb[ -- list:players ]
    { }list
    cacheByPlayer @ foreach pop
        dbref dup player? if swap array_appenditem else pop then
    repeat
; PUBLIC playersOnWeb
 
: setConnectionProperty[ descr:who str:property any:data -- ]
    who @ int? property @ string? AND not if "setConnectionProperty: Invalid arguments" abort then
    connections @ who @ array_getitem ?dup not if exit then
    dup "properties" array_getitem data @ swap property @ array_setitem
    swap "properties" array_setitem connections @ who @ array_setitem connections !
; PUBLIC setConnectionProperty
 
: getConnectionProperty[ descr:who str:property -- any:data ]
    who @ int? property @ string? AND not if "getConnectionProperty: Invalid arguments" abort then
    connections @ who @ array_getitem ?dup not if 0 exit then
    "properties" array_getitem property @ array_getitem
; PUBLIC getConnectionProperty
 
: delConnectionProperty[ descr:who str:property -- ]
    who @ int? property @ string? AND not if "delConnectionProperty: Invalid arguments" abort then
    connections @ who @ array_getitem ?dup not if exit then
    dup "properties" array_getitem property @ array_delitem
    swap "properties" array_setitem connections @ who @ array_setitem connections !
; PUBLIC delConnectionProperty
 
: dispatchStringToDescrs[ arr:descrs str:string -- ]
    string @ ensureValidUTF8WithEncodedEscapeCharacter string !
    (string @ strlen 65000 > if "Outgoing string is over 65000 characters and too long for the muck." abort then)
    $ifdef trackbandwidth
        descrs @ array_count string @ strlen 2 + * "websocket_out" trackBandwidthCounts
    $endif
    descrs @ string @ webSocketSendTextFrameToDescrs
;
 
: prepareSystemMessage[ str:message ?:data -- str:encoded ]
    "SYS" message @ strcat "," strcat data @ encodeJson strcat
;
 
: prepareChannelMessage[ str:channel str:message ?:data -- str:encoded ]
    "MSG" channel @ strcat "," strcat message @ strcat "," strcat data @ encodeJson strcat
;
 
(Utility to continue a system message through and ensure it's logged)
: sendSystemMessageToDescrs[ arr:descrs str:message ?:data -- ]
    message @ data @ prepareSystemMessage
    $ifdef trackBandwidth
        descrs @ array_count over strlen * 2 + "system_out" trackBandwidthCounts
    $endif
    _startLogDebug
        { }list var! debugOutput
        descrs @ foreach nip
            "[>>] " message @ strcat " " strcat swap intostr strcat ": " strcat over dup "," instr strcut nip strcat
            debugOutput @ array_appenditem debugOutput !
        repeat
        debugOutput @
    _stopLogDebugMultiple
    descrs @ swap dispatchStringToDescrs
;
 
(This is the root function for sending - all sendTo functions break down their requirements to call this one)
(It assumes argument checking has been performed already)
: sendChannelMessageToDescrs[ arr:descrs str:channel str:message any:data -- ]
    channel @ message @ data @ prepareChannelMessage
    $ifdef trackBandwidth
        message @ strlen descrs @ array_count * "channel_" channel @ strcat "_out" strcat trackBandwidthCounts
    $endif
    _startLogDebug
        { }list var! debugOutput
        descrs @ foreach nip
            "[>>][" channel @ strcat "." strcat message @ strcat "] " strcat swap intostr strcat ": " strcat
            (Trim down to data part of outgoing string rather than processing it again)
            over dup "," instr strcut nip dup "," instr strcut nip strcat
            debugOutput @ array_appenditem debugOutput !
        repeat
        debugOutput @
    _stopLogDebugMultiple
    descrs @ swap dispatchStringToDescrs
;
 
: sendToDescrs[ arr:descrs str:channel str:message any:data -- ]
    descrs @ array? channel @ string? message @ string? AND AND not if "Invalid arguments" abort then
    message @ "" stringcmp not if "Message can't be blank" abort then
    channel @ "" stringcmp not if "Channel can't be blank" abort then
    descrs @ channel @ message @ data @ sendChannelMessageToDescrs
; PUBLIC sendToDescrs
 
: sendToDescr[ int:who str:channel str:message any:data -- ]
    who @ dup int? AND not if "'Who' must be a non-zero descr." abort then
    channel @ dup string? AND not if "'Channel' must be a non-blank string." abort then
    message @ dup string? AND not if "'Message' must be a non-blank string." abort then
    { who @ }list channel @ message @ data @ sendChannelMessageToDescrs
; PUBLIC sendToDescr
 
: sendToChannel[ str:channel str:message any:data -- ]
    channel @ string? message @ string? AND not if "Invalid arguments" abort then
    message @ "" stringcmp not if "Message can't be blank" abort then
    channel @ "" stringcmp not if "Channel can't be blank" abort then
    cacheByChannel @ channel @ array_getitem ?dup if channel @ message @ data @ sendChannelMessageToDescrs then
; PUBLIC sendToChannel
 
: sendToPlayer[ dbref:player str:channel str:message any:data -- ]
    player @ dbref? channel @ string? message @ string? AND AND not if "Invalid arguments" abort then
    player @ ok? not if "Player must be valid" abort then
    message @ "" stringcmp not if "Message can't be blank" abort then
    channel @ "" stringcmp not if "Channel can't be blank" abort then
    cacheByPlayer @ player @ int array_getitem ?dup not if 0 exit then
    cacheByChannel @ channel @ array_getitem ?dup not if pop 0 exit then
    array_intersect
    ?dup if
        channel @ message @ data @ sendChannelMessageToDescrs
    then
; PUBLIC sendToPlayer
 
: sendToPlayers[ arr:players str:channel str:message any:data -- ]
    players @ array? channel @ string? message @ string? AND AND not if "Invalid arguments" abort then
    message @ "" stringcmp not if "Message can't be blank" abort then
    channel @ "" stringcmp not if "Channel can't be blank" abort then
    { }list (Combined list) var player
    players @ foreach nip player !
        cacheByPlayer @ player @ int array_getitem ?dup not if 0 exit then
        cacheByChannel @ channel @ array_getitem ?dup not if pop 0 exit then
        array_intersect
        ?dup if
            array_union
        then
    repeat
    channel @ message @ data @ sendChannelMessageToDescrs
; PUBLIC sendToPlayers
 
: sendToAccount[ aid:account str:channel str:message any:data -- ]
    account @ int? channel @ string? message @ string? AND AND not if "Invalid arguments" abort then
    account @ not if "Account can't be blank" abort then
    message @ "" stringcmp not if "Message can't be blank" abort then
    channel @ "" stringcmp not if "Channel can't be blank" abort then
    cacheByAccount @ account @ array_getitem ?dup not if 0 exit then
    cacheByChannel @ channel @ array_getitem ?dup not if pop 0 exit then
    array_intersect
    ?dup if
        channel @ message @ data @ sendChannelMessageToDescrs
    then
; PUBLIC sendToAccount
 
( Sends a non-channel specific notification to a connection, for things like error messages )
: sendNotificationToDescr[ int:who str:message -- ]
    who @ dup int? AND not if "'Who' must be a non-zero descr." abort then
    message @ "" stringcmp not if "Message can't be blank" abort then
    { who @ }list "notice" message @ sendSystemMessageToDescrs    
; PUBLIC sendNotificationToDescr
 
(Separate so that it can be called by internal processes)
: handleChannelCallbacks[ int:triggeringDescr dbref:triggeringPlayer str:channel str:message any:data -- ]
    _startLogDebug
        "Handling message from " triggeringDescr @ intostr strcat "/" strcat triggeringPlayer @ unparseobj strcat " on MUCK: " strcat channel @ strcat ":" strcat message @ strcat
    _stopLogDebug
    depth var! startDepth
    "on" message @ strcat var! functionToCall var programToCall
    prog "@channels/" channel @ strcat "/" strcat array_get_propvals foreach (ProgramAsInt CreationDate)
        dup int? not if pop pop continue then
        swap atoi dbref dup program? not if pop pop continue then
        swap over timestamps 3 popn = not if pop pop continue then
        programToCall !
        programToCall @ functionToCall @ cancall? if
            channel @ message @ triggeringDescr @ triggeringPlayer @ data @ programToCall @ functionToCall @
            7 try call catch_detailed
                var! error
                _startLogWarning
                "ERROR whilst handling " channel @ strcat "." strcat message @ strcat ": " strcat error @ unparseCatchDetailedError strcat
                _stopLogWarning
                programToCall @ owner dup ok? if
                    "[MWI/Websocket] The program " programToCall @ unparseobj strcat " crashed whilst handling '" strcat message @ strcat "'. Error: " strcat error @ unparseCatchDetailedError strcat notify
                else pop then
            endcatch
            (Check for misbehaving functions)
            depth startDepth @ > if
                _startLogWarning
                debug_line_str
                "Stack left with " depth 2 - (One for debug line, one for this line) startDepth @ - intostr strcat " extra item(s) after processing message " strcat
                channel @ strcat "." strcat message @ strcat ". Debug line=" strcat swap strcat
                _stopLogWarning
                debug_line_str
                programToCall @ owner dup ok? if
                    dup "[MWI/Websocket] The program " programToCall @ unparseobj strcat " left items on the stack after handling '" strcat message @ strcat "'. Debug line follows: " strcat notify
                    swap notify
                else pop pop then
                depth startDepth @ - popn
            then
        else
            _startLogDebug
                "Couldn't find or call " programToCall @ unparseobj strcat ":" strcat functionToCall @ strcat " to handle an incoming packet (maybe intentional)" strcat
            _stopLogDebug
        then
    repeat
;
 
: addConnectionToChannel[ descr:who str:channel -- ]
    0 var! announceDescr 0 var! announcePlayer 0 var! announceAccount
    connections @ who @ array_getitem
    ?dup not if
        _startLogWarning
            "Attempt at unknown descr " who @ intostr strcat " trying to join channel: " strcat channel @ strcat "(Possibly okay if timely disconnect)" strcat
        _stopLogWarning
        exit
    then
 
    (Get player / account)
    dup var! connectionDetails
    dup "player" array_getitem ?dup not if #-1 then var! player
    "account" array_getitem var! account
    connectionDetails @ "channels" array_getitem
    dup channel @ array_findval not if
        channel @ swap array_appenditem
        connectionDetails @ "channels" array_setitem dup connectionDetails !
        connections @ who @ array_setitem connections !
        _startLogDebug
            "Descr " who @ intostr strcat " joined channel " strcat channel @ strcat
        _stopLogDebug
 
        (Check if we need to do announcements about player / account joining channel if they weren't on it previously)
        player @ ok? if
            player @ channel @ playerUsingChannel? not announcePlayer !
        then
        account @ if
            account @ channel @ accountUsingChannel? not announceAccount !
        then
 
        (Cache - ByChannel - Done last on adding to avoid influencing other checks)
        cacheByChannel @ channel @ array_getitem
        ?dup not if
            _startLogInfo
                "Channel now active: " channel @ strcat
            _stopLogInfo
            { }list
        then
        dup who @ array_findval not if
            who @ swap array_appenditem
            cacheByChannel @ channel @ array_setitem cacheByChannel !
            1 announceDescr !
        else
            pop
            "Descr " who @ intostr strcat " joined channel '" strcat channel @ strcat "' but was already in channel cache." strcat logerror
        then
        _startLogDebug
            "Cache - CacheByChannel is now: " cacheByChannel @ anythingToString strcat
        _stopLogDebug
 
    else pop then
 
    (Send announcements as required)
    (Do announcements to client first, since otherwise callbacks may cause messages to send out of order)
    { who @ }list "joinedChannel" channel @ sendSystemMessageToDescrs
    announceDescr @ if
        who @ channel @ "connected" systime sendToDescr
    then
    announcePlayer @ if
        who @ channel @ "playerConnected" systime sendToDescr
    then
    announceAccount @ if
        who @ channel @ "accountConnected" systime sendToDescr
    then
    (And then process callbacks)
    announceDescr @ if
        who @ player @ channel @ "connectionEnteredChannel" who @ handleChannelCallbacks
    then
    announcePlayer @ if
        who @ player @ channel @ "playerEnteredChannel" player @ handleChannelCallbacks
    then
    announceAccount @ if
        who @ player @ channel @ "accountEnteredChannel" account @ handleChannelCallbacks
    then
;
 
: removeConnectionFromChannel[ str:who str:channel -- ]
    0 var! announceDescr 0 var! announcePlayer 0 var! announceAccount
    connections @ who @ array_getitem
    ?dup not if
        _startLogWarning
            "Attempt at unknown descr " who @ intostr strcat " trying to leave channel: " strcat channel @ strcat "(Possibly okay if timely disconnect)" strcat
        _stopLogWarning
        exit
    then
 
    (Get player / account)
    dup var! connectionDetails
    dup "player" array_getitem ?dup not if #-1 then var! player
    "account" array_getitem var! account
    connectionDetails @ "channels" array_getitem
    dup channel @ array_findval ?dup if
        foreach nip array_delitem repeat
        connectionDetails @ "channels" array_setitem dup connectionDetails !
        connections @ who @ array_setitem connections !
        _startLogDebug
            "Descr " who @ intostr strcat " left channel " strcat channel @ strcat
        _stopLogDebug
 
        (Cache - ByChannel - Done first on removing to ensure it influences other checks)
        cacheByChannel @ channel @ array_getitem
        ?dup not if
            _startLogInfo
                "Channel was already inactive/empty whilst removing a connection: " channel @ strcat
            _stopLogInfo
            { }list
        then
        dup who @ array_findval ?dup if
            foreach nip array_delitem repeat
            ?dup if
                cacheByChannel @ channel @ array_setitem cacheByChannel !
            else
                cacheByChannel @ channel @ array_delitem cacheByChannel !
                _startLogInfo
                    "Channel shutting down (no more connections): " channel @ strcat
                _stopLogInfo
            then
            1 announceDescr !
        else
            pop
            "Descr " who @ intostr strcat " left channel '" strcat channel @ strcat "' but was't in the channel cache to remove." strcat logerror
        then
        _startLogDebug
            "Cache - CacheByChannel is now: " cacheByChannel @ anythingToString strcat
        _stopLogDebug
 
 
        (Check if we need to do announcements about player / account leaving channel if there's no remaining connections)
        player @ ok? if
            player @ channel @ playerUsingChannel? not announcePlayer !
        then
        account @ if
            account @ channel @ accountUsingChannel? not announceAccount !
        then
    else pop then
 
    (Send announcements as required)
    (Do announcements to client first, since otherwise callbacks may cause messages to send out of order)
    (We announce this in case the connection is just leaving/joining channels to change player/account)
    announcePlayer @ if
        who @ channel @ "playerDisconnected" systime sendToDescr
    then
    announceAccount @ if
        who @ channel @ "accountDisconnected" systime sendToDescr
    then
    announceDescr @ if
        who @ channel @ "disconnected" systime sendToDescr
    then
    (And then process callbacks)
    announcePlayer @ if
        who @ player @ channel @ "playerExitedChannel" player @ handleChannelCallbacks
    then
    announceAccount @ if
        who @ player @ channel @ "accountExitedChannel" account @ handleChannelCallbacks
    then
    announceDescr @ if
        who @ player @ channel @ "connectionExitedChannel" who @ handleChannelCallbacks
    then
;
 
 
: deleteConnection[ descr:who -- ]
    connections @ who @ array_getitem ?dup if
        var! connectionDetails
        _startLogDebug
            "Deleting descr " who @ intostr strcat ": " strcat connectionDetails @ anythingToString strcat
        _stopLogDebug
 
        (Remove from channels)
        connectionDetails @ "channels" array_getitem ?dup if
            foreach nip who @ swap removeConnectionFromChannel repeat
        then
 
        (Cache - ByPlayer - we don't check if it's okay as it might have been deleted)
        connectionDetails @ "player" array_getitem ?dup if
            var! player
            cacheByPlayer @ player @ int array_getitem ?dup if
                dup who @ array_findval ?dup if foreach nip array_delitem repeat then
                ?dup if
                    cacheByPlayer @ player @ int array_setitem cacheByPlayer !
                else
                    _startLogDebug
                        "Player's last descr disconnected: " player @ unparseobj strcat
                    _stopLogDebug
                    cacheByPlayer @ player @ int array_delitem cacheByPlayer !
 
                    _startLogDebug
                    "Doing @player disconnect notification for " player @ unparseobj strcat
                    _stopLogDebug
                    var propQueueEntry
                    prog "@player" array_get_propvals foreach swap propQueueEntry ! (S: prog)
                        dup string? if dup "$" instring if match else atoi then then dup dbref? not if dbref then
                        dup program? if
                            player @ 0 rot "wsDisconnect" 4 try enqueue pop catch "Failed to enqueue @player disconnect event '" propQueueEntry @ strcat "'." strcat logError endcatch
                        else pop (-prog) then
                    repeat
                then
                _startLogDebug
                    "Cache - CacheByPlayer is now: " cacheByPlayer @ anythingToString strcat
                _stopLogDebug
 
            then
        then
 
        (Cache - ByAccount - we don't check if it's okay as it might have been deleted)
        connectionDetails @ "account" array_getitem ?dup if
            var! account
            cacheByAccount @ account @ array_getitem ?dup if
                dup who @ array_findval ?dup if foreach nip array_delitem repeat then
                ?dup if
                    cacheByAccount @ account @ array_setitem cacheByAccount !
                else
                    _startLogDebug
                        "Account's last descr disconnected: " account @ intostr strcat
                    _stopLogDebug
                    cacheByAccount @ account @ array_delitem cacheByAccount !
                then
                _startLogDebug
                    "Cache - CacheByAccount is now: " cacheByAccount @ anythingToString strcat
                _stopLogDebug
            then
        then
 
        connections @ who @ array_delitem connections !
        (Cleanly disconnect descr, though this will trigger pidwatch for full clearing up.)
        who @ descr? if
            _startLogDebug
                "Disconnecting still connected descr " who @ intostr strcat
            _stopLogDebug
            { who @ }list systime_precise intostr webSocketSendCloseFrameToDescrs
            who @ descrboot
        then
    else
      "Attempt to delete a non-existing descr: " who @ intostr strcat logError
    then
;
 
: handleAuthentication[ descr:who str:authString -- ]
    authString @ " " split var! page var! token
    _startLogDebug
        "Received auth token '" token @ strcat "' for descr " strcat who @ intostr strcat
    _stopLogDebug
    connections @ who @ array_getitem ?dup not if
        _startLogWarning
            "Received an authentication request for descr not in the system: " who @ intostr strcat " (Possibly okay if timely disconnect)" strcat
        _stopLogWarning
        exit
    then
    var! connectionDetails
    prog "@tokens/" token @ strcat propdir? if
        systime_precise connectionDetails @ "acceptedAt" array_setitem connectionDetails !
        _startLogDebug
            "Accepted auth token '" token @ strcat "' for descr " strcat descr intostr strcat
        _stopLogDebug
 
        (Page)
        page @ ?dup if connectionDetails @ "page" array_setitem connectionDetails ! then
 
        (Account)
        prog "@tokens/" token @ strcat "/account" strcat getprop var! account
        account @ if
            account @ connectionDetails @ "account" array_setitem connectionDetails !
            _startLogDebug
                "Account for " who @ intostr strcat " set to: " strcat account @ intostr strcat
            _stopLogDebug
 
            (Cache - ByAccount)
            cacheByAccount @ account @ array_getitem ?dup not if
                { }list
                _startLogDebug
                "First instance of account " account @ intostr strcat " joined, via descr " strcat who @ intostr strcat
                _stopLogDebug
            then
            (S: DescrList)
            dup who @ array_findval if
                _startLogWarning
                    "Descr was already in byAccount cache when we came to add it: " who @ intostr strcat
                _stopLogWarning
            else
                who @ swap array_appenditem
                cacheByAccount @ account @ array_setitem cacheByAccount !
            then
            _startLogDebug
                "Cache - CacheByAccount is now: " cacheByAccount @ anythingToString strcat
            _stopLogDebug
        then
 
        (Player)
        prog "@tokens/" token @ strcat "/character" strcat getprop dup dbref? not if pop #-1 then var! player
        player @ player? if
            player @ connectionDetails @ "player" array_setitem connectionDetails !
            _startLogDebug
                "Player for " who @ intostr strcat " set to: " strcat player @ unparseobj intostr strcat
            _stopLogDebug
 
            (Cache - ByPlayer)
            cacheByPlayer @ player @ int array_getitem ?dup not if
                { }list
                _startLogDebug
                "First instance of player " player @ unparseobj intostr strcat " joined, via descr " strcat who @ intostr strcat
                _stopLogDebug
 
                _startLogDebug
                "Doing @player connect notification for " player @ unparseobj strcat
                _stopLogDebug
                prog "@player" array_get_propvals foreach swap var! propQueueEntry (S: prog)
                    dup string? if dup "$" instring if match else atoi then then dup dbref? not if dbref then
                    dup program? if
                        player @ 0 rot "wsConnect" 4 try enqueue pop catch "Failed to enqueue @player event '" propQueueEntry @ strcat "'." strcat logError endcatch
                    then
                repeat
            then
 
            (S: DescrList)
            dup who @ array_findval if
                _startLogWarning
                    "Descr was already in byPlayer cache when we came to add it: " who @ intostr strcat
                _stopLogWarning
            else
                who @ swap array_appenditem
                cacheByPlayer @ player @ int array_setitem cacheByPlayer !
            then
            _startLogDebug
                "Cache - CacheByPlayer is now: " cacheByPlayer @ anythingToString strcat
            _stopLogDebug
 
        then
 
        (Store)
        connectionDetails @ connections @ who @ array_setitem connections !
 
        _startLogDebug
            "Completed handshake for descr " who @ intostr strcat " as: " strcat connectionDetails @ anythingToString strcat
        _stopLogDebug
 
        (Notify connection)
        { who @ }list "accepted " who @ intostr strcat "," strcat player @ intostr strcat "," strcat player @ ok? if player @ name strcat then
        $ifdef trackBandwidth
            dup strlen 2 + (For \r\n) "websocket_out" trackBandwidthCounts
        $endif
        _startLogDebug
            "Informing descr " who @ intostr strcat " of accepted connection" strcat
        _stopLogDebug
        webSocketSendTextFrameToDescrs
 
        (Remove the used token)
        prog "@tokens/" token @ strcat "/" strcat removepropdir
    else
        _startLogWarning
            "Websocket for descr " who @ intostr strcat " gave an auth token that wasn't valid: " strcat token @ strcat
        _stopLogWarning
        _startLogDebug
            "Informing descr " who @ intostr strcat " of token rejection." strcat
        _stopLogDebug
        { who @ }list "invalidtoken" webSocketSendTextFrameToDescrs
    then
;
 
: handlePingResponse[ descr:who float:pingResponse -- ]
    connections @ who @ array_getitem
    ?dup if (Occasionally connections witnessed being deleted before a ping response is dealt with)
        var! connectionDetails
        systime_precise connectionDetails @ "lastPingIn" array_setitem connectionDetails !
        systime_precise connectionDetails @ "lastPingOut" array_getitem - connectionDetails @ "ping" array_setitem connectionDetails !
        connectionDetails @ connections @ who @ array_setitem connections !
    then
;
 
: handleIncomingSystemMessage[ descr:who str:message str:dataAsJson ] (Descr should already be confirmed to be valid.)
    who @ not message @ not OR if "handleIncomingSystemMessageFrom called with either descr or message blank." logError exit then
    _startLogDebug
        "[<<] " message @ strcat " " strcat who @ intostr strcat ": " strcat dataAsJson @ strcat
    _stopLogDebug
    $ifdef trackBandwidth
        message @ strlen "system_in" trackBandwidthCounts
    $endif
    dataAsJson @ if
        0 try
            dataAsJson @ decodeJson
        catch
            "Failed to decode JSON whilst handling System Message '" message @ strcat "':" strcat dataAsJson @ strcat logError
            exit
        endcatch
    else "" then var! data
    message @ case
        "joinChannels" stringcmp not when
            data @ dup string? if
                who @ swap addConnectionToChannel
            else
                foreach nip who @ swap addConnectionToChannel repeat
            then
        end
        default
            "ERROR: Unknown system message: " message @ strcat logError
        end
    endcase
;
 
: handleIncomingMessage[ descr:who str:channel str:message str:dataAsJson ] (Descr should already be confirmed to be valid.)
    who @ not channel @ not message @ not OR OR if "handleIncomingMessageFrom called with either descr, channel or message blank." logError exit then
    _startLogDebug
        "[<<][" channel @ strcat "." strcat message @ strcat "] " strcat who @ intostr strcat ": " strcat dataAsJson @ strcat
    _stopLogDebug
    $ifdef trackBandwidth
        message @ strlen "channel_" channel @ strcat "_in" strcat trackBandwidthCounts
    $endif
    dataAsJson @ if
        0 try
            dataAsJson @ decodeJson
        catch
            "Failed to decode JSON whilst handling Message '" message @ strcat "':" strcat dataAsJson @ strcat logError
            exit
        endcatch
    else "" then var! data
    who @ connections @ { who @ "player" }list array_nested_get ?dup not if #-1 then channel @ message @ data @ handleChannelCallbacks
;
 
: handleIncomingTextFrame[ descr:who str:payload ]
    connections @ who @ array_getitem ?dup if (Because it may have dropped elsewhere)
        var! connectionDetails
        connectionDetails @ "pid" array_getitem pid = if
            connectionDetails @ "acceptedAt" array_getitem if (Are we still in the handshake?)
                payload @ dup string? not if pop "" then dup strlen 3 > not if "Malformed (or non-string) payload from descr " who @ intostr strcat ": " strcat swap strcat logError then
                3 strcut var! data
                case
                    "MSG" stringcmp not when (Expected format is Channel, Message, Data)
                        who @ data @ dup "," instr strcut swap dup strlen ?dup if 1 - strcut pop then swap dup "," instr strcut swap dup strlen ?dup if 1 - strcut pop then swap handleIncomingMessage
                    end
                    "SYS" stringcmp not when (Expected format is Message,Data)
                        who @ data @ dup "," instr strcut swap dup strlen ?dup if 1 - strcut pop then swap handleIncomingSystemMessage
                    end
                    default
                        "ERROR: Unrecognized text frame from descr " descr intostr strcat ": " strcat swap strcat logError
                    end
                endcase
            else (Still in handshake - only thing we're expecting is 'auth <token>')
                payload @ "auth " instring 1 = if
                    who @ payload @ 5 strcut nip handleAuthentication
                else
                    _startLogWarning
                        "Websocket for descr " descr intostr strcat " sent the following text instead of the expected auth request: " strcat payload @ strcat
                    _stopLogWarning
                then
            then
        else
            _startLogWarning
                "Websocket for descr " descr intostr strcat " received a text frame from a PID that doesn't match the one in its connection details: " strcat payload @ strcat
            _stopLogWarning
        then
    else
        _startLogWarning
            "Received a text frame from descr " descr intostr strcat " but there's no connection details for them. Possibly okay if they were disconnecting at the time."
        _stopLogWarning
    then
;
 
: attemptToProcessWebsocketMessage[ descr:who array:buffer -- bufferRemaining ]
    buffer @ array_count var! startingBufferLength
    buffer @ websocketGetFrameFromIncomingBuffer (Returns opCode payLoad remainingBuffer)
    buffer ! var! payLoad var! opCode
    opCode @ not if buffer @ exit then (Nothing found, persumably because the buffer doesn't have enough to get a message from yet)
    $ifdef trackBandwidth
        startingBufferLength @ buffer @ array_count -
        "websocket_in" trackBandwidthCounts
    $endif
    opCode @ case
        136 = when
            _startLogDebug
                "Websocket Close request. Terminating pid."
            _stopLogDebug
            payload @ dup webSocketCreateCloseFrameHeader swap
            $ifdef trackBandwidth
                over array_count over strlen + 2 + "websocket_out" trackBandwidthCounts
            $endif
            who @ rot rot webSocketSendFrame
            pid kill pop (Prevent further processing, pidwatch will react to the disconnect)
        end
        137 = when (Ping request, need to reply with pong)
            _startLogDebug
                "Websocket Ping request received."
            _stopLogDebug
            payload @ dup webSocketCreatePongFrameHeader swap
            $ifdef trackBandwidth
                over array_count over strlen + 2 + "websocket_out" trackBandwidthCounts
            $endif
            who rot rot webSocketSendFrame
        end
        138 = when (Pong reply to a ping we sent - the packet should be the systime_precise we sent it at)
            payload @ strtof ?dup if
                _startLogDebug
                    "Websocket Poing response received."
                _stopLogDebug
                who @ swap handlePingResponse
            then
            { }list exit
        end
        129 = when (Text frame, an actual message!)
            who @ payload @ handleIncomingTextFrame
        end
        default (This shouldn't happen as we previously check the opcode is one we support)
            "Websocket code didn't know what to do with an opcode: " opCode @ itoh strcat logError
        end
    endcase
    (In case there were multiple, we need to try to process another)
    buffer @ dup if who @ swap attemptToProcessWebsocketMessage then
;
 
: clientProcess[ descr:who -- ]
    _startLogDebug
        "Starting client process for " who @ intostr strcat
    _stopLogDebug
    var event var eventArguments
    1 var! keepGoing
    { }list var! buffer
    serverProcess @ "registerClientPID" { pid descr }list event_send (So daemon can handle disconnects)
    depth popn
    begin keepGoing @ descr descr? AND while
        background event_wait (debug_line) event ! eventArguments !
        event @ case
            "HTTP.disconnect." instring when
                _startLogDebug
                    "Client process received disconnect event."
                _stopLogDebug
                0 keepGoing !
            end
            "HTTP.input_raw" stringcmp not when (Possible websocket data!)
                buffer @
                dup array_count eventArguments @ array_insertrange
                who @ swap attemptToProcessWebsocketMessage
                buffer !
            end
            "HTTP.input" stringcmp not when (Not used, just need to be aware of it)
            end
            default pop
            "ERROR: Unhandled client event - " event @ strcat logError
            end
        endcase
        depth if
            _startLogWarning
                debug_line_str depth 1 - "Client stack for " descr intostr strcat " had " strcat swap intostr strcat " item(s). Debug_line follows: " strcat swap strcat
            _stopLogWarning
        then
        depth popn
    repeat
    _startLogDebug
        "Ending client process for " who @ intostr strcat
    _stopLogDebug
;
 
: handleClientConnecting
 descr descr? not if exit then (Connections can be dropped immediately)
 prog "disabled" getpropstr "Y" instring if
  descr "HTTP/1.1 503 Service Unavailable\r\n" descrnotify
        descr "\r\n" descrnotify (This should only send one \r\n)
        exit
 then
 systime var! connectedAt
 event_wait pop var! rawWebData
 
 (Ensure correct protocol version)
 rawWebData @ { "data" "CGIdata" "protocolVersion" 0 }list array_nested_get ?dup not if "" then
 protocolVersion stringcmp if
  _startLogWarning
   "Rejected new WebSocket connection from descr " descr intostr strcat " due to it being the wrong protocol version" strcat
  _stopLogWarning
  descr "HTTP/1.1 426 Upgrade Required\r\n" descrnotify
  descr "\r\n" descrnotify (This should only send one \r\n)
  exit
 then
 
 (At this point we're definitely trying to accept a websocket)
 _startLogDebug
  "New connection from descr " descr intostr strcat
 _stopLogDebug
 
 rawWebData @ { "data" "HeaderData" "Sec-WebSocket-Key" }list array_nested_get ?dup not if
  _startLogWarning
   "Rejected new WebSocket connection from descr " descr intostr strcat " due to it missing the websocket key header. " strcat
  _stopLogWarning
  descr "HTTP/1.1 400 Bad Request\r\n" descrnotify descr "\r\n" descrnotify exit
 then
 webSocketCreateAcceptKey var! acceptKey
 {
  "HTTP/1.1 101 Switching Protocols"
  "Server: " version strcat
  "Connection: Upgrade"
  "Upgrade: websocket"
  allowCrossDomain if "Access-Control-Allow-Origin: *" then
  "Sec-WebSocket-Accept: " acceptKey @ strcat
  "Sec-WebSocket-Protocol: mwi"
 }list "\r\n" array_join
 $ifdef trackBandwidth
  dup strlen 4 + (2 \r\n's are going to get sent) "websocket_out" trackBandwidthCounts
 $endif
 descr swap descrnotify
 descr "\r\n" descrnotify (Since descrnotify trims excess \r\n's this will only output one)
 
    { descr }list "welcome"
 $ifdef trackBandwidth
  dup strlen 2 + (For \r\n) "websocket_out" trackBandwidthCounts
 $endif
    webSocketSendTextFrameToDescrs
 
 {
  "descr" descr
  "pid" pid
  "channels" { }list
  "properties" { }dict
  "connectedAt" connectedAt @
 }dict
    $ifdef is_dev
        dup arrayDump
    $endif
    connections @ descr array_setitem connections !
 
    descr clientProcess
 
 _startLogDebug
  "Client connection on " descr intostr strcat " ran for " strcat systime connectedAt @ - intostr strcat "s." strcat
 _stopLogDebug
;
 
: serverDaemon
    var eventArguments
    var eventName
    var toPing
    var connection
    var connectionDetails
    { }dict var! clientPIDs (In the form pid:descr)
    "Server Process started on PID " pid intostr strcat "." strcat logNotice
    prog "@lastUptime" systime setprop
    background 1 "heartbeat" timer_start
    begin 1 while
        event_wait eventName ! eventArguments !
        eventName @ case
            "TIMER.heartbeat" stringcmp not when
                serverProcess @ pid = not if "ServerProcess shutting down since we don't match the expected pid of " serverProcess @ intostr strcat logError exit then
                heartbeatTime "heartbeat" timer_start
                { }list toPing !
                connections @ foreach
                    connectionDetails ! connection !
                    connectionDetails @ "pid" array_getitem ispid? not if
                        _startLogDebug
                            "Disconnecting " connectionDetails @ connectionDetailsToString strcat " due to PID being dead." strcat
                        _stopLogDebug
                        connection @ deleteConnection continue
                    then
                    connectionDetails @ "descr" array_getitem descr? not if
                        _startLogDebug
                            "Disconnecting " connectionDetails @ connectionDetailsToString strcat " due to descr being disconnected." strcat
                        _stopLogDebug
                        connection @ deleteConnection continue
                    then
                    connectionDetails @ "acceptedAt" array_getitem not if
                        (Not finished handshake, so we don't continue to ping but do instead check they're not a stalled connection)
                        connectionDetails @ "connectedAt" array_getitem systime swap - maxAuthTime > if
                            _startLogDebug
                                "Disconnecting " connectionDetails @ connectionDetailsToString strcat " due to them taking too long to authenticate." strcat
                            _stopLogDebug
                            connection @ deleteConnection continue
                        then
                        continue
                    then
                    (Ping related)
                    connectionDetails @ "lastPingOut" array_getitem connectionDetails @ "lastPingIn" array_getitem
                    over over > if (If lastPingOut is higher we're expecting a response. On initial connect both are 0)
                        pop systime_precise swap - maxPingTime > if
                            _startLogDebug
                                "Disconnecting " connectionDetails @ connectionDetailsToString strcat " due to no response to ping." strcat
                            _stopLogDebug
                            connection @ deleteConnection continue
                        then
                    else (Otherwise we're eligible to be pinged)
                        nip (keep last in) connectionDetails @ "connectedAt" array_getitem math.max
                        systime_precise swap - (Time since last ping or initial connection)
                        pingFrequency - 0 > if
                            1 connectionDetails @ "descr" array_getitem ?dup if toPing @ array_appenditem toPing ! then
                        else 0 then
                        if (update lastPingOut record)
                            systime_precise connectionDetails @ "lastPingOut" array_setitem
                            dup connectionDetails ! connections @ connection @ array_setitem connections !
                        then
                    then
                repeat
                _startLogDebug
                    "Heartbeat. Connections: " connections @ array_count intostr strcat
                    ", Outgoing Pings: " strcat toPing @ array_count intostr strcat
                _stopLogDebug
                toPing @ ?dup if
                    systime_precise intostr
                    $ifdef trackBandwidth
                        over array_count over strlen 2 + * "websocket_out" trackBandwidthCounts
                    $endif
                    webSocketSendPingFrameToDescrs
                then
            end
            "USER.registerClientPID" stringcmp not when (Tells us to watch this PID - called with [pid, descr])
                eventArguments @ "data" array_getitem dup 1 array_getitem swap 0 array_getitem (Now S: descr PID)
                dup watchPID
                over clientPIDs @ 3 pick array_setitem clientPIDs !
                _startLogDebug
                    "Server process notified of PID " over intostr strcat " for descr " strcat 3 pick intostr strcat ", now monitoring " strcat clientPIDs @ array_count intostr strcat " PID(s)." strcat
                _stopLogDebug
                pop pop
            end
            "PROC.EXIT." instring when
                eventName @ 10 strcut nip atoi
                clientPIDs @ over array_getitem ?dup if (S: PID descr)
                    clientPIDs @ 3 pick array_delitem clientPIDs !
                    _startLogDebug
                        "Server process notified of disconnect on PID " 3 pick intostr strcat ", now monitoring " strcat clientPIDs @ array_count intostr strcat " PID(s)." strcat
                    _stopLogDebug
                    nip (S: descr)
                    connections @ over array_getitem if deleteConnection else pop then
                else
                    _startLogWarning
                        "Server process notified of disconnect on an unmonitored PID - " over intostr strcat
                    _stopLogWarning
                    pop
                then
            end
            default
                "ERROR: Heartbeat thread got an unrecognized event: " swap strcat logError
            end
        endcase
        depth ?dup if "Heartbeat's stack had " swap intostr strcat " item(s). Debug_line follows:" strcat logError debug_line_str logError depth popn then
    repeat
;
 
(Provides a list of channels and some details about them. Also doubles as general status screen.)
: cmdChannels
    " " .tell
    "^CYAN^Websocket Channel Breakdown" .tell
    "^WHITE^Channel                  All Ply Acc"
    $ifdef trackbandwidth
    "         In(Kb)        Out(Kb)" strcat
    $endif
    .tell
    { }list (Going to build a list based upon config and active channels)
    cacheByChannel @ foreach pop swap array_appenditem repeat
    prog "@channels/" array_get_propdirs foreach nip swap array_appenditem repeat
    1 array_nunion
    var channel
    foreach nip channel !
        channel @ 24 left
        " " strcat
        cacheByChannel @ channel @ array_getitem dup if array_count then intostr 3 right strcat
        " " strcat
        channel @ playersOnChannel array_count intostr 3 right strcat
        " " strcat
        channel @ accountsOnChannel array_count intostr 3 right strcat
        $ifdef trackbandwidth
            "^YELLOW^ " strcat
            0.0 bandwidthCounts @ "channel_" channel @ strcat "_in" strcat array_getitem ?dup if foreach nip + repeat 1024.0 / 1 round then
            comma dup "." instring not if "  " strcat then "K" strcat 14 right strcat
            " " strcat
            0.0 bandwidthCounts @ "channel_" channel @ strcat "_out" strcat array_getitem ?dup if foreach nip + repeat 1024.0 / 1 round then
            comma dup "." instring not if "  " strcat then "K" strcat 14 right strcat
        $endif
        .tell
    repeat
 
    (Total row)
    "^CYAN^----------------------------------------------------------------------" .tell
    "" 24 left "^CYAN^" swap strcat
    " " strcat
    connections @ array_count intostr 3 right strcat
    " " strcat
    cacheByPlayer @ array_count intostr 3 right strcat
    " " strcat
    cacheByAccount @ array_count intostr 3 right strcat
    $ifdef trackbandwidth
        "^YELLOW^ " strcat
        0.0 bandwidthCounts @ "websocket_out" array_getitem ?dup if foreach nip + repeat 1024.0 / 1 round then
            comma dup "." instring not if "  " strcat then "K" strcat 14 right strcat
        " " strcat
        0.0 bandwidthCounts @ "websocket_in" array_getitem ?dup if foreach nip + repeat 1024.0 / 1 round then
        comma dup "." instring not if "  " strcat then "K" strcat 14 right strcat
    $endif
    .tell
 
    "All - All connections, Ply - Players, Acc - Accounts" .tell
;
 
(Debug-dumps of either a single descr or every descr a player owns.)
: cmdDump[ str:target -- ]
   target @ ?dup if
      dup pmatch dup ok? if
         "Dumping all descrs owned by " over .color-unparseobj strcat .tell
         connections @ swap int array_getitem ?dup if
            foreach
               "--Descr " rot 1 + intostr strcat ": ^WHITE^" strcat over strcat .tell
               connections @ swap array_getitem ?dup if arrayDump else "Couldn't find this connection - hopefully it just disconnected else something is very wrong." .tell then
            repeat
            "--Finished." .tell
         else
            "Couldn't find any descrs to show." .tell
         then
      else pop
         connections @ swap atoi array_getitem ?dup if
            "Dumping single connection details.." .tell
            arrayDump
         else
            "That doesn't seem to be a valid descr presently connected." .tell
         then
      then
   else
      "No target specified. Provide either a descr or a player." .tell
   then
;
 
(Provides a list of connections and some details about them)
: cmdConnections ( -- )
    "^CYAN^Websocket Connections" .tell
 
    prog "@lastuptime" getpropval
    "^CYAN^Last started (uptime): ^YELLOW^" "%a, %d %b %Y %H:%M:%S" 3 pick timefmt strcat " (" strcat swap systime swap - timeSpanToString strip strcat " ago)" strcat .tell
 
    "^WHITE^Descr  Player             Time PID         Ping Chn Page" .tell
    connections @ ?dup if
        foreach (S: session info)
            over intostr 6 right " " strcat
            over "player" array_getitem dup ok? if name "^GREEN^" swap else pop "<Unset>" "^BROWN^" swap then 16 left strcat strcat " ^CYAN^" strcat
            over "connectedAt" array_getitem dup int? not if pop systime then systime swap - timeSpanToSixCharacters strcat " ^WHITE^" strcat
            over "pid" array_getitem intostr 8 left strcat " " strcat
            over "ping" array_getitem ?dup if 1000.0 * int intostr "ms" strcat else "-" then 7 right strcat " " strcat
            over "channels" array_getitem array_count intostr 3 right strcat " " strcat
            (Use page to show if they're still connecting)
            over "acceptedAt" array_getitem if
                over "page" array_getitem ?dup not if "Unknown" then strcat
            else
                "^BROWN^[Connecting...]" strcat
            then
            .tell pop pop
        repeat
        "Chn = Amount of channels subscribed to." .tell
    else
        "^BLUE^No connections at present." .tell
    then
;
 
: cmdConfig
   var channel
   "^CYAN^Websocket Channel Configurations" .tell
   prog "@channels/" array_get_propdirs foreach nip channel !
      "Channel: " channel @ strcat .tell
      prog "/@channels/" channel @ strcat "/" strcat array_get_propvals ?dup if
         foreach pop
            dup atoi dbref
            dup ok? if nip .color-unparseobj else pop "Invalid reference: " swap strcat then "  " swap strcat .tell
         repeat
      else "^BLUE^None!" .tell then
   repeat
;
 
: main
    ensureInit
    command @ "Queued event." stringcmp not if (Queued startup)
        dup "Startup" stringcmp not if exit then (The ensureinit command will trigger the actual startup as well as ensure structures are ready)
        dup "ServerStartup" stringcmp not if
            pop serverDaemon (This should run indefinitely)
            "Server Process somehow stoped." logError
        then
        exit
    then
    (Is this a connection?)
    command @ "(WWW)" stringcmp not if pop handleClientConnecting exit then
 
    me @ mlevel 5 > not if "Wiz-only command." .tell exit then
 
    dup "#channel" instring 1 = over "#status" instring 1 = OR if pop cmdChannels exit then
    dup "#dump" instring 1 = if 5 strcut nip strip cmdDump exit then
    dup "#who" instring 1 = if 4 strcut nip strip cmdConnections exit then
    dup "#sessions" instring 1 = if 9 strcut nip strip cmdConnections exit then
    dup "#config" instring 1 = if pop cmdConfig exit then
 
    dup "#reset" stringcmp not if
        "[!] Reset triggered: " me @ unparseobj strcat logNotice
        (Need to kill old PIDs)
        prog getPids foreach nip pid over = if pop else kill pop then repeat
        0 serverProcess ! 0 connections ! ensureInit
        "Server reset.." .tell
        exit
    then
 
    dup "#kill" instring 1 = if
        "[!] Kill signal received." logNotice
        "Service will shut down. This command is largely just here for testing - the system will start up again if something requests it." .tell
        0 serverProcess !
        exit
    then
 
    dup "#debug" instring 1 = if
  6 strcut nip strip
  dup "" stringcmp not if
   "Valid values are: off, warning, info, all" .tell
   exit
  then
  0 "" (Level String)
  3 pick "off"      stringcmp not if pop pop 0                 "Off (Core notices and errors only)" then
  3 pick "warning"  stringcmp not if pop pop debugLevelWarning "Warning" then
  3 pick "info"     stringcmp not if pop pop debugLevelInfo    "Info" then
  3 pick "all"      stringcmp not if pop pop debugLevelAll     "All (Super Spammy)" then
  rot pop dup if
   "Debug level set to: " swap strcat dup logNotice .tell
   debugLevel ! prog "debugLevel" debugLevel @ setprop
  else
   pop pop
   "Didn't recognize that debug level! Valid levels are: off, warning, info, all" .tell
  then
  exit
 then
 
   dup "#addChannel" instring 1 = if
      11 strcut nip strip
      "=" explode_array
      dup array_count 2 = not if "Invalid arguments, use in the form '" command @ strcat " #addChannel <channel>=<program>'" strcat .tell exit then
      dup 0 array_getitem swap 1 array_getitem (Channel Program)
      over "" stringcmp not if "No channel specified! This can't be an empty string." .tell exit then
      dup match dup ok? not if pop "Couldn't match: " swap strcat .tell exit else nip then
      dup program? not if .color-unparseobj " isn't a program!" strcat .tell exit then
      prog "/@channels/" 4 pick strcat "/" strcat 3 pick intostr strcat 3 pick timeStamps 3 popn setprop
      "Added the program '" swap .color-unparseobj strcat "' to receive messages on channel '" strcat swap strcat "'." strcat .tell
      exit
   then
 
   dup "#rmmChannel" instring 1 = if
      11 strcut nip strip
      "=" explode_array
      dup array_count 2 = not if "Invalid arguments, use in the form '" command @ strcat " #rmmChannel <channel>=<program>'" strcat .tell exit then
      dup 0 array_getitem swap 1 array_getitem (Channel Program)
      over "" stringcmp not if "No channel specified! This can't be an empty string." .tell exit then
      match (Because we may be asked to remove garbage/invalid references)
      prog "/@channels/" 4 pick strcat "/" strcat 3 pick intostr strcat
      over over getprop not if "There was no entry to remove." .tell exit then
      remove_prop
      "Removed the program '" swap .color-unparseobj strcat "' from the channel '" strcat swap strcat "'." strcat .tell
      exit
   then
 
 
    dup "#help" instring 1 = over "" stringcmp not OR if pop
        "^WHITE^MuckWebInterface Websockets v" _version strcat .tell
        "Detailed information on the program is contained with the comments." .tell
        "Commands available:" .tell
        "  #who           -- List of present connections." .tell
        "  #channels      -- List of present channels and general status." .tell
        "  #config        -- Present channel configuration." .tell
        "  #debug <level> -- Sets the debug to the given level." .tell
        "  #dump <target> -- If given a descr prints its details, if given a player name dumps all descrs owned by them." .tell
        "  #reset         -- Reset the system (will disconnect everyone.)" .tell
        " " .tell
        "The following two commands will register or unregister a program to receive events on the given channel:" .tell
        "  #addchannel <channel>=<program>" .tell
        "  #rmmchannel <channel>=<program>" .tell
        exit
    then
 
    "Didn't recognize that option, use #help to get a list of available commands." .tell
;
.
c
q