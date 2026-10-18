# Notification attachments and live lookup overlap — 18 October 2026

Baseline: main `68ea4a6` (merged #445–#448), with the notification fix in this PR. The earlier [real compiled-app audit](2026-10-18-notification-live-check.md) records real refresh delivery and Mars's click-through. This follow-up addresses its missing overlap evidence and the reported absence of notification images.

## Reproduced defect and fix

The old service wrote publisher WebP bytes to `.webp` files and swallowed attachment errors. On this host, direct WebP attachment creation returned `UNErrorDomain` 101, “Unrecognized attachment file type”; the same system accepted PNG. The protected client advertises WebP/AVIF in its Accept header, so this path can receive formats the reader supports but notifications reject. Apple's [attachment documentation](https://developer.apple.com/documentation/usernotifications/unnotificationattachment) requires supported local media files.

Full notifications now reuse the reader's selected image and existing bounded ImageIO decoder, then encode PNG rather than trusting the response MIME type. The existing dimension/pixel checks remain, and encoded attachments are capped at 10 MB. Failed writes/attachment creation clean up the owned temporary file and produce a domain/code diagnostic without article text or URLs. Text-only delivery remains the fallback. Minimal/private modes are unchanged; publisher-page lookup is still independent of notification triage.

The offline regression exercises a valid tiny WebP converted to a readable framework-owned PNG, existing PNG input, and malformed data rejection. Full regressions passed before and after incorporating merged #447/#448; the production SwiftPM app target passed. Changed Swift files pass formatting. Repository-wide formatting still fails in untouched `RefreshCoordinator.swift`; a full lint pass finds 218 inherited errors, including protected corpus code. This is not reported as passing.

## Live compiled-app evidence

`script/test_notification_live.sh` builds all production sources using the normal arm64 app build/signing path and an explicit audit entry point. It uses the existing `com.marspater.news` authorization, synthetic eligible stories, temporary preferences and in-memory SQLite. It never opens the production library, changes notification permissions or replaces an installed app. The production `FeedManager`, default notification sender, protected HTTP client and publisher-page image finder are exercised. One report's delayed public HTTPS page keeps lookup unfinished; the other supplies a public WebP image.

The final audit completed successfully. Authorization status was 2 (authorized). `UNUserNotificationCenter` returned two actually delivered notifications, including one `public.png` attachment. Delivery was observed while the wrapped production page lookup had started and had not returned. The image notification's stored-ID/link payload was passed through the real `ArticleStore.articleForNavigation` resolver, which returned the expected story and matching title. Raw feed IDs are not used as a proxy for persisted identity.

The JSON report records exact lookup/delivery observation times in `/private/tmp/news-notification-live/report.json`. Runtime and build logs are in the same private directory. The script verifies the staged signature with `codesign --verify --deep --strict` before execution. It removes only its synthetic delivered notifications afterwards and closes the audit app. No real subscriptions, history, saved/read flags or settings are changed by the harness.

An initial harness build failed because synthetic GUID arguments were missing; the next run exposed an incorrect raw-ID expectation in the harness. Both were corrected. Only the final successful run above is acceptance evidence.

## Limits and issue disposition

This establishes real OS delivery with a supported attachment during an unfinished protected publisher-image lookup, rather than only an injected notification callback. The fixture feed batch and delayed page are controlled; this is not a new real-library refresh or a live news-corpus accuracy audit. Earlier real-app click-through evidence remains in the previous audit; no new human click is claimed. Notification Centre accessibility timed out, so visual thumbnail rendering itself was not captured. API-delivered attachment evidence is kept distinct from visual proof.

The Hindu was also rechecked with `NEWS_CATALOG_FEEDS=the-hindu NEWS_CATALOG_SAMPLE=3 ./test.sh --catalog-reader-access`: the feed was readable and all three sampled articles extracted successfully, median 999 words. This supports retaining the catalog feed and resolving the earlier transient Cloudflare report; it does not guarantee future publisher availability. Private log: `/private/tmp/news-hindu-current.log`.
