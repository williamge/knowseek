# 032. Company facts card (EDGAR)

- Status: done
- Area: `Knowseek.Cards` (new provider), `Knowseek.Entities` (CIK), web card rendering
- Depends on: 031

## Goal

Show a card of facts for a public company ("nvda", "nvidia", "apple"): what the
company is, its shares outstanding and its latest filings, from the SEC's
EDGAR. No price.

## Scope

The original scope was a price card from a Yahoo-style chart endpoint. The
re-probe found no usable source of quotes ([ADR 0021](../decisions/0021-company-card-source.md)),
and the owner narrowed the task to a facts card; the price is task
[040](040-company-price-card.md) (parked).

- CIK from Wikidata property P5531, read into `Entity.cik`. No CIK: no card.
- Two keyless requests to `data.sec.gov` per card: submissions and shares
  outstanding (the second is optional).
- Card facts: name, tickers and exchanges, industry, fiscal year end, filer
  category, shares outstanding with its date, the latest five 10-K, 10-Q and 8-K
  with links, and a credit to the SEC.
- A User-Agent that says who we are, overridable with `SEC_USER_AGENT`.
- TTL one hour. A 403 or 429 gives `stale` or `unavailable`, never an error
  response.
- Fix the stale wording about the required checks (`AGENTS.md`, ADR 0010).

## Acceptance criteria

- `Req.Test` stubs with fixtures recorded from the real responses; no network.
- Nvidia, Nvidia by name and Apple give a card; a company with no CIK gives
  `none`; 403, 429 and a malformed body are `stale` or `unavailable`.
- A company with no shares concept (Alphabet) still has a card.
- Frontend shows the facts, the filing links and the SEC credit.
- `make check-quiet` passes.

## Outcome

Built. [ADR 0021](../decisions/0021-company-card-source.md) has the evidence and
the decision.

**Built.** `Entity.cik` (P5531) in the Wikidata resolver, with fixtures and tests.
`Knowseek.Cards.Edgar` (client) and `Knowseek.Cards.Providers.Company` (card type
`company`), wired into the providers list with a cache of its own. Frontend
`CompanyFacts.tsx` (facts, filings as links that open with `noopener noreferrer`,
the SEC credit) and one dispatch line plus a footer line in `FactCard.tsx`.
`SEC_USER_AGENT` in `config/runtime.exs`, `.env.example` and the README. README
API table, ARCHITECTURE, ADR 0017 note, fixtures README. The "three checks"
wording is fixed (`AGENTS.md`, a dated update in ADR 0010, a note in ADR 0020).

**Decisions.** The card is for any company with a CIK, not only Nasdaq and NYSE:
the SEC knows its tickers and exchanges, and a foreign filer on the NYSE (TSMC)
files 20-F and 6-K, which the filing list includes. A company with no
shares-outstanding concept (Alphabet: several share classes) has a card without
it. The default User-Agent is `Knowseek/0.1 (self-hosted instance)`: the SEC
answers 403 to a User-Agent that contains `github` or a URL in the form we first
tried (ADR 0021), and 403 to `www.sec.gov` for a UA without a contact, so the
ticker file is not used.

**Left out.** Any price, market state or quote label (task 040, parked).
Revenue and financial statements (the XBRL tag differs per company). Other
filers' forms (proxy statements, insider forms). Entities that have no Wikidata
CIK get no card.

**Follow-ups.** [040](040-company-price-card.md).
