/**
 * Extracts one top-level string field out of JSON that is still arriving.
 *
 * The model returns structured JSON, but the user should see prose before the
 * annotations finish generating. Rather than stream raw JSON to the client and
 * make it parse partial syntax, the server pulls the `summary` field out here
 * and emits it as plain text deltas. The client never sees JSON fragments.
 *
 * This is display-only. The client draws from the validated final result, never
 * from these deltas.
 */
export class SummaryFieldStream {
  private buffer = "";
  private state: "seeking" | "inside" | "done" = "seeking";
  private escaped = false;
  private unicodeDigits: string | null = null;
  private readonly needle: string;

  constructor(fieldName = "summary") {
    this.needle = `"${fieldName}"`;
  }

  /** Returns the newly-decoded characters of the field, or "" when there are none yet. */
  push(chunk: string): string {
    if (this.state === "done") return "";
    this.buffer += chunk;

    if (this.state === "seeking") {
      const key = this.buffer.indexOf(this.needle);
      if (key === -1) {
        // Keep a tail long enough to match a needle split across chunks.
        if (this.buffer.length > this.needle.length) {
          this.buffer = this.buffer.slice(-this.needle.length);
        }
        return "";
      }
      // Skip the colon and whitespace to reach the opening quote of the value.
      const quote = this.buffer.indexOf('"', key + this.needle.length);
      if (quote === -1) return "";
      this.buffer = this.buffer.slice(quote + 1);
      this.state = "inside";
    }

    let out = "";
    let index = 0;
    while (index < this.buffer.length) {
      const char = this.buffer[index];
      index += 1;

      if (this.unicodeDigits !== null) {
        this.unicodeDigits += char;
        if (this.unicodeDigits.length === 4) {
          const code = Number.parseInt(this.unicodeDigits, 16);
          if (Number.isFinite(code)) out += String.fromCharCode(code);
          this.unicodeDigits = null;
        }
        continue;
      }

      if (this.escaped) {
        this.escaped = false;
        if (char === "u") {
          this.unicodeDigits = "";
        } else {
          out += unescapeJsonChar(char);
        }
        continue;
      }

      if (char === "\\") {
        this.escaped = true;
        continue;
      }

      if (char === '"') {
        this.state = "done";
        break;
      }

      out += char;
    }

    this.buffer = this.state === "done" ? "" : this.buffer.slice(index);
    return out;
  }
}

function unescapeJsonChar(char: string): string {
  switch (char) {
    case "n":
      return "\n";
    case "t":
      return "\t";
    case "r":
      return "\r";
    case "b":
      return "\b";
    case "f":
      return "\f";
    default:
      return char;
  }
}
