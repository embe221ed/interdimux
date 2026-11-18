// Rex exposes a host-scoped scripting ID for each session. Read each object's
// properties in one Apple Event; each individual property access crosses into Rex.
function showSession(app, hostName, sessionID) {
    const hosts = app.hosts.whose({name: hostName})();
    const host = hosts.length === 1 ? hosts[0].properties() : null;
    if (!host || !host.connected || host.name !== hostName || !host.id) {
        throw Error("Connect this Rex app to the selected host, then refresh the picker.");
    }
    const id = host.id + "/" + sessionID;
    const session = app.sessions.byId(id);
    const missing = "The session is no longer available in this Rex app. Refresh the picker.";
    try {
        const details = session.properties();
        if (details.id !== id || !details.remote || details.hostName !== hostName) {
            throw Error(missing);
        }
        app.show(session);
    } catch (error) {
        if (error.errorNumber === -1728) throw Error(missing);
        throw error;
    }
}

function run(args) {
    try {
        const app = Application(Number(args[0]));
        if (app.id() !== "com.superlogical.rex") {
            throw Error("The original Rex app closed. Reopen the picker from Rex.");
        }
        if (!app.hosts || !app.sessions || !app.show) {
            throw Error("Update Rex for Mac to a version with AppleScript session support.");
        }
        showSession(app, args[1], args[2]);
        return JSON.stringify({shown: true});
    } catch (error) {
        const message = error.errorNumber === -1743
            ? "Allow Automation access to Rex in System Settings → Privacy & Security → Automation."
            : error.message;
        return JSON.stringify({error: message});
    }
}
