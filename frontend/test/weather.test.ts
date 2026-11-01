import { describe, expect, it } from "vitest";
import {
  compassPoint,
  dayLabel,
  formatPrecipitation,
  formatSpeed,
  formatTemperature,
  placeClock,
  safeLocale,
  usesImperial,
} from "../src/lib/weather";
import { weatherFacts } from "./fixtures";

describe("usesImperial", () => {
  it("is true for the US only", () => {
    expect(usesImperial("en-US")).toBe(true);
    expect(usesImperial("es-US")).toBe(true);
    expect(usesImperial("en-GB")).toBe(false);
    expect(usesImperial("de-DE")).toBe(false);
    expect(usesImperial("ja-JP")).toBe(false);
    expect(usesImperial("fr-CA")).toBe(false);
  });

  it("reads a bare language as its likely region", () => {
    expect(usesImperial("en")).toBe(true);
    expect(usesImperial("de")).toBe(false);
  });

  it("falls back to en-US (imperial) for an empty or invalid locale", () => {
    expect(usesImperial("not a locale!")).toBe(true);
    expect(usesImperial("")).toBe(true);
  });
});

describe("safeLocale", () => {
  it("keeps a valid tag", () => {
    expect(safeLocale("de-DE")).toBe("de-DE");
    expect(safeLocale("en")).toBe("en");
  });

  it("falls back to en-US for an empty, missing or invalid tag", () => {
    expect(safeLocale("")).toBe("en-US");
    expect(safeLocale(undefined)).toBe("en-US");
    expect(safeLocale(null)).toBe("en-US");
    expect(safeLocale("not a locale!")).toBe("en-US");
    expect(safeLocale("en_US")).toBe("en-US");
  });
});

describe("an empty or invalid locale never throws", () => {
  it.each(["", "not a locale!", "en_US"])("formats with %j like en-US", (locale) => {
    expect(formatTemperature(17, locale)).toBe("63°F");
    expect(formatSpeed(4.7, locale)).toBe("3 mph");
    expect(formatPrecipitation(2.5, locale)).toBe("0.1 in");
    expect(placeClock("2026-11-01T01:00:00Z", "Asia/Tokyo", locale)).toBe("10:00 AM GMT+9");
    expect(dayLabel(weatherFacts().daily[1], 1, locale)).toBe("Mon");
  });
});

describe("formatTemperature", () => {
  it("en-US: Fahrenheit, rounded", () => {
    expect(formatTemperature(17, "en-US")).toBe("63°F");
    expect(formatTemperature(0, "en-US")).toBe("32°F");
    expect(formatTemperature(-40, "en-US")).toBe("-40°F");
  });

  it("never shows a negative zero", () => {
    expect(formatTemperature(-0.2, "en-GB")).toBe("0°C");
    expect(formatTemperature(-0, "en-GB")).toBe("0°C");
    // -17.8 °C is -0.04 °F.
    expect(formatTemperature(-17.8, "en-US")).toBe("0°F");
    expect(formatTemperature(-0.4, "de-DE")).toBe("0°C");
    expect(formatSpeed(-0.1, "en-GB")).toBe("0 km/h");
    expect(formatPrecipitation(-0.01, "en-GB")).toBe("0 mm");
  });

  it("en-GB: Celsius, rounded", () => {
    expect(formatTemperature(17, "en-GB")).toBe("17°C");
    expect(formatTemperature(15.7, "en-GB")).toBe("16°C");
    expect(formatTemperature(-0.4, "en-GB")).toBe("0°C");
  });

  it("de-DE: Celsius with the locale's minus sign", () => {
    expect(formatTemperature(17, "de-DE")).toBe("17°C");
    expect(formatTemperature(-5, "de-DE")).toBe("-5°C");
  });

  it("shows a dash for a missing value", () => {
    expect(formatTemperature(null, "en-US")).toBe("–");
    expect(formatTemperature(null, "de-DE")).toBe("–");
  });
});

describe("formatSpeed", () => {
  it("en-US: mph", () => {
    expect(formatSpeed(4.7, "en-US")).toBe("3 mph");
    expect(formatSpeed(100, "en-US")).toBe("62 mph");
  });

  it("other locales: km/h", () => {
    expect(formatSpeed(4.7, "en-GB")).toBe("5 km/h");
    expect(formatSpeed(100, "fr-FR")).toBe("100 km/h");
  });

  it("shows a dash for a missing value", () => {
    expect(formatSpeed(null, "en-US")).toBe("–");
  });
});

describe("formatPrecipitation", () => {
  it("en-US: inches, two decimals at most", () => {
    expect(formatPrecipitation(2.5, "en-US")).toBe("0.1 in");
    expect(formatPrecipitation(25.4, "en-US")).toBe("1 in");
    expect(formatPrecipitation(0.3, "en-US")).toBe("0.01 in");
  });

  it("other locales: millimetres, one decimal at most, in the locale's decimal mark", () => {
    expect(formatPrecipitation(2.5, "en-GB")).toBe("2.5 mm");
    expect(formatPrecipitation(2.54, "de-DE")).toBe("2,5 mm");
    expect(formatPrecipitation(0, "en-GB")).toBe("0 mm");
  });

  it("shows a dash for a missing value", () => {
    expect(formatPrecipitation(null, "en-GB")).toBe("–");
  });
});

describe("compassPoint", () => {
  it("names the eight directions", () => {
    expect([0, 45, 90, 135, 180, 225, 270, 315].map((degrees) => compassPoint(degrees))).toEqual([
      "N",
      "NE",
      "E",
      "SE",
      "S",
      "SW",
      "W",
      "NW",
    ]);
  });

  it("rounds to the nearest point and wraps around north", () => {
    expect(compassPoint(351)).toBe("N");
    expect(compassPoint(359.9)).toBe("N");
    expect(compassPoint(22)).toBe("N");
    expect(compassPoint(23)).toBe("NE");
    expect(compassPoint(360)).toBe("N");
    expect(compassPoint(-90)).toBe("W");
  });

  it("is empty for a missing direction", () => {
    expect(compassPoint(null)).toBe("");
    expect(compassPoint(NaN)).toBe("");
  });
});

describe("placeClock", () => {
  // The tests run in America/New_York (test/global-setup.ts): the place's zone must win.
  it("shows the time in the place's zone, not the reader's", () => {
    expect(placeClock("2026-11-01T01:00:00Z", "Asia/Tokyo", "en-US")).toBe("10:00 AM GMT+9");
    expect(placeClock("2026-11-01T01:00:00Z", "America/New_York", "en-US")).toBe("9:00 PM EDT");
  });

  it("follows the locale's clock", () => {
    expect(placeClock("2026-11-01T01:00:00Z", "Asia/Tokyo", "de-DE")).toBe("10:00 GMT+9");
  });

  it("falls back to UTC for an unknown zone", () => {
    expect(placeClock("2026-11-01T01:00:00Z", "Not/AZone", "en-US")).toBe("1:00 AM UTC");
  });
});

describe("dayLabel", () => {
  const days = weatherFacts().daily;

  it("calls the first day Today", () => {
    expect(dayLabel(days[0], 0, "en-US")).toBe("Today");
  });

  it("names the other days by their local calendar date, whatever the reader's zone", () => {
    expect(dayLabel(days[1], 1, "en-US")).toBe("Mon");
    expect(dayLabel(days[4], 4, "en-US")).toBe("Thu");
    expect(dayLabel(days[1], 1, "de-DE")).toBe("Mo");
  });
});
