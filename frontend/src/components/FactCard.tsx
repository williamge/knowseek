import { clockTime, gameTime, versus } from "../lib/format";
import type { CardResponse, FactCard as FactCardData, SportsTeamFacts } from "../types";

interface Props {
  data: CardResponse;
  /** Runs a search for the label of an alternative entity. */
  onSearch: (query: string) => void;
}

/**
 * The card of live facts above the results. The search does not depend on it:
 * it renders nothing until the first card arrives.
 */
export function FactCard({ data, onSearch }: Props) {
  if (!data.card) return null;
  const stale = data.status === "stale";
  const labels = data.alternatives.flatMap((entity) => (entity.label ? [entity.label] : []));

  return (
    <section className="fact-card" aria-label={`Live facts: ${data.card.title}`}>
      <CardBody card={data.card} />

      <footer className="fact-card__foot">
        {data.card.facts.source && <span>{data.card.facts.source}</span>}
        {data.as_of && (
          <span>
            as of{" "}
            <time dateTime={data.as_of}>
              {clockTime(data.as_of, data.card.facts.live !== null)}
            </time>
          </span>
        )}
        {stale && (
          <span className="fact-card__stale" role="status">
            may be out of date
          </span>
        )}
      </footer>

      {labels.length > 0 && (
        <div className="fact-card__also">
          <span>also:</span>
          {labels.map((label) => (
            <button key={label} type="button" className="chip" onClick={() => onSearch(label)}>
              {label}
            </button>
          ))}
        </div>
      )}
    </section>
  );
}

function CardBody({ card }: { card: FactCardData }) {
  switch (card.type) {
    case "sports_team":
      return <TeamBody title={card.title} facts={card.facts} />;
  }
}

function score(own: number | null, other: number | null): string {
  return own === null || other === null ? "" : `${own}–${other}`;
}

function TeamBody({ title, facts }: { title: string; facts: SportsTeamFacts }) {
  const { live, last_game: last, next_game: next, injuries } = facts;

  return (
    <>
      <header className="fact-card__head">
        <h2 className="fact-card__title">{title}</h2>
        <span className="fact-card__league">{facts.league}</span>
        {facts.record && (
          <span className="fact-card__record" title="Record this season">
            {facts.record}
          </span>
        )}
      </header>

      <dl className="fact-card__facts">
        {live && (
          <div className="fact-card__row">
            <dt>
              <span className="live-badge">Live</span>
            </dt>
            <dd>
              <strong>{score(live.team_score, live.opponent_score)}</strong>{" "}
              {versus(live.home_away, live.opponent)}
              {live.status_text && <span className="fact-card__muted"> · {live.status_text}</span>}
            </dd>
          </div>
        )}

        {last && (
          <div className="fact-card__row">
            <dt>Last game</dt>
            <dd>
              {last.result && (
                <span className={`result-letter result-letter--${last.result}`}>{last.result}</span>
              )}{" "}
              <strong>{score(last.team_score, last.opponent_score)}</strong>{" "}
              {versus(last.home_away, last.opponent)}
              <span className="fact-card__muted"> · {gameTime(last.date)}</span>
            </dd>
          </div>
        )}

        {next && (
          <div className="fact-card__row">
            <dt>Next game</dt>
            <dd>
              {versus(next.home_away, next.opponent)}
              <span className="fact-card__muted"> · {gameTime(next.date)}</span>
            </dd>
          </div>
        )}

        {injuries.length > 0 && (
          <div className="fact-card__row">
            <dt>Injuries</dt>
            <dd>
              {injuries.map((injury, index) => (
                <span key={injury.player}>
                  {index > 0 && ", "}
                  {injury.player} <span className="fact-card__muted">({injury.status})</span>
                </span>
              ))}
            </dd>
          </div>
        )}
      </dl>
    </>
  );
}
