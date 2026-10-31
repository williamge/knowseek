import { describe, expect, it } from "vitest";
import {
  displayHost,
  everyInterval,
  groupHits,
  highlight,
  isWebUrl,
  normalizeQuery,
  shortDate,
  timeAgo,
} from "../src/lib/format";
import { hit } from "./fixtures";

describe("normalizeQuery", () => {
  it("lowercases and collapses whitespace like the backend", () => {
    expect(normalizeQuery("  Rust   ASYNC\nRuntimes ")).toBe("rust async runtimes");
  });
});

describe("shortDate", () => {
  const now = new Date(2026, 9, 30);
  it("omits the year for this year", () => {
    expect(shortDate(new Date(2026, 9, 29, 12).toISOString(), now)).toBe("Oct 29");
  });
  it("adds the year for another year", () => {
    expect(shortDate(new Date(2025, 9, 29, 12).toISOString(), now)).toBe("Oct 29, 2025");
  });
});

describe("timeAgo", () => {
  const now = new Date("2026-10-30T12:00:00Z");
  it("formats past times", () => {
    expect(timeAgo("2026-10-30T09:00:00Z", now)).toBe("3 hours ago");
    expect(timeAgo("2026-10-28T12:00:00Z", now)).toBe("2 days ago");
  });
  it("says just now for very recent times", () => {
    expect(timeAgo("2026-10-30T11:59:40Z", now)).toBe("just now");
  });
});

describe("everyInterval", () => {
  it("names whole units", () => {
    expect(everyInterval(3600)).toBe("every hour");
    expect(everyInterval(6 * 3600)).toBe("every 6 hours");
    expect(everyInterval(86_400)).toBe("every day");
    expect(everyInterval(7 * 86_400)).toBe("every week");
  });
  it("falls back to seconds", () => {
    expect(everyInterval(1000)).toBe("every 1000 seconds");
  });
});

describe("urls", () => {
  it("treats only http(s) urls as links", () => {
    expect(isWebUrl("https://example.com/a")).toBe(true);
    expect(isWebUrl("urn:knowseek:sha256:abc")).toBe(false);
  });
  it("shows the host without www", () => {
    expect(displayHost("https://www.example.com/a")).toBe("example.com");
    expect(displayHost("urn:knowseek:sha256:abc")).toBe("added manually");
  });
});

describe("groupHits", () => {
  it("makes one group per hit: the best chunk first, then its passages", () => {
    const groups = groupHits([
      hit({
        document_id: "a",
        chunk_id: "a1",
        passages: [{ chunk_id: "a2", content: "More.", score: 0.01 }],
      }),
      hit({ document_id: "b", chunk_id: "b1" }),
    ]);
    expect(groups.map((g) => g.documentId)).toEqual(["a", "b"]);
    expect(groups[0].passages.map((p) => p.chunk_id)).toEqual(["a1", "a2"]);
    expect(groups[0].passages[1].similarity).toBeNull();
    expect(groups[1].passages).toHaveLength(1);
  });
  it("uses the host when a document has no title", () => {
    const [group] = groupHits([hit({ title: null, url: "https://www.example.com/x" })]);
    expect(group.title).toBe("example.com");
  });
});

describe("highlight", () => {
  it("marks query terms case-insensitively", () => {
    expect(highlight("Octopuses are smart", "octopus")).toEqual([
      { text: "Octopus", match: true },
      { text: "es are smart", match: false },
    ]);
  });
  it("ignores short words and stop words", () => {
    expect(highlight("the cat is on the mat", "the is on")).toEqual([
      { text: "the cat is on the mat", match: false },
    ]);
  });
  it("escapes regex characters in the query", () => {
    expect(highlight("c++ is fun", "c++ (fun")).toEqual([
      { text: "c++ is ", match: false },
      { text: "fun", match: true },
    ]);
  });
});
