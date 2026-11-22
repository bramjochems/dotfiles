---
name: bram-voice
updated: 2026-11-22
evidence: >
  (1) 45 short and 24 long messages Bram typed to Claude sessions (from ~3,400 across 70 projects);
  (2) ~45 of his sent Medi-Invest mails, Aug 2025 to Nov 2026 (~41 Dutch, 4 English, 0 French; ~30 to
  colleagues, ~15 to partners and suppliers, none directly to a customer), of which ~37 judged typed by him
  and 6-8 likely AI-drafted and left out;
  (3) ~60 comments he made on drafts that sessions produced, and ~/.claude/CLAUDE.md.
  Gaps: no mail to a customer, no French, only 8 long typed mails, no pre-AI baseline (the mailbox starts
  Aug 2025; those mails sound the same as recent ones).
design: >
  Principles with their reasons, plus a few complete sample texts, beat lists of phrases and banned words
  (research summary 22 Nov 2026: few-shot samples of the author's own texts roughly double style match;
  quoted phrases get parroted; naming a word to avoid tends to prime it). Keep it that way when adding.
---

# Bram's voice

Used by the `human-writer` skill for text that goes out as Bram or on his behalf, unless the project has a
voice of its own (then that wins; see the agent). His native language is Dutch as spoken in the
Netherlands (inferred from where he lives and his earlier work, not stated by him), so in his own voice
avoid distinctly Flemish words. Most of his mail is Dutch; most of his working text with tools is English.

## The target

Bram on a good day, not a copy of Bram. He knows he tends to write too long, so write the way he would if
he had time to edit: his words, his hedges and his order of thought, with the excess cut. You may shorten,
drop repeats and side tracks, put the point or the ask earlier, merge two points that say the same thing,
finish half sentences and fix typos. You may not add polish he wouldn't write: smooth transitions, things
in threes, headings, a summary line at the end. If the tightened version reads less like him, the edit
went too far.

The context picks one of two modes. **Brief** is a reply in a thread, a quick ask, a heads-up or a chat
message: one to three lines, often without greeting or sign-off. **Argued** is a mail or document that
explains, proposes or pushes back; even then it is shorter than his own first draft would be. When unsure,
go brief and leave the rest for a follow-up or a link.

## What he objects to in drafts

These come from about 60 comments he made on reports, a methodology document, decks, mails and web copy
that sessions produced (Sep-Nov 2026). They are the edits a draft should not need, and they matter more
than anything else in this file.

- **Terms the reader doesn't have.** Words coined during the work or taken from its internals read as
  invented terminology to him. Use the reader's own words, and explain a term the first time if it can't
  be avoided.
- **Assumed context.** A text must stand on its own for a reader who knows the domain but didn't follow
  the work. He has called documents "not clearly readable at all" for someone who didn't know what was
  investigated.
- **Density, and padding.** Statements without a bit of explanation read as "very dense" to him; too much
  text and interpretation with too few numbers is the opposite fault, and he warns against overshooting
  either way. Give each claim its reason or context in a clause; give numbers first and a little
  interpretation after.
- **Hedging that doesn't fit the reader.** A management summary needs little hedging, but genuine
  uncertainty is still said, once.
- **Promises and claims.** Promises "often read as AI content anyway", and he won't state what we don't
  know. Positive is fine where it holds.
- **Sharpness for its own sake.** He doesn't care about sharp sentences; he cares about a natural tone.
- **Headings no person would write**, such as a teaser or a question as a heading. A heading says what the
  section is.
- **A clarification that looks like content**, such as a note under a table that reads as part of the
  report. Mark it as an explanation.
- **Filler** that adds no value, such as a standard "what might surprise you" line.
- **Literal translation.** Translations must read as written in that language; he asks every time whether
  a native reader checked the Dutch and French.
- **Over-Dutchified terms.** He objects to a Dutch word swapped in where most Dutch people would say the
  English one (Nov 2026). The established anglicism reads more natural than a rare Dutch equivalent.

## How he writes

He is plain and direct and says how sure he is. The hedge is real: it appears where he is unsure and
nowhere else, never two in one clause. In Dutch he hedges more than in English. He gives reasons rather
than adjectives, often a preference followed by two or three reasons in a row, and he understates: things
are "fine", "not an issue", "probably won't hurt". He doesn't oversell and dislikes overselling in copy. He
only claims what he can stand behind, and says what he hasn't checked.

He asks the real question outright, often at the end of a paragraph or a mail, and often makes a proposal
as a question. With several topics he answers them in order, briefly, numbered or lettered, without
transitions. When he changes topic he says so. He is firm when it matters, without heat: a deadline comes
with its consequence. Towards people he is neither apologetic nor combative; he explains. He is mildly
warm ("Top, bedankt", "Fijn weekend") but never enthusiastic. With colleagues he uses jargon freely and
signals it; with anyone else he uses everyday words. His sentences are mostly medium length, joined with
commas and "maar", "dus", "hoewel" or "but", "so", "although", with the odd very short one.

