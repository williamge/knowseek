import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FactCard } from "../src/components/FactCard";
import { WeatherFacts } from "../src/components/WeatherFacts";
import { weatherFacts, weatherResponse } from "./fixtures";

const noop = () => {};

afterEach(() => {
  vi.restoreAllMocks();
});

describe("weather card", () => {
  it("shows the place, its description, the temperature in the reader's units and the condition", () => {
    vi.spyOn(navigator, "language", "get").mockReturnValue("en-US");
    render(<FactCard data={weatherResponse()} onSearch={noop} />);

    const card = screen.getByRole("region", { name: "Live facts: Tokyo" });
    expect(within(card).getByRole("heading", { name: "Tokyo" })).toBeInTheDocument();
    expect(within(card).getByText("capital and largest city of Japan")).toBeInTheDocument();
    expect(card.querySelector(".weather__temp")).toHaveTextContent("63°F");
    expect(within(card).getByText(/Clear sky/)).toBeInTheDocument();
    expect(within(card).getByText(/feels like 60°F/)).toBeInTheDocument();
  });

  it("shows today's high and low, the wind and the humidity", () => {
    render(<WeatherFacts title="Tokyo" description={null} facts={weatherFacts()} locale="en-US" />);

    expect(screen.getByText(/High 68°F · low 53°F/)).toBeInTheDocument();
    expect(screen.getByText(/0% chance of rain/)).toBeInTheDocument();
    expect(screen.getByText(/3 mph from N/)).toBeInTheDocument();
    expect(screen.getByText(/humidity 55%/)).toBeInTheDocument();
  });

  it("uses metric units outside the US", () => {
    render(<WeatherFacts title="Tokyo" description={null} facts={weatherFacts()} locale="en-GB" />);

    expect(screen.getAllByText("17°C")[0]).toHaveClass("weather__temp");
    expect(screen.getByText(/High 20°C · low 12°C/)).toBeInTheDocument();
    expect(screen.getByText(/5 km\/h from N/)).toBeInTheDocument();
  });

  it("shows a strip of the days, today first", () => {
    render(<WeatherFacts title="Tokyo" description={null} facts={weatherFacts()} locale="en-US" />);

    const strip = screen.getByRole("list", { name: "Forecast" });
    const days = within(strip).getAllByRole("listitem");
    expect(days).toHaveLength(5);
    expect(days[0]).toHaveTextContent("Today");
    expect(days[0]).toHaveTextContent("68°F");
    expect(days[1]).toHaveTextContent("Mon");
    expect(days[1]).toHaveTextContent("72°F");
    expect(within(days[1]).getByRole("img", { name: "Drizzle" })).toBeInTheDocument();
  });

  it("shows no strip when the forecast has only today", () => {
    const facts = weatherFacts();
    render(
      <WeatherFacts
        title="Tokyo"
        description={null}
        facts={{ ...facts, daily: facts.daily.slice(0, 1) }}
        locale="en-US"
      />,
    );
    expect(screen.queryByRole("list", { name: "Forecast" })).not.toBeInTheDocument();
  });

  it("copes with a card that has no numbers", () => {
    const facts = weatherFacts();
    render(
      <WeatherFacts
        title="Tokyo"
        description={null}
        locale="en-US"
        facts={{
          ...facts,
          daily: [],
          current: {
            ...facts.current,
            temperature_c: null,
            apparent_temperature_c: null,
            humidity_percent: null,
            wind_speed_kmh: null,
            wind_direction_deg: null,
            precipitation_mm: null,
          },
        }}
      />,
    );
    expect(screen.getByText(/feels like –/)).toBeInTheDocument();
    expect(screen.queryByText(/humidity/)).not.toBeInTheDocument();
  });

  it("shows precipitation now only when it is raining", () => {
    const facts = weatherFacts();
    const raining = { ...facts, current: { ...facts.current, precipitation_mm: 2.5 } };
    const { rerender } = render(
      <WeatherFacts title="Tokyo" description={null} facts={raining} locale="en-US" />,
    );
    expect(screen.getByText(/0\.1 in precipitation/)).toBeInTheDocument();

    rerender(<WeatherFacts title="Tokyo" description={null} facts={facts} locale="en-US" />);
    expect(screen.queryByText(/precipitation/)).not.toBeInTheDocument();
  });

  it("stamps the time in the place's zone and credits Open-Meteo with a link", () => {
    render(<FactCard data={weatherResponse()} onSearch={noop} />);

    const stamp = screen.getByText("10:00 AM GMT+9");
    expect(stamp.closest("time")).toHaveAttribute("datetime", "2026-11-01T01:00:00Z");

    const credit = screen.getByRole("link", { name: "Weather data by Open-Meteo.com" });
    expect(credit).toHaveAttribute("href", "https://open-meteo.com/");
    expect(credit).toHaveAttribute("rel", "noreferrer");
  });

  it("says when the card may be out of date", () => {
    render(<FactCard data={weatherResponse({ status: "stale" })} onSearch={noop} />);
    expect(screen.getByRole("status")).toHaveTextContent("may be out of date");
  });

  it("does not show the sports footer on a weather card", () => {
    render(<FactCard data={weatherResponse()} onSearch={noop} />);
    expect(screen.queryByText("ESPN")).not.toBeInTheDocument();
  });

  it("searches for the weather in an alternative place", async () => {
    const onSearch = vi.fn();
    const alternative = {
      id: "Q60",
      label: "New York City",
      description: "most populous city in the United States",
      kind: "place",
      wikipedia_title: "New York City",
    };
    render(
      <FactCard data={weatherResponse({ alternatives: [alternative] })} onSearch={onSearch} />,
    );

    await userEvent.click(screen.getByRole("button", { name: "New York City" }));
    expect(onSearch).toHaveBeenCalledWith("weather in New York City");
  });

  it.each(["", "not a locale!"])(
    "renders with en-US units when navigator.language is %j (no crash)",
    (language) => {
      vi.spyOn(navigator, "language", "get").mockReturnValue(language);
      render(<FactCard data={weatherResponse()} onSearch={noop} />);

      expect(screen.getByRole("region", { name: "Live facts: Tokyo" })).toBeInTheDocument();
      expect(screen.getByText("10:00 AM GMT+9")).toBeInTheDocument();
      expect(document.querySelector(".weather__temp")).toHaveTextContent("63°F");
    },
  );

  it("links the license as well as the credit", () => {
    render(<FactCard data={weatherResponse()} onSearch={noop} />);
    expect(screen.getByRole("link", { name: "CC BY 4.0" })).toHaveAttribute(
      "href",
      "https://creativecommons.org/licenses/by/4.0/",
    );
  });

  it("says where the wind comes from, and nothing when the direction is unknown", () => {
    const facts = weatherFacts();
    const { rerender } = render(
      <WeatherFacts title="Tokyo" description={null} facts={facts} locale="en-US" />,
    );
    expect(screen.getByText(/3 mph from N/)).toBeInTheDocument();

    rerender(
      <WeatherFacts
        title="Tokyo"
        description={null}
        facts={{ ...facts, current: { ...facts.current, wind_direction_deg: null } }}
        locale="en-US"
      />,
    );
    expect(screen.queryByText(/from/)).not.toBeInTheDocument();
  });

  it("gives an alternative place its description as a tooltip", () => {
    const alternative = {
      id: "Q1384",
      label: "New York",
      description: "state of the United States of America",
      kind: "place",
      wikipedia_title: "New York (state)",
    };
    render(<FactCard data={weatherResponse({ alternatives: [alternative] })} onSearch={noop} />);
    expect(screen.getByRole("button", { name: "New York" })).toHaveAttribute(
      "title",
      "state of the United States of America",
    );
  });
});
