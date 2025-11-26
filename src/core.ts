import Connection from "./connection";
import ConnectionFaker from "./connection-faker";
import ConnectionWebSocket from "./connection-websocket";
import Channel from "./channel";
import ChannelInterface from "./channel-interface";
import {
    InitialMode,
    ConnectionState
} from "./defs";
import type {
    ConnectionErrorCallback,
    ConnectionOptions,
    ConnectionStateChangedCallback,
    PlayerChangedCallback,
    SystemNotificationCallback
} from "./defs";

/**
 * Message in the form MSG<Channel>,<Message>,<Data>
 */
const msgRegExp: RegExp = /MSG(.*?),(.*?),(.*)/;

/**
 * System message in the form SYS<Message>,<Data>
 */
const sysRegExp: RegExp = /SYS(.*?),(.*)/;

/**
 * Present mode we're operating in.
 */
let mode: string = InitialMode;

/**
 * Whether we can use local storage. Set in initialization.
 */
let localStorageAvailable: boolean = false;

/**
 * Present connection status
 */
let connectionState: ConnectionState = ConnectionState.disconnected;

/**
 * Present player's database reference or null
 */
let playerDbref: number | null = null;

/**
 * Present player's name or null
 */
let playerName: string | null = null;

/**
 * Callbacks to be notified when the player gets changed
 */
let playerChangedCallbacks: PlayerChangedCallback[] = [];

/**
 * Callbacks to be notified when the connection status gets changed
 */
let connectionStateChangedCallbacks: ConnectionStateChangedCallback[] = [];

/**
 * Callbacks to be notified when something goes wrong
 */
let connectionErrorCallbacks: ConnectionErrorCallback[] = [];

let systemNotificationCallbacks: SystemNotificationCallback[] = [];
/**
 * Timeout mostly used to ensure we don't have multiple connection attempts
 */
let queuedConnectionTimeout: ReturnType<typeof setTimeout> | null = null;

/**
 * Number of failed attempts, so we can slow down on the retries over time
 */
let connectionFailures: number = 0;

/**
 * Whether debug mode is on
 */
let debug: boolean = false;

/**
 * Our presently configured connection object. Only set if active.
 */
let connection: Connection | null = null;

/**
 * A lookup list of registered channels
 */
const channels: { [channelName: string]: Channel } = {};

/**
 * Default websocket url to use unless it's overridden
 */
let defaultWebsocketUrl: string = '';

/**
 * Default authentication url to use unless it's overridden.
 */
let defaultAuthenticationUrl: string = '';

/**
 * Utility function to format errors
 */
export const logError = (message: string): void => {
    console.log("Mwi-Websocket ERROR: " + message);
}

/**
 * Utility function to format debug lines and omit if disabled
 */
export const logDebug = (message: string): void => {
    if (debug) console.log("Mwi-Websocket DEBUG: " + message);
}

/**
 * Enables or disables printing debug information into the console
 */
export const setDebug = (trueOrFalse: boolean): void => {
    if (trueOrFalse) {
        debug = true;
        console.log("Console logging enabled.");
    } else {
        debug = false;
        console.log("Console logging disabled.");
    }
    if (!localStorageAvailable) {
        logError("Can't save debug preference - local storage is not available.");
        return;
    }
    if (debug)
        localStorage.setItem('mwiWebsocket-debug', 'y');
    else
        localStorage.removeItem('mwiWebsocket-debug');
}

/**
 * Called by the connection. If the fault wasn't fatal, a reconnect is queued
 */
export const handleConnectionFailure = (errorMessage: string, fatal: boolean = false): void => {
    clearConnectionTimeout(); // If the connection failed, it definitely isn't pending
    connectionFailures++;
    dispatchError(errorMessage);
    if (!connection) return; // Connection has already stopped
    // Start again unless the problem was fatal
    if (fatal) {
        logError("Fatal Connection Error - cancelling any further attempt to connect.");
        stop();
    } else {
        queueConnection()
    }
}

/**
 * Called by the connection. Stops any queued connections and resets failed count
 * Does not handle setting player-dbref/player-name since that can vary on connection
 */
export const handleConnectionSuccess = () => {
    logDebug("Resetting failed count due to success.");
    clearConnectionTimeout();
    connectionFailures = 0;
}

/**
 * Attempts to parse the given JSON
 */
const tryToParseJson = (json: string | null): any => {
    if (!json) return null;
    let parsedJson = null;
    try {
        parsedJson = JSON.parse(json);
    } catch {
        logError("Couldn't parse the following JSON: " + json);
    }
    return parsedJson;
}

/**
 * Used by the present connection to pass back a raw string for processing
 */
