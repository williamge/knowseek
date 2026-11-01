import type { WeatherDay } from "../types";

const FALLBACK_LOCALE = "en-US";

/**
 * `locale` if it is a valid BCP 47 tag, else `en-US`. `navigator.language` can
 * be empty, and `Intl` throws a RangeError on an empty or malformed tag, which
 * would unmount the page.
 */
export function safeLocale(locale: string | null | undefined): string {
  if (!locale) return FALLBACK_LOCALE;
  try {
    return Intl.getCanonicalLocales(locale).length > 0 ? locale : FALLBACK_LOCALE;
  } catch {
    return FALLBACK_LOCALE;
  }
}

/**
 * The backend sends metric values. Only the US reads Fahrenheit, mph and
 * inches; every other locale gets metric. A bare language ("en") counts as its
 * most likely region (`en` is `en-US`), like the browser's own formatting.
 */
export function usesImperial(locale: string): boolean {
  return new Intl.Locale(safeLocale(locale)).maximize().region === "US";
}

const MISSING = "–";

/** Rounds first, so that -0.2 shows as "0", not "-0". */
function number(value: number, locale: string, maximumFractionDigits = 0): string {
  const scale = 10 ** maximumFractionDigits;
  const rounded = Math.round(value * scale) / scale;
  return new Intl.NumberFormat(safeLocale(locale), { maximumFractionDigits }).format(
    rounded === 0 ? 0 : rounded,
  );
}

/** 17 -> "63°F" (US) or "17°C". */
export function formatTemperature(celsius: number | null, locale: string): string {
  if (celsius === null) return MISSING;
  return usesImperial(locale)
    ? `${number((celsius * 9) / 5 + 32, locale)}°F`
    : `${number(celsius, locale)}°C`;
}

/** 4.7 km/h -> "3 mph" (US) or "5 km/h". */
export function formatSpeed(kmh: number | null, locale: string): string {
  if (kmh === null) return MISSING;
  return usesImperial(locale)
    ? `${number(kmh / 1.609344, locale)} mph`
    : `${number(kmh, locale)} km/h`;
}

/** 2.5 mm -> "0.1 in" (US) or "2.5 mm". */
export function formatPrecipitation(mm: number | null, locale: string): string {
  if (mm === null) return MISSING;
  return usesImperial(locale)
    ? `${number(mm / 25.4, locale, 2)} in`
    : `${number(mm, locale, 1)} mm`;
}

const COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];

/** 351 -> "N", 90 -> "E": the direction the wind blows from. */
export function compassPoint(degrees: number | null): string {
  if (degrees === null || !Number.isFinite(degrees)) return "";
  const index = Math.round((((degrees % 360) + 360) % 360) / 45) % 8;
  return COMPASS[index];
}

/** "10:00 AM GMT+9": `iso` (UTC) in the place's time zone, named by `Intl`. */
export function placeClock(iso: string, timezone: string, locale: string): string {
  const options: Intl.DateTimeFormatOptions = {
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  };
  const date = new Date(iso);
  locale = safeLocale(locale);
  try {
    return date.toLocaleTimeString(locale, { ...options, timeZone: timezone });
  } catch {
    // An unknown zone name: show UTC rather than the reader's zone, which would mislead.
    return date.toLocaleTimeString(locale, { ...options, timeZone: "UTC" });
  }
}

/** "Today" for the first day, else the short weekday ("Mon") of a local date like "2026-11-02". */
export function dayLabel(day: WeatherDay, index: number, locale: string): string {
  if (index === 0) return "Today";
  // A date without a time is the place's calendar date: read it as UTC midnight, show it in UTC.
  return new Date(`${day.date}T00:00:00Z`).toLocaleDateString(safeLocale(locale), {
    weekday: "short",
    timeZone: "UTC",
  });
}