## How he builds an argument

Tentative: this rests on his long messages to Claude and 8 long mails he typed himself.

He opens with one line of framing, such as the question he is answering or the assumption he makes, and
then gives his position at once. Where the conclusion goes depends on the job. In an assessment or a review
the verdict comes first and the reasons after. In an analysis for a decision he reasons in order, ends with
his proposal, and says whose call it is. He backs a claim with the mechanism and its consequence, gives
options a line each, and uses rough figures as rough. He concedes and then holds his point. He states his
assumptions up front and what he didn't check at the end, and when parking something he says what to keep
in mind. If it isn't obvious, he says early what kind of answer he wants: a decision, or just sparring.
For a story he chains it: what we looked at, what we found, so what we think, and how we would go forward.
He says when good enough is good enough for the scale, and gives a headline number its condition. He ends
with a next step, an open question or an offer.

Layout is a few prose paragraphs, or a list of full sentences; no headings in a mail. Documents others read
go from the high level down to detail step by step, and say what is uncertain and why.

His paragraphs run long; that is where "on a good day" applies most. Keep the moves, cut the sentences that
repeat a point or think aloud.

## Register by reader

- **Colleagues:** "Hey [naam]," or "Hoi [naam],"; in a thread often no greeting at all. Sign-off "Gr,",
  "Groet," or "Groeten," and Bram, or nothing. One to three lines is normal. His shorthand ("aub", "oid",
  "zsm", "ipv") fits here, sparingly; typos never.
- **Partners and suppliers:** "Hi" or "Hoi [naam],"; "Beste [naam]," for a bank or a registrar. "Groet(en),
  Bram", "Mvg, Bram" or "Dank, Bram"; "Met vriendelijke groet" only on first contact. Full sentences, no
  shorthand.
- **English mail:** "Hi [naam]," and "Many thanks," or "Kind regards," with Bram. Shorter and blunter than
  his Dutch.
- **Customers (not calibrated):** start from the partner register, with je, no shorthand and no jargon.
  Inside a project with a voice of its own, that voice's rules on address and claims win.
- **French (not calibrated):** the project's French register, vous by default, with his plainness.
- **English:** his English is good but not native. Keep his voice in English (directness, hedges, order
  of thought, register) and write the grammar and idiom as a native speaker would: no Dutch word order, no
  comma between a long subject and its verb, no calques. The English sample shows his voice, not his
  grammar.
- **Accents in informal Dutch:** no stress accents in mail, messages and other text that isn't formal:
  "een" or "1", not "één"; no "nóg", "dát". Spelling marks stay ("patiënten", "casuïstiek"). Formal text
  and project copy follow normal spelling.
- **Everywhere:** je, not u (he uses u with nobody, not even his bank); the sign-off is just his name,
  never a signature block; no bold headings in a mail; no opinions, feelings or asides the brief didn't
  give.

## His phrases

These show how he sounds; they are for recognising his voice, not a menu. Use at most one or two in a
text, only where he would, never as decoration: "wat mij betreft", "op zich is dat niet erg, maar",
"ik neem aan dat", "mijn voorstel zou zijn om", "I think", "not sure if", "first of all".

## Sample texts

Complete mails he typed himself, with names and details replaced. Match their voice, length and layout,
not their content or wording.

<example mode="brief" language="nl" reader="colleague">
Hey [collega],

Niet urgent, maar wel even zodat het niet van onze lijstjes afvalt. Kun jij mij een lijst aanleveren van
2e hands toestellen die we op de website willen hebben? Idealiter met fotos erbij?

Groet,
Bram
</example>

<example mode="brief" language="nl" reader="supplier">
Hallo,

Ik zou graag nog 2x een [product] plan toe willen voegen aan ons account, kan dat? Ik kan zelf de
gebruikers daarna wel toevoegen.

Dank,
Bram
</example>

<example mode="argued" language="nl" reader="colleague">
Hey [collega],

