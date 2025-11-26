import Channel from "./channel";
import type {ChannelMessageCallback, ChannelMonitorCallback} from './defs';

/**
 * The parts of a channel that will be exposed to a program using this library
 */
export default class ChannelInterface {

    /**
     * Channel that this public interface is for
     */
    private channel: Channel;

    /**
     * Constructor
     */
    constructor(channel: Channel) {
        this.channel = channel;
    }

    /**
     * Name of the channel
     */
    name(): string {
        return this.channel.name;
    }

    /**
     * String representation for this channel
     */
    toString(): string {
        return "Channel[" + this.name() + "]"
    }

    /**
     * Used to register callbacks for when a given message arrives via this channel.
     * The given callback will receive whatever data the muck sends
     */
    on(message: string, callback: ChannelMessageCallback) {
        if (!message || !callback) throw "Invalid Arguments";
        this.channel.registerMessageHandler(message, callback);
    }

    /**
     * Called on ANY message, mostly intended to monitor a channel in development
     * The given callback will receive (message, data, outgoing?)
     */
    any(callback: ChannelMonitorCallback) {
        if (!callback) throw "Invalid Arguments";
        this.channel.registerMonitorHandler(callback);
    }

    /**
     * Sends a message via this channel
     */
    send(message: string, data: any = null) {
        if (!message) throw "Send called without a text message";
        this.channel.sendMessage(message, data);
    }
}