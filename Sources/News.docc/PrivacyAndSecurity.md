# Privacy, sandbox and security boundaries

Know what leaves the Mac, what is treated as untrusted, and which layer enforces each boundary.

## Overview

Library data stays on the Mac. In a release build, the traffic that leaves is feed, article and image requests to publishers, the resources a page loads when a story is opened in Web view, and one update check to GitHub through ``UpdateChecker``. Publishers see the client's IP address and the requested URLs, and so do any third parties that serve a Web view page's resources.

Release builds link no analytics or crash-reporting SDK. Only a development build with a Sentry DSN configured links Sentry, and it sends crash reports and warning and error logs, with non-public values redacted, to that Sentry project.

All URLs, feed bodies, HTML, redirects, DNS answers and OPML files are untrusted, including content from public HTTPS endpoints.

### Sandbox

The app runs under App Sandbox and Hardened Runtime, and `News.entitlements` grants only three capabilities beyond the sandbox itself:

| Entitlement | Why |
|---|---|
| `com.apple.security.network.client` | Outgoing requests to publishers and the update check |
| `com.apple.security.network.server` | The gateway's listener, bound to `127.0.0.1` |
| `com.apple.security.files.user-selected.read-write` | Files the reader picks in a dialog, such as OPML |

### Network gateway

Remote fetching goes through ``SecureHTTPClient`` and the loopback ``NetworkBoundaryProxy``. The gateway resolves each name through ``ProxyResolver``, checks every answer with ``IPAddressValidator``, and connects to a validated numeric address, so a second DNS lookup cannot rebind the connection to a private one. Loopback, private and link-local ranges are refused, and only ports 80, 443, 8080 and 8443 are allowed. TLS stays end to end between the client and the publisher.

### Untrusted content

Parsers bound their input: feed XML rejects entity declarations and caps depth and item count, and OPML import scans for entity and attribute-list declarations before Foundation can expand them. ``ArticleWebView`` previews use a non-persistent data store, disable publisher JavaScript and use ``WebPreviewPolicy`` to block local URL forms, because WebKit bypasses proxies for local destinations.

### Local data

The library, read state, saved stories, mute rules and generated analysis stay in the app's container. ``CacheManager`` keeps the HTTP cache apart from durable user state, so clearing it loses nothing the reader made. Spotlight indexes saved stories only. ``LibraryBackup`` writes only where the reader chooses, and nothing uploads it.

Logs must not expose secrets, article contents or full sensitive URLs.

### Notifications

``NotificationService`` offers three levels. Full mode shows headlines and may fetch a lead image through the protected client. Private and Minimal modes show no story text and make no image request.

## Topics

### Boundaries

- ``SecureHTTPClient``
- ``NetworkBoundaryProxy``
- ``IPAddressValidator``
- ``ProxyResolver``
- ``WebPreviewPolicy``
