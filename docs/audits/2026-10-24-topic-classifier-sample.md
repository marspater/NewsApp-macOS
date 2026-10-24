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