export const receivedStringFromConnection = (stringReceived: string): void => {
    if (stringReceived.indexOf('MSG') === 0) {
        let channel: string, message: string, data: any;
        try {
            let dataAsJson: string | null;
            [, channel, message, dataAsJson] = stringReceived.match(msgRegExp) || [null, '', '', null];
            data = tryToParseJson(dataAsJson);
        } catch (e) {
            logError("Failed to parse string as incoming channel message: " + stringReceived);
            console.log(e);
            return;
        }
        if (message === '') {
            logError("Incoming channel message had an empty message: " + stringReceived);
            return;
        }
        if (debug) console.log("[ << " + channel + "." + message + "] ", data);
        receivedChannelMessage(channel, message, data);
        return;
    }
    if (stringReceived.indexOf('SYS') === 0) {
        let message: string, data: any;
        try {
            let dataAsJson: string | null;
            [, message, dataAsJson] = stringReceived.match(sysRegExp) || [null, '', null];
            data = tryToParseJson(dataAsJson);
        } catch (e) {
            logError("Failed to parse string as incoming system message: " + stringReceived);
            return;
        }
        if (message === '') {
            logError("Incoming system message had an empty message: " + stringReceived);
            return;
        }
        if (debug) console.log("[ << " + message + "] ", data);
        receivedSystemMessage(message, data);
        return;
    }
    logError("Don't know what to do with the string: " + stringReceived);
};

export const sendChannelMessage = (channel: string, message: string, data: any): void => {
    if (!connection) {
        logDebug(`Attempt to send a channel message whilst not connected: ${channel}:${message}`);
        return;
    }
    if (debug) console.log("[ >> " + channel + "." + message + "] ", data);
    let parsedData: string = connection.encodeDataForConnection(data);
    let parsedMessage: string = ["MSG", channel, ',', message, ',', parsedData].join('');
    connection.sendString(parsedMessage);
}

const sendSystemMessage = (message: string, data: any): void => {
    if (!connection) {
        logDebug(`Attempt to send a system message whilst not connected: ${message}`);
        return;
    }
    if (debug) console.log("[ >> " + message + "] ", data);
    let parsedData: string = connection.encodeDataForConnection(data);
    let parsedMessage: string = ["SYS", message, ',', parsedData].join('');
    connection.sendString(parsedMessage);
}

const receivedSystemMessage = (message: string, data: any): void => {
    switch (message) {
        case 'joinedChannel':
            // Let the channel know it's joined, so it can process buffered items
            const channel = channels[data];
            if (channel) channel.channelConnected();
            else logError("Muck acknowledged joining a channel we weren't aware of! Channel: " + data);
            break;
        case 'notice':
            for (const callback of connectionErrorCallbacks) {
                try {
                    callback(data);
                } catch (e) {
                }
            }
            break;
        case 'test':
            logDebug("Mwi-Websocket Test message received. Data=" + data);
            break;
        case 'ping': //This is actually http only, websockets do it at a lower level
            sendSystemMessage('pong', data);
            break;
        default:
            logError("Unrecognized system message received: " + message);
    }
}

const receivedChannelMessage = (channelName: string, message: string, data: any): void => {
    const channel = channels[channelName];
    if (channel) channel.receiveMessage(message, data);
    else
        logError("Received message on channel we're not aware of! Channel = " + channelName);
}

/**
 * Utility function to unset any current connection timeout
 */
const clearConnectionTimeout = () => {
    if (queuedConnectionTimeout) {
        logDebug("Cancelling queued connection timeout");
        clearTimeout(queuedConnectionTimeout);
        queuedConnectionTimeout = null;
    }
}

/**
 * Used as entry point for both new connections and reconnects
 */
const queueConnection = () => {
    if (queuedConnectionTimeout) return; // Already queued
    if (!connection) {
        logError("Attempt to queue the next connection when no connection has been configured.");
        throw "Attempt to queue the next connection when no connection has been configured.";
    }
    let delay: number = Math.min(connectionFailures * 100, 60000);
    queuedConnectionTimeout = setTimeout(connect, delay);
    updateAndDispatchStatus(ConnectionState.queued);
    updateAndDispatchPlayer(null, null);
    for (const channelName in channels) {
        const channel = channels[channelName];
        if (channel) channel.channelDisconnected();
    }
    logDebug(`Connection attempt queued with a delay of ${delay}ms.`);
}

/**
 * Start a connection attempt on the currently configured connection
 * This should only be run through queueConnection
 */
const connect = () => {
    if (!connection) {
        logError("Attempt to start a connection when it hasn't been configured yet.");
        throw "Attempt to start a connection when it hasn't been configured yet."
    }
    logDebug("Starting connection.");
    updateAndDispatchStatus(ConnectionState.connecting);
    connection.connect();
}

/**
 * Create and start a new connection which the library will attempt to keep open.
 */
export const start = (options: ConnectionOptions = {}): void => {
    if (connection) {
        logDebug("Attempt to start the connection when it's already been started.");
        return;
    }
    if (!(options.websocketUrl)) options.websocketUrl = defaultWebsocketUrl;
    if (!(options.authenticationUrl)) options.authenticationUrl = defaultAuthenticationUrl;

    if (mode === 'test' || options.useFaker)
        connection = new ConnectionFaker(options);
    else
        connection = new ConnectionWebSocket(options)
    queueConnection();
}

