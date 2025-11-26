import {updateAndDispatchStatus, updateAndDispatchPlayer, receivedStringFromConnection} from "./core";
import {ConnectionState} from "./defs";
import Connection from "./connection";

/**
 * A fake connection for testing purposes
 */
export default class ConnectionFaker extends Connection {

    constructor(_options: object = {}) {
        super();
    }

    connect(): void {
        updateAndDispatchStatus(ConnectionState.connected);
        updateAndDispatchPlayer(1, 'TestPlayer');
    }

    disconnect(): void {

    }

    sendString(stringToSend: string): void {

        if (stringToSend.startsWith('SYS')) {
            let [message, data] = stringToSend.split(',', 2);
            message = message ? message.slice(3) : '';
            data = data ? JSON.parse(data) : {};
            //Respond to join requests as if joined
            if (message === 'joinChannels') {
                setTimeout(() => receivedStringFromConnection('SYSjoinedChannel,' + this.encodeDataForConnection(data)));

            }
        }

        if (stringToSend.startsWith('MSG')) {
            let [channel, message, data] = stringToSend.split(',', 3);
            channel = channel ? channel.slice(3) : '';
            data = data ? JSON.parse(data) : {};
            //Reflect anything that has 'reflect' as the message
            if (message === 'reflect') {
                setTimeout(() => receivedStringFromConnection('MSG' + channel + ',reflected,' + this.encodeDataForConnection(data)));
            }
        }
    }

}