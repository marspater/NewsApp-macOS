# Topic classifier: labelled library sample — 24 October 2026

Issue #546 (epic L). The deterministic topic classifier (`NaturalLanguageTopicClassifier.classifyContent`) measured
before and after whole-word rule fixes on a labelled sample of stored stories. The Foundation Models classification
stage was unreachable (ingestion passed `allowFoundationModels: false`) and is deleted in the same change; nothing
measured here ever used it.

## Sample

- Source: a read-only copy of the live library (`sqlite3 .backup`, 6,020 stories, schema v25), stories published in
  the 14 days before 24 October 2026 (3,965 stories). The copy and the labelled file stay outside the repository.
- 200 stories drawn with a fixed seed; the id list is kept beside the labels so `--export-categories`
  (`NEWS_CATEGORY_IDS`) re-exports exactly the same stories after a rule change.
- Labels: Claude labelled every story into the app's 12 categories from headline and summary, following the
  decision of 24 October (Claude labels, Mars spot-checks). Label distribution: World 98, Technology 23, Business 18,
  Sports 17, Science 11, Politics 10, Health 9, Entertainment 8, Lifestyle 3, Travel 1, Food 1, Fashion 1.
- Protocol: a story about a foreign country's politics, conflict or disaster is World; national politics (the
  United States, the United Kingdom as covered by their own feeds) is Politics; a company, market, price or tax story
  is Business; a product, platform, game or gadget story is Technology; a match, league, club or athlete story is
  Sports whatever the country; health of a public figure is Health; an attack on a politician is World.
- Input: headline, feed summary and stored text, exactly what ingestion classifies (`rssCategory: nil`).

## Result

| | Correct of 200 | Accuracy |
| --- | --- | --- |
| Before (main `ecc113f`) | 127 | 63.5 % |
| After | 166 | 83.0 % |

Agreement of the categories already stored in the library with the labels: 120 of 200 (60.0 %).

### Misfile classes before, and the fix

| Class | Count | Example | Fix |
| --- | --- | --- | --- |
| World filed as Politics | 15 | "Macron takes aim at Trump for using France riots for election gain" | A foreign place or leader in the headline makes a Politics story World unless the headline also carries a national-politics cue (Congress, Senate, White House, governor, Supreme Court, Democrat, Republican, lawmaker, executive order, midterm, Capitol). "president", previously a Politics cue, is now World. |
| Sports filed as World | 9 | "Al-Nassr survive Al-Faisaly scare…", "Arsenal relieve pressure with Spurs win" | League, competition and match cues (world cup, Formula One, Ligue 1, Champions League, clasico, derby, fixture, matchday, striker, cricket, rugby…). World now loses a tie against a later category: it is the catch-all. |
| Technology filed as World | 9 | "Pikmin 4 is $20 off ahead of its Nintendo Switch 2 update" | Product, platform and game cues (app, smartphone, camera, console, Nintendo, Xbox, TikTok, Meta, OpenAI, EV, robot, social media…). |
| Business filed as World | 9 | "Comcast loses more customers, claims other ISPs' cheap prices are irrational" | Company, customer, price, tax, deal, debt, bond and tariff cues. |
| World filed as Business | 4 | "Drone strike on Abyei market … kills 150" | "market" alone no longer scores Business; "markets", "stock market" and "market share" do. Conflict cues (airstrike, missile, troops, killed, attack, protests, unrest, ceasefire…) score World. |
| Health filed as World | 3 | "Ebola outbreak in DR Congo spreads to new province" | Outbreak and disease cues (Ebola, outbreak, epidemic, cholera, measles, chemotherapy, tumour, patients). |
| World filed as Food | 2 | "Half a million Palestinians lose food aid" | Compound exclusions: "food aid", "food agency", "food program(me)", "food security", "food shortages", "food supplies" are removed before cues are counted. |
| Science filed as World | 2 | "Deforestation in Brazil's Amazon falls to all-time low" | Environment cues (deforestation, El Niño, emissions, warming, coral, reef, scientists, asteroid, spacecraft). |

### Misfiles after (34)

Sports as World 6 (club stories with no listed cue: "Anderson, 44, not offered new Lancashire contract"), Politics
as World 4 (Trump stories naming a foreign leader or country, which the protocol files as World only when the story
is about that country), Technology as World 4 (an electric SUV, a game community, an airship, AI-driven job cuts),
World as Science 2 ("research institutions", a climate lawsuit), Science as World 2, Entertainment as World 2, and
14 single cases. No class is left above 6, and none of the remaining cases is a brand word or a tie.