/**
 * Shut down and delete the connection completely. Will stop any further attempts to connect.
 */
export const stop = () => {
    if (!connection) {
        logDebug("Attempt to stop a connection when there isn't one.");
        return;
    }
    logDebug("Stopping connection.");
    clearConnectionTimeout();
    updateAndDispatchStatus(ConnectionState.disconnected);
    updateAndDispatchPlayer(null, null);
    for (const channelName in channels) {
        const channel = channels[channelName];
        //Channels will be re-joined if required, but we need to let them know to buffer until the muck acknowledges them.
        if (channel) channel.channelDisconnected()
    }
    connection.disconnect();
    connection = null;
}

/**
 * Returns a channel interface to talk to a channel, joining it if required.
 */
export const channel = (channelName: string): ChannelInterface => {
    if (channelName in channels) {
        const channel = channels[channelName];
        if (channel) return channel.interface;
    }
    logDebug('New Channel - ' + channelName);
    let newChannel: Channel = new Channel(channelName);
    channels[channelName] = newChannel;
    //Only send join request if we have a connection, as the connection process will also handle joins
    if (connectionState === ConnectionState.connected) sendSystemMessage('joinChannels', channelName);
    return newChannel.interface;
}

//region Event Processing

/**
 * Register a callback to be notified when the active player changes
 * Will be called with (playerDbref, playerName).
 */
export const onPlayerChanged = (callback: PlayerChangedCallback): void => {
    playerChangedCallbacks.push(callback);
}

/**
 * Register a callback to be notified when there's an error
 */
export const onError = (callback: ConnectionErrorCallback): void => {
    connectionErrorCallbacks.push(callback);
}

/**
 * Register a callback to be notified when there's a system notification
 */
export const onSystemNotification = (callback: SystemNotificationCallback): void => {
    systemNotificationCallbacks.push(callback);
}

/**
 * Registers a new callback that'll be informed of changes to the connection status.
 * The passed callback will immediately be called with the present status too.
 */
export const onConnectionStateChanged = (callback: ConnectionStateChangedCallback): void => {
    connectionStateChangedCallbacks.push(callback);
    callback(connectionState);
}

/**
 * Called by present connection
 */
export const updateAndDispatchPlayer = (newDbref: number | null, newName: string | null): void => {
    if (playerDbref === newDbref && playerName === newName) return;
    playerDbref = newDbref;
    playerName = newName;
    logDebug("Player changed: " + newName + '(' + newDbref + ')');
    for (const callback of playerChangedCallbacks) {
        try {
            callback(newDbref, newName);
        } catch (e) {
        }
    }
}

/**
 * Called by present connection
 */
export const updateAndDispatchStatus = (newStatus: ConnectionState): void => {
    if (connectionState === newStatus) return;
    logDebug('Connection status changed to ' + newStatus + ' (from ' + connectionState + ')');
    connectionState = newStatus;

    // Maybe need to send channel join requests?
    if (newStatus === ConnectionState.connected) {
        let channelsToJoin = [];
        for (const channelName in channels) {
            const channel = channels[channelName];
            if (channel && !channel.isChannelJoined()) channelsToJoin.push(channel);
        }
        if (channelsToJoin.length > 0) sendSystemMessage('joinChannels', channelsToJoin);
    }

    //Callbacks
    for (const callback of connectionStateChangedCallbacks) {
        try {
            callback(newStatus);
        } catch (e) {
        }
    }
};

/**
 * Called when there's an error we also want to send onto users of the library
 */
const dispatchError = (error: string): void => {
    logError("(dispatched) " + error);
    for (const callback of connectionErrorCallbacks) {
        try {
            callback(error);
        } catch (e) {
            // Not doing anything if a provided callback failed
        }
    }
}
//endregion Event Processing

//region External functions for library specifically

/**
 * Name of the present player. Empty string if no player.
 */
export const getPlayerName = (): string | null => {
    return playerName;
}

/**
 * Dbref of player represented as a number. -1 if no player.
 */
export const getPlayerDbref = (): number | null => {
    return playerDbref;
}

/**
 * Utility function to return whether a player exists
 */
export const isPlayerSet = (): boolean => {
    return playerDbref !== null;
}

/**
 * Returns the present connection state.
 * One of: connecting, login, connected, failed
 */
export const getConnectionState = (): ConnectionState => {
    return connectionState;
}

//endregion External functions for library specifically

//region Initialization

// Previously this was a test to find something in order of self, window, global
const context = globalThis;

// Figure out whether we have local storage (And load debug option if so)
localStorageAvailable = localStorage?.getItem !== undefined;
if (localStorageAvailable && localStorage.getItem('mwiWebsocket-debug') === 'y') debug = true;

// Set default URLs
if (context.location) {
    defaultWebsocketUrl = (location.protocol === 'https:' ? 'wss://' : 'ws://') // Ensure same level of security as page
        + location.hostname + "/mwi/ws";
    defaultAuthenticationUrl = location.origin + '/getWebsocketToken';
}

logDebug("Initialization complete.")

//endregion Initialization