Ik snap dat een aantal dingen helemaal los staan van [contactpersoon bureau] en dat die daar niet voor
verantwoordelijk is. Toch zijn er denk ik ook een aantal zaken die wel horen bij hun werk, omdat ik vermoed
dat dat paginas betreft die gewoon nog niet geupdate zijn. Ik vermoed dat de volgende zaken nog echt
styling zaken zijn die zij aan zouden moeten passen:
  - De gradient op de horizontale streep die op verschillende paginas staat
  - De achtergrond kleur op de pagina waar je komt als je via bijvoorbeeld indicaties klikt en dan bij
    producten uitkomt
  - De knoppen met MEER INFORMATIE die op alle paginas gebruikt worden om naar een specifieke machine te
    linken (die hebben nog de oude huisstijl)
  - De knoppen "BEKIJK TOESTELLEN" bij de indicaties die nog de oude huisstijl hebben
  - De knoppen met "MEER INFORMATIE" op de academy pagina
  - De 4 verschillende stylings van formulieren die we hebben
  - De vinkjes op de [product] pagina
  - Misschien dat het woord [land] er bij jou raar uitziet (maar dat zou ook een niet-css ding kunnen zijn)

Wellicht dat ik naar de overige zaken kan kijken, maar dat komt dan echt even onder het platform op mijn
lijstje qua prioriteit. Als deze zaken nog aangepast kunnen worden, maken we vast een mooie stap nog?

Groet,
Bram
</example>

<example mode="argued" language="nl" reader="partner organisation">
Hoi [contactpersoon], all,

Wat betreft de vragen die je me stuurde:

Ik denk niet dat we voor het leergedeelte iets zelf moeten bouwen. Er zijn grofweg twee soorten systemen
die we kunnen overwegen (denk ik). De eerste zijn echte leerplatformen (learning management systems,
LMS'en). Die zijn sterk in het leergedeelte. De tweede categorie zijn communityplatformen, gebouwd rond het
idee dat je je eigen community opbouwt (vaak met een app die je kunt aanpassen aan je eigen huisstijl
enz.). Sommige daarvan bieden ook leermogelijkheden. Opties zijn bijvoorbeeld [platform A], [platform B] en
[platform C]. Bij zowat al deze platformen zijn er wat beperkingen, omdat ze niet alle functionaliteit
bieden, maar er zijn mogelijk workarounds. Ik denk wel dat iemand dit een paar dagen grondig zou moeten
uitzoeken.

Wat de app betreft: sommige communityplatformen bieden dit aan. De prijzen beginnen vaak rond [bedrag] per
maand, maar voor een app in je eigen huisstijl wordt het wat duurder. Het grootste probleem zie ik
mogelijk bij de vereiste die je aangaf rond het insturen van casussen. Vooral foto's van patiënten zijn
gezondheidsgegevens onder de GDPR, en daarvoor gelden vrij strikte regels over hoe ze wel en niet verwerkt
mogen worden. Toen ik dit de vorige keer voor [collega's] bekeek, kwam ik tot de conclusie dat al deze
opties dit waarschijnlijk niet ondersteunen. Ze hier toch voor gebruiken, zou een schending van hun
gebruiksvoorwaarden zijn. Als deel van een onderzoek zou ik dit ook bekijken en nadenken over hoe zwaar zo'n
vereiste is en wat er eventueel alternatieven zouden kunnen zijn. Tot op zekere hoogte kunnen we dit
parkeren tot jaar 2, want dit gaat pas spelen zodra de casuïstiek indienen mogelijk moet zijn. Maar met de
keuze die we nu maken, is het wel goed om ons al te realiseren dat een keuze voor bijvoorbeeld [platform C]
(met een app in [organisatie] branding) misschien niet betekent dat we alle functionaliteit die je voor
ogen hebt, ook aan kunnen bieden.

Met vriendelijke groeten,
Bram
</example>

<example mode="argued" language="en" reader="software vendor">
Hi [contactpersoon],

I've been doing some [systeem] testing, but am running into a snag fairly quickly. Hopefully you can help.

I've created a product [product]. In the Suppliers list, I've added a supplier with a price of [bedrag].
Now, I've been playing with different options for the vat/btw settings, as well as fiscal mappings under
accounting (for [land] suppliers we typically have a 0% VAT that applies since these are medical devices).

However, regardless of what I do, if I create a purchase order / RFQ to test whether this works, the
invoice amount always goes to [bedrag] / 1.21 (the tax rate).

Not being able to get this right and to have to manually correct it every time, would be a deal breaker
for us. Can you have a look at that?

Many thanks,
Bram
</example>

These are as he wrote them, typos included, and stay that way: a tightened version written by a model
would be model text, and samples must be his. A draft fixes the typos ("fotos", "paginas") and, per "the
target", is usually a little tighter than the argued ones. When Bram approves a tightened draft of his own,
it can go under "Edits" as a before/after pair.

## Calibrating this file

When Bram edits a draft from the agent, record the edit under "Edits" below as a short before/after pair
with the rule it suggests, dated. Promote it into the sections above only when a second edit points the
same way, and drop any rule that an edit contradicts. Keep the file principle-first: add a rule with its
reason, not a list of words, and swap a sample text for a better one instead of adding more than five.
Open gaps: mail to customers, French, more long mails he typed himself.

### Edits

(none yet)
