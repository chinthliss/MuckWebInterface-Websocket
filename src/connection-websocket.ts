import {
    handleConnectionFailure,
    handleConnectionSuccess,
    logDebug,
    logError,
    receivedStringFromConnection,
    updateAndDispatchPlayer,
    updateAndDispatchStatus
} from "./core";
import {ConnectionState} from "./defs";
import Connection from "./connection";
import axios from "axios";
import type {AxiosError, AxiosInstance, AxiosResponse} from "axios";

export interface ConnectionWebsocketOptions {
    websocketUrl?: string;
    authenticationUrl?: string;
}

/**
 * Handles the underlying websocket connection
 */
export default class ConnectionWebSocket extends Connection {

    /**
     * In case we're outdated and need a refresh.
     */
    private protocolVersion: number = 1;

    /**
     * The url used to request an access token
     */
    private authenticationUrl: string;

    /**
     * The url the websocket will connect to
     */
    private websocketUrl: string;

    /**
     * The websocket
     */
    private connection: WebSocket | null = null;

    /**
     * Used as part of the handshake
     */
    private handshakeReceivedWelcome: boolean = false;

    /**
     * Used as part of the handshake
     */
    private handshakeCompleted: boolean = false;

    /**
     *  Use as part of the handshake
     */
    private handshakeTimeout: ReturnType<typeof setTimeout> | null = null;

    /**
     * Used to hold messages that tried to send before the initial connection is complete
     */
    private connectingOutgoingMessageBuffer: string[] = [];

    /**
     * Our own Axios instance, so we don't interfere/fight with a hosting pages interceptors
     */
    private axiosInstance: AxiosInstance;

    /**
     * Constructor
     */
    constructor(options: ConnectionWebsocketOptions = {}) {
        super();

        if (!options.websocketUrl || !options.authenticationUrl) throw "Missing mandatory options from MwiWebsocket configuration";

        this.axiosInstance = axios.create();

        // Calculate where we're connecting to
        this.websocketUrl = options.websocketUrl;
        this.authenticationUrl = options.authenticationUrl;

        // Add parameters to Url
        this.websocketUrl += '?protocolVersion=' + this.protocolVersion;
    }

    private clearHandshakeTimeoutIfSet = () => {
        if (this.handshakeTimeout) {
            clearTimeout(this.handshakeTimeout);
            this.handshakeTimeout = null;
        }
    };

    /**
     * Callback for the websocket's event handler
     */
    private handleWebSocketClose = (e: CloseEvent) => {
        logDebug("WebSocket closed: " + (e.reason ? e.reason : 'No reason given.'));
        this.cleanupAndReportConnectionFailure(
            "Websocket closed with " + (e.reason ? "reason: " + e.reason : "no reason given."), false
        );
    };

    /**
     * Callback for the websocket's event handler
     */
    private handleWebSocketError = () => {
        // This can be passed an event but the websocket spec only passes a simple Event object with no further information.
        logError("An error occurred with the websocket (which doesn't provide information)");
        // Websocket spec says that an error will auto-close, so wait until said close event to avoid duplication
        // this.cleanupAndReportConnectionFailure("Websocket returned error.");
    }

    /**
     * Callback for the websocket's event handler
     */
    private handleWebSocketMessage = (e: MessageEvent) => {
        let message = e.data.slice(0, -2); //Remove \r\n
        receivedStringFromConnection(message);
    }

