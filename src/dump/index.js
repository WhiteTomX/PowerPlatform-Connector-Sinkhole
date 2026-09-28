// Catch-all dump: writes the raw incoming POST/PUT verbatim to blob storage, then
// responds 410 Gone with a plain-text warning (the domain is dangling and was
// reclaimed for research - anyone still sending it requests should know their
// content is no longer private to the original owner). Deliberately does NOT
// context.log() the body/headers anywhere - the only copy of the content is the
// blob itself, so it stays out of Application Insights (now wired up for failure
// visibility - see tofu/monitoring.tf - but only ever sees what this file logs) and
// is only visible to whoever reads the blob.
const GONE_MESSAGE = [
    "410 Gone",
    "",
    "This domain was previously used by a different service, which has since been",
    "decommissioned. The domain was left dangling (still routable, no longer owned",
    "by the original operator) and has been reclaimed to prevent takeover by a",
    "malicious third party.",
    "",
    "Any request sent here - including this one - could otherwise have been",
    "received by an unrelated third party able to view its contents. Stop sending",
    "requests to this host and update the receiving system's configuration."
].join("\n");

module.exports = async function (context, req) {
    const record = {
        receivedAtUtc: new Date().toISOString(),
        method: req.method,
        url: req.originalUrl || req.url,
        query: req.query,
        headers: req.headers,
        // rawBody preserves the exact bytes as received (as a string); falls back
        // to the parsed body if the runtime didn't populate rawBody for some content type.
        body: req.rawBody !== undefined ? req.rawBody : req.body
    };

    context.bindings.outputBlob = JSON.stringify(record, null, 2);

    context.log(`Dumped ${req.method} ${req.url} (${Buffer.byteLength(context.bindings.outputBlob)} bytes)`);

    context.res = {
        status: 410,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: GONE_MESSAGE
    };
};
