import { highlight } from "../lib/format";

export function Highlighted({ text, query }: { text: string; query: string }) {
  return (
    <>
      {highlight(text, query).map((segment, index) =>
        segment.match ? <mark key={index}>{segment.text}</mark> : segment.text,
      )}
    </>
  );
}
