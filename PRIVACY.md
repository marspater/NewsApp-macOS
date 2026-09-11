# Privacy Architecture & Data Policy

NewsApp is engineered with a **local-first, zero-telemetry architecture**. Your reading habits, article feeds, saved stories, and AI intelligence analysis remain strictly confidential and never leave your Mac.

---

## 1. Local-First Storage Architecture

* **Database Engine**: All application state—including subscribed feeds, articles, read state, bookmarks, and full-text search indexes—is stored locally in SQLite (`news_v2.sqlite`) using Write-Ahead Logging (WAL) and `NORMAL` synchronous mode in your user application support directory:
  ```text
  ~/Library/Application Support/News/news_v2.sqlite
  ```
* **Separation of Concerns**: Ephemeral HTTP response caches (`URLCache`) are strictly segregated from durable user data. Clearing the HTTP cache does not alter bookmarks, read markers, or custom feed hierarchies.
* **No Account Required**: The application does not require user registration, account creation, or cloud authentication.

---

## 2. Zero Telemetry & Network Egress Boundary

* **No Analytics or Tracking**: NewsApp contains zero telemetry SDKs, zero user tracking scripts, and zero third-party diagnostic reporters (e.g., no Google Analytics, no Firebase, no Sentry, no Mixpanel).
* **Direct Network Access**: Outgoing HTTP/HTTPS network requests are made directly from your Mac to the specific RSS, Atom, or JSON feed hosts that you choose to subscribe to, and to the original web pages you view. No intermediate proxy, relay server, or cloud scraper is utilized.
* **Server-Side Request Forgery (SSRF) Protection**:
  All network requests pass through `SecureHTTPClient` and `IPAddressValidator` prior to connection initiation:
  * **Loopback Prevention**: `127.0.0.0/8`, `::1`
  * **Private Network (RFC 1918) Prevention**: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`
  * **Link-Local / Cloud Metadata Prevention**: `169.254.0.0/16`, `fe80::/10`, AWS/GCP metadata (`169.254.169.254`)
  * **Port Restrictions**: Non-standard intranet ports are rejected; only standard HTTP/HTTPS ports (80, 443, 8080, 8443) are permitted for feed retrieval.
* **WebView Navigation Security**: In-app article previews enforce strict HTTPS/HTTP schemes and prevent navigation to private or local network hosts.

---

## 3. On-Device Intelligence & Natural Language Processing

* **Local Machine Learning**: All article intelligence operations—topic categorization, sentiment scoring, named entity extraction, and content summarization—are executed locally on-device using Apple's `NaturalLanguage` framework.
* **Zero Cloud AI Egress**: Article content, summaries, and extracted metadata are never transmitted to third-party AI or cloud LLM APIs.

---

## 4. Minimal Hardened Runtime Entitlements

NewsApp is signed with macOS **Hardened Runtime** and declares only the absolute minimum required entitlements (`News.entitlements`):

| Entitlement | Purpose |
|:---|:---|
| `com.apple.security.network.client` | Outgoing HTTP/HTTPS network connections to fetch feeds and article web pages. |
| `com.apple.security.files.user-selected.read-write` | User-initiated file dialogs to import and export OPML subscription lists. |

No access is requested or granted for:
* Camera or Microphone
* Location Services
* Contacts, Calendars, or Reminders
* Arbitrary disk read/write permissions
* Server network listener sockets (`network.server`)

---

## 5. Data Retention & User Control

* **Retention Policies**: Configurable automatic pruning keeps local SQLite storage lightweight without removing bookmarked articles.
* **Exportability**: You can export your entire feed library at any time via the standard OPML 2.0 format (`File > Export OPML...`).
* **Complete Erasure**: Deleting the `~/Library/Application Support/News` and `~/Library/Caches/com.marspater.news.cache` directories completely purges all application state from your machine.
