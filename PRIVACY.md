# Privacy Architecture & Data Policy

NewsApp is engineered with a **local-first, zero-telemetry architecture**. Reading state, saved stories and generated analysis are stored on your Mac and are not sent to telemetry or cloud AI providers. Feed, article and image requests go directly to publishers, which receive your IP address and the requested URLs. Pages opened in Web view can load publisher-controlled third-party resources.

---

## 1. Local-First Storage Architecture

* **Database Engine**: All application state—including subscribed feeds, articles, read state, bookmarks, and full-text search indexes—is stored locally in SQLite (`news.sqlite3`) using Write-Ahead Logging (WAL) and `NORMAL` synchronous mode in your user application support directory:
  ```text
  ~/Library/Containers/com.marspater.news/Data/Library/Application Support/com.marspater.news/news.sqlite3
  ```
* **World Tension**: Opt-in panel headlines and on-device v2 assessments stay local. Up to 90 daily assessments and their bounded headline evidence are stored in `news.sqlite3.world-tension-v2.json` beside the library; the reading shown blends a day with its week on device (methodology v3), and no cloud model receives them.
* **Separation of Concerns**: Ephemeral HTTP response caches (`URLCache`) are strictly segregated from durable user data. Clearing the HTTP cache does not alter bookmarks, read markers, or custom feed hierarchies.
* **Spotlight Indexing**: Only stories you explicitly save are indexed in macOS Spotlight (`CoreSpotlight`) on your Mac, with their title, publisher, summary, and publication date (`com.marspater.news.saved-stories`). Unread and read feed items are never indexed. Removing a story from Saved Stories removes its Spotlight entry immediately, clearing caches leaves saved-story entries intact, and each launch rebuilds the Spotlight entries from the library, so after a restore only the restored library's saved stories remain. Deleting the library files by hand leaves entries in Spotlight until News next launches.
* **Muting**: Muted publisher hosts and topic words are stored in the app's local preferences and applied on your Mac; they are never sent anywhere.
* **Backups**: Back Up Library… writes a backup only where you save it; it contains your library, settings and World Tension history and is readable by your user account only. NewsApp never uploads it; a synced folder you save it to, such as iCloud Drive, may. Restoring keeps the replaced library beside it on your Mac (newest two copies).
* **No Account Required**: The application does not require user registration, account creation, or cloud authentication.

---

## 2. Zero Telemetry & Network Egress Boundary

* **No Analytics or Tracking**: NewsApp contains zero telemetry SDKs, zero user tracking scripts, and zero third-party diagnostic reporters (e.g., no Google Analytics, no Firebase, no Sentry, no Mixpanel).
* **Direct Network Access**: Outgoing HTTP/HTTPS network requests are made directly from your Mac to the specific RSS, Atom, or JSON feed hosts that you choose to subscribe to, and to the original web pages you view. In the background, the app also reads a few article pages from those publishers: for card images, and for publisher-excerpt event overviews when energy policy allows. An on-device loopback gateway validates destinations and pins upstream connections to public IP addresses. No remote proxy, relay server or cloud scraper is utilized. TLS remains end-to-end between the native client and publisher.
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

* **Full Mode**: Displays the article headline, publisher source, and teaser snippet; a grouped banner shows a count and up to two headlines. If an article provides a lead image, it is fetched on-demand directly from the publisher via `SecureHTTPClient` with full SSRF validation, size limits (10 MB max), and timeout bounds. Which stories notify is decided on your Mac from each story's wording, how many publishers report its event, the feeds you star (at most three) and your top three interest categories, which come from the same local read and saved history as the Briefing. To hold its limits and avoid repeats across refreshes and relaunches, `news.sqlite3` keeps a local delivery log: when each banner posted, its lane and starred feed, and the events it announced with a headline key (7 days), plus priority stories waiting for the next grouped banner with their headlines (24 hours). The log never leaves your Mac.
* **Private Mode**: Emits strictly generic notification alerts (`Title: News Update`, `Body: You have new articles available. Open to read.`). Zero article headlines, body snippets, or publisher names are included, and **zero remote image requests** are executed.
* **Minimal Mode**: Aggregates all new articles into a single unified notification alert (`3 new articles across 2 sources`). No article headlines or content are disclosed, and **zero remote image requests** are executed.

---

## 4. On-Device Intelligence & Natural Language Processing

* **Local Machine Learning**: All article intelligence operations—topic categorization, sentiment scoring, named entity extraction, and content summarization—are executed locally on-device using Apple's `NaturalLanguage` and, when available, `FoundationModels` frameworks.
* **Lead Images**: When a shown, unmuted story's group has no usable image, the app reads up to 256 KiB from the start of one report's article page (through the same protected client as the reader) to find its Open Graph, Twitter or schema.org article image. Publishers therefore receive requests for some stories you have not opened, at most 30 per refresh, outside Low Power Mode. Completed lookups are remembered; unreachable pages may retry. Article text from these lookups is not kept.
* **Briefing**: Recent read and saved-story categories influence the finite Briefing on device. The app reads at most 200 existing local history records from the last 30 days; it creates no remote profile. Panel feeds fetched only for World Tension stay outside the ordinary feed unless subscribed; read/saved stories remain accessible.
* **Story Importance**: Existing local importance ratings can break Briefing ties after publisher coverage. Refresh and Briefing selection do not request new ratings. Importance never hides stories, deletes them or suppresses feed ingestion; ordinary user-configured retention still applies.
* **Event Grouping**: Headlines and feed summaries are compared locally using deterministic NaturalLanguage signals. Borderline pairs may be scored by the app's own on-device pair model (a fine-tuned MiniLM CoreML model); decisions never invoke an LLM, and grouping works independently of the on-device AI setting.
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

* **Retention Policies**: Read stories that are not saved are deleted after 30 days by default (Settings › Storage: Never, 30 or 90 days). Saved stories, unread stories and stories cited by an event overview are kept.
* **Exportability**: You can export your entire feed library at any time via the standard OPML 2.0 format (`File > Export OPML...`).
* **Diagnostics Export**: Help › Export Diagnostics… writes a zip file to a place you choose. Nothing is sent anywhere; you decide whether to share the file. It contains:
  * The app's own log entries (subsystem `com.marspater.news`) from **this launch only**. macOS lets a sandboxed app read only its own process's log, so entries from earlier launches are not included. If the app has run for more than a day, only the last 24 hours are included. Values the app logs as private appear as `<private>`.
  * The app version and build, the macOS version and the library's schema version.
  * A settings summary: counts of feeds, starred feeds, sections and mute rules; the refresh interval and retention period; and which notification, Dock badge, menu bar, on-device intelligence, insecure HTTP and World Tension options are on.
  * Feed health per subscription (responding or failing, newest item, text depth), named by host only.

  The export does not add story text. Before the zip is written, every URL is cut down to its host (no path, query or credentials), home folder paths are shortened to `~`, and the titles of stories the app has loaded are replaced with `<story>` when they are 12 or more characters long. Shorter titles are left as written, because they match ordinary words in log text. The app does not log titles as public values, so they normally appear only as `<private>`.
* **Complete Erasure**: Current application data is stored under `~/Library/Containers/com.marspater.news/`. Quit the app before manually removing its sandbox container. Removing that container does not erase exported OPML files or historical backups stored elsewhere.
