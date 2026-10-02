# Privacy Architecture & Data Policy

NewsApp is engineered with a **local-first, zero-telemetry architecture**. Reading state, saved stories and generated analysis are stored on your Mac and are not sent to telemetry or cloud AI providers. Feed, article and image requests go directly to publishers, which receive your IP address and the requested URLs. Pages opened in Web view can load publisher-controlled third-party resources.

---

## 1. Local-First Storage Architecture

* **Database Engine**: All application state—including subscribed feeds, articles, read state, bookmarks, and full-text search indexes—is stored locally in SQLite (`news.sqlite3`) using Write-Ahead Logging (WAL) and `NORMAL` synchronous mode in your user application support directory:
  ```text
  ~/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3
  ```
* **Separation of Concerns**: Ephemeral HTTP response caches (`URLCache`) are strictly segregated from durable user data. Clearing the HTTP cache does not alter bookmarks, read markers, or custom feed hierarchies.
* **Muting**: Muted publisher hosts and topic words are stored in the app's local preferences and applied on your Mac; they are never sent anywhere.
* **No Account Required**: The application does not require user registration, account creation, or cloud authentication.

---

## 2. Zero Telemetry & Network Egress Boundary

* **No Analytics or Tracking**: NewsApp contains zero telemetry SDKs, zero user tracking scripts, and zero third-party diagnostic reporters (e.g., no Google Analytics, no Firebase, no Sentry, no Mixpanel).
* **Direct Network Access**: Outgoing HTTP/HTTPS network requests are made directly from your Mac to the specific RSS, Atom, or JSON feed hosts that you choose to subscribe to, and to the original web pages you view. An on-device loopback gateway validates destinations and pins upstream connections to public IP addresses. No remote proxy, relay server or cloud scraper is utilized. TLS remains end-to-end between the native client and publisher.
* **Server-Side Request Forgery (SSRF) Protection**:
  Feed, extraction, article-image and update requests use `SecureHTTPClient` and the native socket gateway. The gateway validates every resolved address before connecting to a numeric public endpoint, preventing a second DNS lookup from rebinding the connection. Protected Web previews use the same gateway and native content rules; permitted public third-party resources can still load:
  * **Loopback Prevention**: `127.0.0.0/8`, `::1`
  * **Private Network (RFC 1918) Prevention**: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`
  * **Link-Local / Cloud Metadata Prevention**: `169.254.0.0/16`, `fe80::/10`, AWS/GCP metadata (`169.254.169.254`)
  * **Port Restrictions**: Non-standard intranet ports are rejected; only standard HTTP/HTTPS ports (80, 443, 8080, 8443) are permitted for feed retrieval.
* **WebView Navigation Security**: In-app article previews enforce strict HTTPS/HTTP schemes. Scripts are disabled to prevent independent WebRTC sockets. Native WebKit content rules block numeric literals, single-label, localhost and mDNS resources, including local redirects, because WebKit implicitly bypasses proxies for local addresses. These restrictions can affect publisher interactivity; the external browser option remains available.

---

## 3. Notification Privacy Tiers & Network Egress

NewsApp provides three distinct notification privacy modes with clear network and metadata boundaries:

* **Full Mode**: Displays the article headline, publisher source, and teaser snippet. If an article provides a lead image, it is fetched on-demand directly from the publisher via `SecureHTTPClient` with full SSRF validation, size limits (5 MB max), and timeout bounds.
* **Private Mode**: Emits strictly generic notification alerts (`Title: News Update`, `Body: You have new articles available. Open to read.`). Zero article headlines, body snippets, or publisher names are included, and **zero remote image requests** are executed.
* **Minimal Mode**: Aggregates all new articles into a single unified notification alert (`3 new articles across 2 sources`). No article headlines or content are disclosed, and **zero remote image requests** are executed.

---

## 4. On-Device Intelligence & Natural Language Processing

* **Local Machine Learning**: All article intelligence operations—topic categorization, sentiment scoring, named entity extraction, and content summarization—are executed locally on-device using Apple's `NaturalLanguage` and, when available, `FoundationModels` frameworks.
* **Zero Cloud AI Egress**: Article content, summaries, and extracted metadata are never transmitted to third-party AI or cloud LLM APIs.

---

## 5. Minimal Hardened Runtime Entitlements

NewsApp is signed with macOS **Hardened Runtime** and declares only the absolute minimum required entitlements (`News.entitlements`):

| Entitlement | Purpose |
|:---|:---|
| `com.apple.security.network.client` | Outgoing HTTP/HTTPS network connections to fetch feeds and article web pages. |
| `com.apple.security.network.server` | An ephemeral listener bound strictly to `127.0.0.1` for the on-device destination-validation gateway; no LAN listener. |

| `com.apple.security.files.user-selected.read-write` | User-initiated file dialogs to import and export OPML subscription lists. |

No access is requested or granted for:
* Camera or Microphone
* Location Services
* Contacts, Calendars, or Reminders
* Arbitrary disk read/write permissions

---

## 6. Data Retention & User Control

* **Retention Policies**: Configurable automatic pruning keeps local SQLite storage lightweight without removing bookmarked articles.
* **Exportability**: You can export your entire feed library at any time via the standard OPML 2.0 format (`File > Export OPML...`).
* **Complete Erasure**: Current application data is stored under `~/Library/Containers/com.marspater.news/`. Quit the app before manually removing its sandbox container. Removing that container does not erase exported OPML files or historical backups stored elsewhere.

