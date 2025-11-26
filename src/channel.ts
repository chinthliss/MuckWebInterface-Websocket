import {sendChannelMessage} from './core';
import ChannelInterface from "./channel-interface";

import type {ChannelMessageCallback, ChannelMonitorCallback} from "./defs";

export default class Channel {

    /**
     * This channel's name
     */
    readonly name: string;

    /**
     * Collection of callbacks, indexed by the message they respond to
     */
    private messageCallbacks: { [message: string]: ChannelMessageCallback[] } = {};

    /**
     * Callbacks that will receive any message
     */
    private monitorCallbacks: ChannelMonitorCallback[] = [];

    /**
     * The public interface that will be passed back to the calling page
     */
    interface: ChannelInterface;

    /**
     * Used so we can capture and buffer messages to a channel that are sent before the join command completes
     */
    private joined: boolean = false;

    /**
     * Used to cache outgoing messages during joining or rejoining
     */
    private joiningMessageBuffer: [message: string, data: any][] = [];

    /**
     * Creates a new channel with the given name
     */
    constructor(channelName: string) {
        if (!channelName) throw "Attempt to create channel with an empty channelName.";
        this.name = channelName;
        this.interface = new ChannelInterface(this);
    }

    /**
     * Has this channel handle a received message
     */
    receiveMessage(message: string, data: any): void {
        for (const callback of this.monitorCallbacks) {
            setTimeout(() => {
                callback(message, data, false);
            });
        }
        const callbacks = this.messageCallbacks[message];
        if (callbacks) {
            for (const callback of callbacks) {
                setTimeout(() => {
                    callback(data);
                });
            }
        }
    }

    /**
     * Send a message via this channel
     */
    sendMessage(message: string, data: any): void {
        if (!this.joined) {
            //If we're connecting/reconnecting, then buffer it instead
            this.joiningMessageBuffer.push([message, data]);
            return;
        }
        for (const callback of this.monitorCallbacks) {
            setTimeout(() => {
                callback(message, data, true);
            });
        }
        sendChannelMessage(this.name, message, data);
    }


    /**
     * Register a handler to react to a particular message
     */
    registerMessageHandler(message: string, handler: ChannelMessageCallback): void {
        if (!(message in this.messageCallbacks)) this.messageCallbacks[message] = [];
        this.messageCallbacks[message]?.push(handler);
    }

    /**
     * Register a new handler to see ALL communication
     */
    registerMonitorHandler(handler: ChannelMonitorCallback): void {
        this.monitorCallbacks.push(handler);
    }

    /**
     * Used to notify the channel it's been connected
     */
    channelConnected(): void {
        this.joined = true;
        for (const bufferedMessage of this.joiningMessageBuffer) {
            this.sendMessage(bufferedMessage[0], bufferedMessage[1]);
        }
    }

    /**
     * Used to notify the channel it's been disconnected
     */
    channelDisconnected(): void {
        this.joined = false;
    }

    /**
     * Get whether the channel is presently joined
     */
    isChannelJoined(): boolean {
        return this.joined;
    }
}