Brand words: "apple" alone no longer scores Technology; the company is recognised through its products and
possessive ("Apple Music", "Apple TV", "Apple Watch", "Apple Intelligence", "Apple Store", "Apple's"), so "Apple
Music has a new logo" stays Technology while "Grandma's apple pie recipe" is Food. In this sample every headline with
the word was about the company, so the change is neutral here and matters for food and lifestyle feeds.

## Regressions

`testCanonicalClassificationDisambiguation` gained one case per fixed class (marketplace, food aid, a league name, a
Saudi derby tie, Macron/Trump, a South Carolina rally, the White House, Ebola, Comcast customers, a game deal,
deforestation, Apple, apple pie).

## Limits

- One library, one reader's subscriptions, 14 days: the sample over-represents World (49 %) and the feeds in the
  catalog. The accuracy numbers describe this sample, not the catalog.
- Labels are one labeller's reading of a headline and summary; borderline stories (sport governance, a politician's
  injury, climate litigation) were labelled by the protocol above and could be read otherwise.
- No installation, isolated app launch or live network checks were part of this audit.

## Second pass — 26 October 2026

Review of the first pass found 9 stories it had broken (right on main, wrong after) and 25 it had left wrong, and
asked for general rules plus a check against overfitting: the 83.0 % was measured on the stories the rules were written
from.

### Rule changes

- Place, leader and international-body names (`worldPlaces`: countries, capitals, "Putin", "Macron", "UN", …) say
  where a story happens, not what it is about, so they count half as much as a topic cue. A story with no other topic
  still reads as World; "Kenya confirms new Ebola cases" is Health, "Omani label takes its ballerina heels to Paris"
  (Paris Fashion Week) is Fashion and "UN warns El Niño could be strongest on record" is Science.
- "president" is no longer a World cue: it names US and foreign heads of state alike.
- New World topic cues for disasters ("casualties", "collapse", "earthquake", "floods", "hurricane") and "diplomats".
- New cues: "politician(s)" (Politics, so the foreign-place rule makes an attack on a foreign politician World),
  "consumer(s)" (Business), "rpg", "single player", "multiplayer", "ces" (Technology), "feature film", "filmmaker",
  "prequel", "sequel", "episode(s)", "trailer", "festival" (Entertainment), "trattoria", "bistro", "brasserie",
  "eatery", "pizzeria", "bakery" (Food), "match", "triathlon", "triathlete(s)" (Sports).
- Tried and dropped: "political"/"politics" as Politics cues (they pulled foreign political crises into Politics), and
  a 1.5 score threshold so a single summary cue classifies (176/200 instead of 181/200).

### Result

Sample 2 is a fresh draw from a newer read-only library copy (26 October, 6,400 stories, the 14 days before 26
October; `NEWS_CATEGORY_SEED=2026-10-26`, the 15 stories already in sample 1 skipped), labelled by Claude with the same
protocol before any classifier output was looked at, and scored once, after the rules were frozen. No rule was written
from sample 2.

| | Sample 1 (rules written from it) | Sample 2 (fresh, held out) |
| --- | --- | --- |
| Before (main `ecc113f`) | 127 / 200 (63.5 %) | 112 / 200 (56.0 %) |
| First pass (`0ca9252`) | 166 / 200 (83.0 %) | 136 / 200 (68.0 %) |
| Second pass | 181 / 200 (90.5 %) | 141 / 200 (70.5 %) |

Both columns were exported by `--export-categories` with `NEWS_CATEGORY_IDS` (which now ignores the 14-day window, so
a listed sample can be measured again on a later day).

On sample 1 the second pass fixes 17 stories the first pass got wrong and breaks 2 it had right; 6 of the 9 it had
broken are right again. On sample 2 it fixes 6 and breaks 1.

The held-out gain is real but much smaller than the in-sample one: the first pass gained 12 points on fresh stories
against 19.5 on its own sample, the second pass 2.5 against 7.5. Sample 2's remaining misfiles are mostly specific
stories filed as World for lack of any cue (Business 8, Entertainment 7, Technology 5, Politics 5, Sports 4), US
politics stories that name a foreign country or leader (5 Politics as World, 5 World as Politics both ways), and gadget
deals read as Business (3). These need a broader vocabulary or a different method, not more single cues.

### Remaining limits

- One labeller (Claude) for both samples; Mars spot-checks. Borderline protocol cases (a US politician's statement
  about a foreign country, royals, energy projects) can be read either way.
- Club and athlete names carry no cue ("Al-Nassr survive Al-Faisaly scare", "Anderson not offered new Lancashire
  contract"); a gazetteer of clubs was not added.
