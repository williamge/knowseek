import {
  compassPoint,
  dayLabel,
  formatPrecipitation,
  formatSpeed,
  formatTemperature,
  placeClock,
  safeLocale,
} from "../lib/weather";
import type { WeatherFacts as WeatherFactsData } from "../types";

interface Props {
  title: string;
  /** What Wikidata says the place is, for example "capital and largest city of Japan". */
  description: string | null;
  facts: WeatherFactsData;
  /** Picks the units. The browser's language by default. */
  locale?: string;
}

const browserLocale = () =>
  safeLocale(typeof navigator === "undefined" ? undefined : navigator.language);

/** The body of a weather card: current conditions and a few days. */
export function WeatherFacts({ title, description, facts, locale = browserLocale() }: Props) {
  const { current, daily } = facts;
  const today = daily[0];

  return (
    <>
      <header className="fact-card__head">
        <h2 className="fact-card__title">{title}</h2>
        {description && <span className="fact-card__league">{description}</span>}
      </header>

      <div className="weather__now">
        <span className="weather__icon" aria-hidden="true">
          {current.icon}
        </span>
        <strong className="weather__temp">
          {formatTemperature(current.temperature_c, locale)}
        </strong>
        <span className="weather__condition">
          {current.condition}
          <span className="fact-card__muted">
            {" "}
            · feels like {formatTemperature(current.apparent_temperature_c, locale)}
          </span>
        </span>
      </div>

      <dl className="fact-card__facts">
        {today && (
          <div className="fact-card__row">
            <dt>Today</dt>
            <dd>
              High {formatTemperature(today.high_c, locale)} · low{" "}
              {formatTemperature(today.low_c, locale)}
              {today.precipitation_probability_percent !== null && (
                <span className="fact-card__muted">
                  {" "}
                  · {today.precipitation_probability_percent}% chance of rain
                </span>
              )}
            </dd>
          </div>
        )}
        <div className="fact-card__row">
          <dt>Wind</dt>
          <dd>
            {formatSpeed(current.wind_speed_kmh, locale)}
            {current.wind_direction_deg !== null &&
              ` from ${compassPoint(current.wind_direction_deg)}`}
            {current.humidity_percent !== null && (
              <span className="fact-card__muted"> · humidity {current.humidity_percent}%</span>
            )}
            {current.precipitation_mm !== null && current.precipitation_mm > 0 && (
              <span className="fact-card__muted">
                {" "}
                · {formatPrecipitation(current.precipitation_mm, locale)} precipitation
              </span>
            )}
          </dd>
        </div>
      </dl>

      {daily.length > 1 && (
        <ol className="weather__days" aria-label="Forecast">
          {daily.map((day, index) => (
            <li key={day.date} className="weather__day">
              <span className="weather__day-name">{dayLabel(day, index, locale)}</span>
              <span className="weather__day-icon" role="img" aria-label={day.condition}>
                {day.icon}
              </span>
              <span>{formatTemperature(day.high_c, locale)}</span>
              <span className="fact-card__muted">{formatTemperature(day.low_c, locale)}</span>
            </li>
          ))}
        </ol>
      )}
    </>
  );
}

/**
 * The footer of a weather card: when the conditions are from, in the place's
 * time zone, and the credit that Open-Meteo's license (CC BY 4.0) requires.
 */
export function WeatherCredit({
  facts,
  locale = browserLocale(),
}: {
  facts: WeatherFactsData;
  locale?: string;
}) {
  return (
    <>
      <span>
        as of{" "}
        <time dateTime={facts.observed_at}>
          {placeClock(facts.observed_at, facts.timezone, locale)}
        </time>
      </span>
      <a href={facts.source_url} target="_blank" rel="noreferrer">
        Weather data by {facts.source}
      </a>
      <a href="https://creativecommons.org/licenses/by/4.0/" target="_blank" rel="noreferrer">
        CC BY 4.0
      </a>
    </>
  );
}
