# Local Privacy & Security Architecture

Learn about the zero-telemetry local storage engine and the protected network egress boundary.

## Overview

News operates with a zero-telemetry architecture where user data remains exclusively on the Mac.

### Local-First Persistence

- **SQLite Database (``DatabaseEngine``)**: Stores feeds, articles, reading history, and saved stories locally at:
  ```text
  ~/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3
  ```
- **Spotlight Integration (``SpotlightIndexer``)**: Indexes only stories explicitly saved by the user into macOS `CoreSpotlight`. Unread and read articles are never exposed to external indexes.
- **Zero Diagnostics**: Contains no third-party tracking or diagnostic SDKs.

### Network Gateway & SSRF Protection

All outbound HTTP requests for feeds, article readers, and lead images pass through a dedicated validation gateway (``SecureHTTPClient``):
- **Address Validation**: Validates resolved DNS answers against loopback (`127.0.0.0/8`, `::1`), private networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), and link-local/cloud metadata endpoints (`169.254.169.254`).
- **Connection Pinning**: Upstream sockets connect strictly to validated numeric IP addresses, preventing DNS rebinding attacks.
- **WebKit Security**: Embedded article previews disable JavaScript execution and enforce native content rules blocking local network resources.
