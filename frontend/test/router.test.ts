import { describe, expect, it } from "vitest";
import { parseRoute, routeToUrl } from "../src/router";

describe("routes with a document open", () => {
  it("keeps ?doc= on a page other than search", () => {
    const route = parseRoute({ pathname: "/crawl", search: "?doc=abc" });
    expect(route).toEqual({ page: "crawl", query: null, doc: "abc" });
    expect(routeToUrl(route)).toBe("/crawl?doc=abc");
  });

  it("has no query string without a document", () => {
    const route = parseRoute({ pathname: "/stats", search: "" });
    expect(route).toEqual({ page: "stats", query: null, doc: null });
    expect(routeToUrl(route)).toBe("/stats");
  });

  it("still reads q and doc on the home route", () => {
    const route = parseRoute({ pathname: "/", search: "?q=octopus&doc=d1" });
    expect(route).toEqual({ page: null, query: "octopus", doc: "d1" });
    expect(routeToUrl(route)).toBe("/?q=octopus&doc=d1");
  });
});