    private openWebsocket(websocketToken: string) {
        logDebug("Opening websocket");
        updateAndDispatchStatus(ConnectionState.connecting);

        this.connection = new WebSocket(this.websocketUrl, 'mwi');
        this.connection.onopen = () => {
            this.handshakeReceivedWelcome = false;
            this.handshakeCompleted = false;
            this.connectingOutgoingMessageBuffer = [];
            this.handshakeTimeout = setTimeout(() => {
                logError('WebSocket took too long to complete handshake, assuming failure.');
                this.cleanupAndReportConnectionFailure("Websocket took too long to connect.", false);
            }, 10000);
        };

        this.connection.onclose = this.handleWebSocketClose;
        this.connection.onerror = this.handleWebSocketError;

        // During connection, we use a special onMessage handling to deal with the handshake
        this.connection.onmessage = (e) => {
            if (!this.connection) return; // Don't react if we disconnected
            let message = e.data.slice(0, -2); //Remove \r\n

            if (!this.handshakeReceivedWelcome) {
                if (message === 'welcome') {
                    this.connection.send('auth ' + websocketToken + ' ' + location.href);
                    this.handshakeReceivedWelcome = true;
                    logDebug("WebSocket received initial welcome message, attempting to authenticate.");
                } else logError("WebSocket got an unexpected message whilst expecting welcome: " + message);
                return;
            }

            if (!this.handshakeCompleted) {
                if (message.startsWith('accepted ')) {
                    logDebug("WebSocket received descr.");
                    let [descr, playerDbref, playerName] = message.slice(9).split(',');
                    playerDbref = parseInt(playerDbref);

                    logDebug("Server acknowledged us connected as descr: "
                        + descr + ", playerDbref: " + playerDbref + ", playerName: " + playerName);

                    this.clearHandshakeTimeoutIfSet();
                    this.handshakeCompleted = true;
                    // Switch the message handler to the proper one
                    this.connection.onmessage = this.handleWebSocketMessage;
                    handleConnectionSuccess();
                    updateAndDispatchStatus(ConnectionState.connected);
                    updateAndDispatchPlayer(playerDbref, playerName);
                    //Resend anything that was buffered
                    for (const message of this.connectingOutgoingMessageBuffer) {
                        this.sendString(message);
                    }
                    this.connectingOutgoingMessageBuffer = [];
                    return;
                }
                if (message === 'invalidtoken') {
                    this.cleanupAndReportConnectionFailure("Server refused authentication token.", true);
                    return;
                }
                logError("WebSocket got an unexpected message whilst expecting descr: " + message);
                return;
            }
            logError("Unexpected message during login: " + message);
        }
    }

    /**
     * Starts the websocket up and connects it.
     * Will fail if the websocket is already active.
     */
    connect() {
        if (this.connection) {
            logDebug("Attempt to connect websocket when it's already active.");
            return;
        }

        //Step 1 - we need to get an authentication token from the webpage
        let websocketToken: string;
        logDebug("Requesting authentication token from webpage");
        this.axiosInstance.get(this.authenticationUrl)
            .then((response: AxiosResponse) => {
                websocketToken = response.data;
                //Step 2 - connect to the websocket and throw the token at it
                this.openWebsocket(websocketToken);
            })
            .catch((error: AxiosError) => {
                // This is fatal if we actually managed to connect to the server and it refused us
                const isFatal: boolean = error.response !== undefined && error.response.status === 403;
                logError("Failed to get an authentication token from the webpage. Error was: " + error.message);
                if (isFatal) logError("Furthermore, the webpage forbid us from retrying.");
                this.cleanupAndReportConnectionFailure("Couldn't authenticate", isFatal);
            });
    }

    /**
     * Disconnects the websocket and tidies it up
     */
    disconnect(): void {
        this.clearHandshakeTimeoutIfSet();
        // The websocket's close connection callback will log this
        // logDebug(this.connection !== null ? "Closing websocket." : "No websocket to close.");
        if (this.connection !== null) this.connection.close(1000, "Disconnected");
        this.connection = null;
    }

    /**
     * Internal utility function to disconnect before passing an error back to core
     */
    private cleanupAndReportConnectionFailure(error: string, isFatal: boolean): void {
        if (this.connection) this.disconnect();
        handleConnectionFailure(error, isFatal);
    }

    /**
     * Send a string over the websocket
     */
    sendString(stringToSend: string): void {
        if (!this.connection) {
            logDebug("Couldn't send message (and not buffering) due to being in an unconnected state: " + stringToSend);
            return;
        }
        if (stringToSend.length > 30000) {
            logError("Websocket had to abort sending a string because it's over 30,000 characters.");
            return;
        }

        // Limit characters being sent to a limited ANSI subset.
        stringToSend = stringToSend.replace(/[^\x20-\x7E\x0A]/g, "")

        // Buffer the string if we're still connecting
        if (!this.handshakeReceivedWelcome || !this.handshakeCompleted) {
            logDebug("Buffering outgoing message: " + stringToSend);
            this.connectingOutgoingMessageBuffer.push(stringToSend);
            return;
        }
        this.connection.send(stringToSend);
    }

}