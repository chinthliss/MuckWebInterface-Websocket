export default abstract class Connection {

    encodeDataForConnection(data: any): string {
        if (typeof data === 'undefined') return '';

        let json: string = JSON.stringify(data);
        // Attempt to try to replace certain unicode special characters with ANSI ones.
        // Note that we're already JSON so any replacements must take that into account
        json = json
            .replace(/[\u2018\u2019\u201A]/g, "'") // Single-quotes
            .replace(/[\u201C\u201D\u201E]/g, '\\"') // Double-quotes
            .replace(/\u2026/g, "...") // Ellipsis
            .replace(/[\u2013\u2014]/g, "-") // Dash
            .replace(/\u02C6/g, "^")
            .replace(/\u2039/g, "<")
            .replace(/\u203A/g, ">")
            .replace(/[\u02DC\u00A0]/g, " ")
        return json;
    }

    /**
     * Start up the connection
     */
    abstract connect(): void;

    /**
     * Stop the connection
     */
    abstract disconnect(): void;

    /**
     * Send a string over the connection
     */
    abstract sendString(stringToSend: string): void;

}