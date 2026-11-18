// Rex exposes a host-scoped scripting ID for each session. Address the object
// by its complete ID even if a similarly named host or session exists.
function showSession(app, hostName, sessionID) {
    const hosts = app.hosts.whose({name: hostName})();
    if (hosts.length !== 1 || !hosts[0].connected()) {
        throw Error("Connect this Rex app to the selected host, then refresh the picker.");
    }
    const hostID = hosts[0].id();
    const session = app.sessions.byId(hostID + "/" + sessionID);
    if (!session.exists() || !session.remote() || session.hostName() !== hostName) {
        throw Error("The session is no longer available in this Rex app. Refresh the picker.");
    }
    app.show(session);
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
